import AppKit
import CryptoKit
import EkagrachitCore

/// Keeps Ekagrachit up to date by itself.
///
/// - Checks the latest release's `update.json` shortly after launch and every
///   six hours (one HTTPS request to GitHub; nothing about the user is sent).
/// - Downloads the app archive, and accepts it only if its SHA-256 matches and
///   its Ed25519 signature verifies against the release key built into this
///   app, and it unpacks to an Ekagrachit.app of exactly the offered version
///   with a valid code signature.
/// - Installs only while no focus session is running (and not right after
///   one), swapping the bundle in place from a tiny helper script after this
///   process exits, then relaunching. A failed swap restores the old bundle.
///
/// Builds without a release key (local and CI test builds) never update.
@MainActor
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case downloading(String)
        case ready(version: String, app: URL)
    }

    private(set) var state: State = .idle
    private let currentVersion: String
    private let feedURL: URL?
    private let publicKey: Curve25519.Signing.PublicKey?
    private let allowLocalHTTP: Bool
    private var timer: Timer?

    /// Whether automatic checks are on (Settings).
    var isEnabled: () -> Bool = { true }
    /// Whether installing (quitting and relaunching) is fine right now.
    var canInstallNow: () -> Bool = { false }
    /// Quiet feedback (toasts), only for user-initiated checks and the final notice.
    var notify: (String) -> Void = { _ in }
    /// Called just before quitting to install.
    var willRelaunch: () -> Void = {}

    static let checkInterval: TimeInterval = 6 * 3600

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        currentVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        // Test hooks (the end-to-end update test serves a local feed signed with a test key).
        let feedOverride = environment["EKAGRACHIT_UPDATE_FEED"]
        allowLocalHTTP = feedOverride != nil
        feedURL = (feedOverride ?? (bundle.object(forInfoDictionaryKey: "EKUpdateFeedURL") as? String)).flatMap(URL.init(string:))
        let keyString = environment["EKAGRACHIT_UPDATE_PUBLIC_KEY"] ?? (bundle.object(forInfoDictionaryKey: "EKUpdatePublicKey") as? String) ?? ""
        publicKey = Data(base64Encoded: keyString).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    /// Updating is possible at all: this build carries a release key and a feed.
    var isAvailable: Bool { publicKey != nil && feedURL != nil }

    func start(checkSoon: Bool) {
        guard isAvailable else {
            Log.info("updates: off in this build (no release key)")
            return
        }
        let first: TimeInterval = checkSoon ? 2 : 60
        DispatchQueue.main.asyncAfter(deadline: .now() + first) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfEnabled() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfEnabled() }
        }
        timer?.tolerance = 600
    }

    private func checkIfEnabled() {
        if isEnabled() { check(userInitiated: false) }
    }

    /// "Check for Updates…" or the schedule.
    func check(userInitiated: Bool) {
        guard isAvailable, let feedURL else {
            if userInitiated { notify("This build of Ekagrachit doesn't update itself.") }
            return
        }
        switch state {
        case .checking, .downloading:
            if userInitiated { notify("Already checking for updates…") }
            return
        case let .ready(version, _):
            if userInitiated { notify("Ekagrachit \(version) is ready; it installs when you're between sessions.") }
            installIfPossible()
            return
        case .idle:
            break
        }
        state = .checking
        Task { [weak self] in
            await self?.run(feedURL: feedURL, userInitiated: userInitiated)
        }
    }

    /// Install a staged update if nothing is in the way. Called after checks,
    /// after sessions end, and periodically by the app's tick.
    func installIfPossible() {
        guard case let .ready(version, app) = state, canInstallNow() else { return }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path), !target.path.contains("/AppTranslocation/") else {
            Log.info("updates: \(parent.path) is not writable; not installing \(version)")
            notify("Ekagrachit \(version) is available. Move Ekagrachit to Applications so it can update itself.")
            state = .idle
            return
        }
        do {
            try launchSwapper(newApp: app, target: target)
        } catch {
            Log.info("updates: could not start the installer: \(error)")
            state = .idle
            return
        }
        Log.info("updates: installing \(version) and relaunching")
        notify("Updating Ekagrachit to \(version)…")
        willRelaunch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
    }

    // MARK: - Check, download, verify

    private func run(feedURL: URL, userInitiated: Bool) async {
        do {
            let (data, response) = try await Self.session.data(from: feedURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("feed answered \(String(describing: (response as? HTTPURLResponse)?.statusCode))") }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let system = SemanticVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion)
            switch UpdatePolicy.decide(current: currentVersion, manifestData: data, systemVersion: system, allowLocalHTTP: allowLocalHTTP) {
            case .upToDate:
                state = .idle
                Log.info("updates: \(currentVersion) is current")
                if userInitiated { notify("Ekagrachit \(currentVersion) is up to date.") }
            case let .rejected(reason):
                state = .idle
                Log.info("updates: manifest rejected: \(reason)")
                if userInitiated { notify("Couldn't check for updates. Try again later.") }
            case let .available(version, archive):
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                state = .downloading(version.description)
                Log.info("updates: downloading \(version)")
                if userInitiated { notify("Downloading Ekagrachit \(version)…") }
                let app = try await download(archive, manifest: manifest, version: version.description)
                state = .ready(version: version.description, app: app)
                Log.info("updates: \(version) verified and staged at \(app.path)")
                installIfPossible()
            }
        } catch {
            state = .idle
            Log.info("updates: \(error)")
            if userInitiated { notify("Couldn't check for updates. Try again later.") }
        }
    }

    private func download(_ archive: URL, manifest: UpdateManifest, version: String) async throws -> URL {
        guard let publicKey else { throw UpdateError("no release key") }
        let (file, response) = try await Self.session.download(from: archive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("archive answered \(String(describing: (response as? HTTPURLResponse)?.statusCode))") }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard UpdatePolicy.hex(SHA256.hash(data: data)) == manifest.sha256.lowercased() else { throw UpdateError("checksum mismatch") }
        guard let sig = Data(base64Encoded: manifest.signature), publicKey.isValidSignature(sig, for: data) else {
            throw UpdateError("signature does not verify against the release key")
        }
        // Unpack next to our support files, then check what came out.
        let staging = try Self.stagingDirectory(version: version)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", file.path, staging.path])
        let app = staging.appendingPathComponent("Ekagrachit.app")
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == version
        else { throw UpdateError("archive does not contain Ekagrachit \(version)") }
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral // no cookies, no cache on disk
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        c.httpAdditionalHeaders = ["User-Agent": "Ekagrachit/\(v)"]
        return URLSession(configuration: c)
    }()

    private static func stagingDirectory(version: String) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ekagrachit/Updates", isDirectory: true)
        try? FileManager.default.removeItem(at: base) // only ever one staged update
        let dir = base.appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                proc.terminationStatus == 0 ? c.resume() : c.resume(throwing: UpdateError("\(tool) exited \(proc.terminationStatus)"))
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    // MARK: - Install

    /// A helper script waits for this process to exit, swaps the bundles
    /// (restoring the old one if the swap fails) and relaunches.
    private func launchSwapper(newApp: URL, target: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; APP="$2"; NEW="$3"; OLD="$2.previous"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2; i=$((i + 1))
          [ "$i" -gt 300 ] && exit 1
        done
        rm -rf "${OLD:?}"
        mv "${APP:?}" "${OLD:?}" || exit 1
        if mv "${NEW:?}" "${APP:?}"; then
          rm -rf "${OLD:?}"
        else
          mv "${OLD:?}" "${APP:?}"
        fi
        /usr/bin/open "${APP:?}"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ekagrachit-update-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [url.path, String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
