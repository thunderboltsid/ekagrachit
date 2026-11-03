import Foundation

/// Registers ekagrachit-host with Chromium-based browsers so that installing
/// the app is just "drag to Applications": at every launch the app (re)writes
/// the Native Messaging manifest for each installed browser, pointing at the
/// host binary inside its own bundle. Moving or updating the app therefore
/// keeps working without scripts.
public enum NativeHostRegistration {
    /// Extension IDs allowed to talk to the host. The development ID is fixed
    /// by the public key pinned in extensions/chrome/manifest.json.
    public static let allowedExtensionIDs = ["dpbpdbflelamfpmehknioljngeaagaeb"]

    /// Per-user Native Messaging host directories, relative to
    /// ~/Library/Application Support, for browsers that support Chrome extensions.
    public static let browserDirectories = [
        "Google/Chrome",
        "Google/Chrome Beta",
        "Google/Chrome Dev",
        "Google/Chrome Canary",
        "Google/Chrome for Testing",
        "Chromium",
        "BraveSoftware/Brave-Browser",
        "Microsoft Edge",
        "Vivaldi",
    ]

    public static func manifest(hostPath: String, extensionIDs: [String] = allowedExtensionIDs) -> Data {
        let obj: [String: Any] = [
            "name": BridgeProtocol.hostName,
            "description": "Ekagrachit native messaging host",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public struct Result: Equatable, Sendable {
        public var written: [String] = []
        public var unchanged: [String] = []
        public var failed: [String] = []
    }

    /// Writes the manifest into every browser directory that exists (plus
    /// Google Chrome's, which is created if missing). Idempotent: identical
    /// files are left untouched.
    public static func register(hostPath: String, applicationSupport: URL, fileManager: FileManager = .default) -> Result {
        var result = Result()
        let data = manifest(hostPath: hostPath)
        for dir in browserDirectories {
            let browserRoot = applicationSupport.appendingPathComponent(dir, isDirectory: true)
            guard dir == "Google/Chrome" || fileManager.fileExists(atPath: browserRoot.path) else { continue }
            let hostsDir = browserRoot.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let file = hostsDir.appendingPathComponent("\(BridgeProtocol.hostName).json")
            if (try? Data(contentsOf: file)) == data {
                result.unchanged.append(dir)
                continue
            }
            do {
                try fileManager.createDirectory(at: hostsDir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                result.written.append(dir)
            } catch {
                result.failed.append(dir)
            }
        }
        return result
    }

    /// Copies the bundled extension to a stable, user-visible location (Chrome
    /// keeps loading an unpacked extension from the folder it was loaded from,
    /// so it must not live inside the app bundle, which is replaced on update
    /// and cannot be picked in Chrome's folder dialog). Returns true if files
    /// changed, i.e. the user should reload the extension.
    @discardableResult
    public static func syncExtension(from source: URL, to destination: URL, fileManager: FileManager = .default) throws -> Bool {
        guard fileManager.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else { return false }
        if directoriesEqual(source, destination, fileManager: fileManager) { return false }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).staging-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            let old = parent.appendingPathComponent(".\(destination.lastPathComponent).old-\(UUID().uuidString)")
            try fileManager.moveItem(at: destination, to: old)
            try fileManager.moveItem(at: staging, to: destination)
            try? fileManager.removeItem(at: old)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        return true
    }

    static func directoriesEqual(_ a: URL, _ b: URL, fileManager: FileManager) -> Bool {
        func listing(_ root: URL) -> [String: Data]? {
            guard let e = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
            var out: [String: Data] = [:]
            for case let url as URL in e {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
                out[rel] = try? Data(contentsOf: url)
            }
            return out
        }
        guard fileManager.fileExists(atPath: b.path), let la = listing(a), let lb = listing(b) else { return false }
        return la == lb
    }
}
