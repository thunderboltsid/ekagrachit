import AppKit
import ApplicationServices
import Combine
import EkagrachitCore
import ServiceManagement
import os

/// Diagnostics: unified log (Console.app, subsystem io.github.thunderboltsid.ekagrachit)
/// and, when run from a terminal or test harness, stderr.
enum Log {
    private static let logger = Logger(subsystem: "io.github.thunderboltsid.ekagrachit", category: "app")
    static func info(_ s: String) {
        logger.info("\(s, privacy: .public)")
        if isatty(STDERR_FILENO) != 0 || ProcessInfo.processInfo.environment["EKAGRACHIT_LOG_STDERR"] == "1" {
            FileHandle.standardError.write(Data("[ekagrachit \(Date().timeIntervalSince1970)] \(s)\n".utf8))
        }
    }
}

/// User preferences (UserDefaults). Never stores URLs or history.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var startShortcut: String { didSet { d.set(startShortcut, forKey: "startShortcut") } }
    @Published var endShortcut: String { didSet { d.set(endShortcut, forKey: "endShortcut") } }
    @Published var overlayStyle: OverlayStyle { didSet { d.set(overlayStyle.rawValue, forKey: "overlayStyle") } }
    @Published var defaultMinutes: Int { didSet { d.set(defaultMinutes, forKey: "defaultMinutes") } }
    @Published var playEndSound: Bool { didSet { d.set(playEndSound, forKey: "playEndSound") } }

    init() {
        startShortcut = d.string(forKey: "startShortcut") ?? ""
        endShortcut = d.string(forKey: "endShortcut") ?? ""
        overlayStyle = OverlayStyle(rawValue: d.string(forKey: "overlayStyle") ?? "") ?? .frosted
        let m = d.integer(forKey: "defaultMinutes")
        defaultMinutes = m > 0 ? m : 25
        playEndSound = d.object(forKey: "playEndSound") as? Bool ?? true
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Ekagrachit: launch at login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}

/// The app's single owner of session side effects.
///
/// It feeds events into the pure `SessionStateMachine` and executes the
/// effects it returns. Everything runs on the main thread: bridge callbacks
/// are delivered on the main queue, timers are main-run-loop timers.
@MainActor
final class FocusSessionCoordinator: ObservableObject {
    @Published private(set) var machine = MachineState()
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var accessibilityTrusted = Permissions.accessibilityTrusted
    @Published private(set) var extensionVersion: String?
    @Published private(set) var bridgeError: String?
    @Published var message: String?
    /// Where the unpacked extension lives for Chrome to load (copied from the app bundle).
    @Published private(set) var extensionFolder: URL?
    /// Version of the extension bundled with this app.
    @Published private(set) var bundledExtensionVersion: String?
    /// URL of Chrome's active tab, offered to prefill the start form.
    @Published private(set) var suggestedTarget: String?
    /// A start is waiting for Chrome/the extension to come up.
    @Published private(set) var waitingForChrome = false

    static let showSetupNotification = Notification.Name("EkagrachitShowSetup")
    static let chromeBundleID = "com.google.Chrome"
    private var pendingStart: (target: String, minutes: Int, until: Date)?
    private var pendingTabCID: String?
    /// Extension versions we already asked to reload (once per version, per app run: no loops).
    private var reloadRequested: Set<String> = []

    let settings = AppSettings()
    private let clock = SystemClock.shared
    private let store = SessionStore(url: Paths.sessionFile)
    private let bridge = BridgeServer(path: Paths.socketPath, deliveryQueue: .main)
    private let tracker = WindowTracker()
    private let overlays = OverlayManager()
    private let confirmPanel = ConfirmEndPanel()
    private let epoch = BridgeProtocol.newSid()
    private var seq = 0
    private var activeConnection: BridgeServer.ConnectionID?
    private var helloed: [BridgeServer.ConnectionID] = []
    private var browserPids: [BridgeServer.ConnectionID: Int32] = [:]
    private var tickTimer: Timer?
    private var focusTimer: Timer?
    private var locateTimer: Timer?
    private var hotKey: HotKey?
    private var quickStartHotKey: HotKey?
    /// Windows the user can choose as a focus target (refreshed when the menu opens).
    @Published private(set) var windowChoices: [WindowCandidate] = []
    /// The app the user was in before opening Ekagrachit's menu.
    private(set) var lastExternalApp: NSRunningApplication?
    /// Set when ⌃⌥⌘F was pressed on a browser: start on its active tab when it answers.
    private var quickStartWebCID: String?
    private var lastRefocus = Date.distantPast
    private var lastAssessmentLog = ""
    private var focusDebouncer = FocusLossDebouncer()
    private var hudFlash: (text: String, until: Date)?
    private let toast = ToastPanel()
    private var exemptPidsCache: Set<Int32> = []
    private var exemptPidsAt = Date.distantPast
    private var ticks = 0
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"

    var phase: Phase { machine.phase }
    var isSessionRunning: Bool { machine.phase != .idle }
    var extensionConnected: Bool { machine.extensionConnected }

    // MARK: - Lifecycle

    func start() {
        registerHostAndExtension()
        overlays.style = settings.overlayStyle
        settings.$overlayStyle.sink { [weak self] s in self?.overlays.style = s }.store(in: &cancellables)
        overlays.onClick = { [weak self] in self?.refocus(force: true) }
        overlays.hud.onEnd = { [weak self] in self?.presentEndConfirmation() }
        confirmPanel.onConfirm = { [weak self] in
            self?.confirmPanel.dismiss()
            self?.dispatch(.endRequested(.userEnded))
        }
        confirmPanel.onCancel = { [weak self] in
            self?.confirmPanel.dismiss()
            self?.refocus(force: true)
        }

        bridge.onConnect = { _ in }
        bridge.onMessage = { [weak self] msg, id in MainActor.assumeIsolated { self?.handle(msg, from: id) } }
        bridge.onDisconnect = { [weak self] id in MainActor.assumeIsolated { self?.connectionClosed(id) } }
        do {
            try bridge.start()
        } catch {
            bridgeError = "Could not open the extension bridge: \(error)"
        }

        if let persisted = store.load() {
            dispatch(.restore(persisted))
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observeSystem()
        quickStartHotKey = HotKey(keyCode: HotKey.quickStartKeyCode, modifiers: HotKey.emergencyModifiers) { [weak self] in
            MainActor.assumeIsolated { self?.focusFrontmostWindow() }
        }
    }

    /// Makes installation "drag to Applications": register the bundled native
    /// messaging host with every installed Chromium browser and keep the
    /// loadable copy of the extension in sync with the one in the bundle.
    private func registerHostAndExtension() {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        if let src = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) {
            let dst = Paths.supportDirectory.appendingPathComponent("Chrome Extension", isDirectory: true)
            do {
                try NativeHostRegistration.syncExtension(from: src, to: dst)
                extensionFolder = dst
            } catch {
                NSLog("Ekagrachit: could not copy the Chrome extension: \(error)")
            }
            if let data = try? Data(contentsOf: src.appendingPathComponent("manifest.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bundledExtensionVersion = obj["version"] as? String
            }
        }
        guard env["EKAGRACHIT_NO_HOST_REGISTRATION"] != "1" else { return }
        let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ekagrachit-host")
        // Chrome executes the host directly. If the app came from a downloaded
        // DMG, the user approved the app (Open Anyway) but the helper still
        // carries the quarantine flag, which can make macOS refuse to run it
        // when Chrome starts it. Clear it on our own bundled helper.
        _ = removexattr(host.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard fm.isExecutableFile(atPath: host.path),
              let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let result = NativeHostRegistration.register(hostPath: host.path, applicationSupport: support)
        if !result.failed.isEmpty { NSLog("Ekagrachit: could not register the native host for \(result.failed)") }
    }

    func revealExtensionFolder() {
        guard let folder = extensionFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func openChromeExtensionsPage() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeBundleID),
              let url = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Ask the extension for the active tab's URL (menu prefill).
    func refreshSuggestion() {
        suggestedTarget = nil // so the same URL fills the (cleared) field again
        guard let id = activeConnection, machine.phase == .idle else { return }
        let cid = BridgeProtocol.newSid()
        pendingTabCID = cid
        bridge.send(.activeTabRequest(cid: cid), to: id)
    }

    /// Called on app termination (logout, update, kill via Quit when idle).
    /// Overlays die with the process; the persisted session (if any) lets a
    /// relaunch resume it until its deadline.
    func prepareForTermination() {
        overlays.hide()
        bridge.stop()
    }

    // MARK: - User intents

    /// Refresh the list of windows offered in the menu.
    func refreshWindowChoices() {
        windowChoices = WindowCandidates.rank(tracker.candidates(), ownBundleID: Bundle.main.bundleIdentifier)
    }

    /// The app the user was in when they opened the menu: the frontmost app,
    /// unless that is Ekagrachit itself (then the last other app activated).
    var appBeforeMenu: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { return front }
        return lastExternalApp
    }

    /// The menu's choice for an app: its focused window if listed, else its frontmost listed window.
    func frontWindowChoice(of pid: Int32) -> WindowCandidate? {
        let mine = windowChoices.filter { $0.pid == pid }
        if let focused = tracker.focusedWindowBounds(pid: pid),
           let w = mine.first(where: { $0.bounds.approximatelyEquals(focused, tolerance: WindowMatching.boundsTolerance) }) {
            return w
        }
        return mine.first
    }

    /// The window a hotkey or URL should focus for an app: its focused (key)
    /// window, else its frontmost real window. Never a tiny helper window.
    private func frontWindow(pid: Int32? = nil, bundleID: String? = nil) -> WindowCandidate? {
        let all = WindowCandidates.rank(tracker.candidates(), ownBundleID: Bundle.main.bundleIdentifier, limit: 200)
        let mine = all.filter { c in (pid.map { c.pid == $0 } ?? true) && (bundleID.map { c.bundleID == $0 } ?? true) }
        if let p = mine.first?.pid, let focused = tracker.focusedWindowBounds(pid: p),
           let w = mine.first(where: { $0.pid == p && $0.bounds.approximatelyEquals(focused, tolerance: WindowMatching.boundsTolerance) }) {
            return w
        }
        return mine.first
    }

    /// Focus a native Mac window (Word, Pages, Cursor, iTerm2, …). No browser involved.
    @discardableResult
    func startAppSession(_ target: NativeWindowTarget, minutes: Int) -> String? {
        guard (1...480).contains(minutes) else { return report("Choose a duration between 1 and 480 minutes.") }
        accessibilityTrusted = Permissions.accessibilityTrusted
        let allowUntrusted = ProcessInfo.processInfo.environment["EKAGRACHIT_ALLOW_WITHOUT_ACCESSIBILITY"] == "1"
        guard accessibilityTrusted || allowUntrusted else {
            Permissions.requestAccessibility()
            return report("Ekagrachit needs the Accessibility permission to keep your window in front. Grant it in System Settings → Privacy & Security → Accessibility, then start again.")
        }
        Log.info("start app session: \(target.bundleID) window \(target.windowNumber.map(String.init) ?? "?")")
        tracker.beginSession(browserPid: target.pid)
        if let rejection = dispatch(.startAppRequested(sid: BridgeProtocol.newSid(), app: target, duration: TimeInterval(minutes * 60))) {
            return report(rejection)
        }
        message = nil
        closeMenuWindow()
        return nil
    }

    /// ⌃⌥⌘F: focus whatever you're looking at, for your usual duration.
    func focusFrontmostWindow(minutes: Int? = nil) {
        guard !isSessionRunning else { return }
        let m = minutes ?? settings.defaultMinutes
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let bundle = front.bundleIdentifier ?? ""
        if WindowCandidates.browserBundleIDs.contains(bundle) {
            guard let id = activeConnection else {
                toast.show("To focus a web page, set up the Chrome extension (menu → Set Up…)", for: 5)
                return
            }
            let cid = BridgeProtocol.newSid()
            quickStartWebCID = cid
            pendingQuickMinutes = m
            bridge.send(.activeTabRequest(cid: cid), to: id)
            return
        }
        guard let window = frontWindow(pid: front.processIdentifier) else {
            toast.show("Bring the window you want to focus on to the front, then press \(HotKey.quickStartDisplay)", for: 5)
            return
        }
        if let error = startAppSession(window.target, minutes: m) { toast.show(error, for: 6) }
    }

    private var pendingQuickMinutes = 25

    /// ekagrachit://focus?url=…|app=<bundle id>|window=front[&minutes=N]
    /// (for Shortcuts, Raycast, Alfred, scripts). There is deliberately no URL
    /// to end a session: ending stays a deliberate, held action.
    func handleURL(_ url: URL) {
        guard url.scheme == "ekagrachit", url.host == "focus",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        let q = Dictionary(items.compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        let minutes = q["minutes"].flatMap(Int.init) ?? settings.defaultMinutes
        var error: String?
        if let target = q["url"] {
            error = startSession(target: target, minutes: minutes)
        } else if let bundle = q["app"] {
            if let w = frontWindow(bundleID: bundle) {
                error = startAppSession(w.target, minutes: minutes)
            } else {
                error = "No open window of \(bundle) to focus on."
            }
        } else if q["window"] == "front" {
            focusFrontmostWindow(minutes: minutes)
        }
        if let error { toast.show(error, for: 6) }
    }

    /// Returns an error message, or nil if the session is starting.
    @discardableResult
    func startSession(target: String, minutes: Int) -> String? {
        let normalized: String
        switch TargetValidation.normalize(target) {
        case let .success(u): normalized = u
        case let .failure(e): return report(e.description)
        }
        guard (1...480).contains(minutes) else { return report("Choose a duration between 1 and 480 minutes.") }
        accessibilityTrusted = Permissions.accessibilityTrusted
        // Test rigs without a TCC grant may opt out; raising then falls back to app activation.
        let allowUntrusted = ProcessInfo.processInfo.environment["EKAGRACHIT_ALLOW_WITHOUT_ACCESSIBILITY"] == "1"
        guard accessibilityTrusted || allowUntrusted else {
            Permissions.requestAccessibility()
            return report("Ekagrachit needs the Accessibility permission to keep the focus window in front. Grant it in System Settings → Privacy & Security → Accessibility, then start again.")
        }
        guard let pid = currentBrowserPid() else {
            return deferUntilChromeIsReady(target: normalized, minutes: minutes)
        }
        Log.info("start web session")
        tracker.beginSession(browserPid: pid)
        if let rejection = dispatch(.startRequested(sid: BridgeProtocol.newSid(), target: normalized, duration: TimeInterval(minutes * 60))) {
            return report(rejection)
        }
        message = nil
        closeMenuWindow()
        return nil
    }

    /// No extension connected: open Chrome if needed and start as soon as the
    /// extension says hello (or give a clear error after 20 s).
    private func deferUntilChromeIsReady(target: String, minutes: Int) -> String? {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeBundleID) else {
            return report("Google Chrome is not installed. Ekagrachit opens your document in Chrome.")
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleID).isEmpty {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: chrome, configuration: config)
        }
        pendingStart = (target, minutes, Date().addingTimeInterval(20))
        waitingForChrome = true
        message = nil
        return nil
    }

    private func checkPendingStart() {
        guard let p = pendingStart else { return }
        if activeConnection != nil, browserPids[activeConnection!] != nil {
            pendingStart = nil
            waitingForChrome = false
            if let error = startSession(target: p.target, minutes: p.minutes) { toast.show(error, for: 6) }
        } else if Date() > p.until {
            pendingStart = nil
            waitingForChrome = false
            let text = "Chrome is open, but the Ekagrachit extension didn't connect. Check that it is installed and enabled."
            message = text
            toast.show(text, for: 6)
        }
    }

    /// The menu-bar window must not stay open over the focus window.
    /// Opens the menu-bar window, as if its ◎ had been clicked (the Chrome
    /// toolbar button asks for this). Uses Accessibility to press our own
    /// status item: on macOS 26 menu-bar extras are hosted by the system, so
    /// there is no in-process window to click.
    func openMenuWindow() {
        if let w = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtra") }) {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var bar: CFTypeRef?
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let item = (kids as? [AXUIElement])?.first else {
            Log.info("show_menu: status item not found")
            toast.show("Click ◎ in the menu bar to choose what to focus on.", for: 4)
            return
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if result != .success { Log.info("show_menu: press failed \(result.rawValue)") }
    }

    private func closeMenuWindow() {
        for w in NSApp.windows where w.isVisible && String(describing: type(of: w)).contains("MenuBarExtra") {
            Log.info("closing menu window")
            w.close()
        }
    }

    /// Cancel while still preparing (nothing is enforced yet), or ask for
    /// deliberate confirmation once the session is active.
    func requestEnd() {
        switch machine.phase {
        case .preparing: dispatch(.endRequested(.userEnded))
        case .active, .degraded: presentEndConfirmation()
        default: break
        }
    }

    func presentEndConfirmation() {
        guard machine.phase == .active || machine.phase == .degraded || machine.phase == .preparing else { return }
        confirmPanel.present()
    }

    func refreshPermissions() {
        accessibilityTrusted = Permissions.accessibilityTrusted
    }

    @discardableResult
    private func report(_ s: String) -> String {
        message = s
        return s
    }

    // MARK: - State machine plumbing

    /// Applies an event; returns a rejection message if the request was refused.
    @discardableResult
    func dispatch(_ event: MachineEvent) -> String? {
        let t = SessionStateMachine.reduce(machine, event, now: clock.now())
        if let r = t.rejection { return r }
        machine = t.state
        for e in t.effects { perform(e) }
        updateRemaining()
        if machine.phase == .idle {
            hotKey = nil
        } else if hotKey == nil {
            hotKey = HotKey(keyCode: HotKey.emergencyKeyCode, modifiers: HotKey.emergencyModifiers) { [weak self] in
                MainActor.assumeIsolated { self?.presentEndConfirmation() }
            }
        }
        return nil
    }

    /// Captured when a session starts (the session is cleared by the time it ends).
    private var lastSessionMinutes = 0
    /// Wall-clock start and planned end of the running session, and its app target (for the ledger and the end toast).
    private var sessionSpan: (start: TimeInterval, end: TimeInterval, app: NativeWindowTarget?)?
    /// Focused time per day, kept locally (dates and durations only).
    @Published private(set) var ledger: FocusLedger = {
        guard let data = UserDefaults.standard.data(forKey: "focusLedger"),
              let l = try? JSONDecoder().decode(FocusLedger.self, from: data) else { return FocusLedger() }
        return l
    }()
    var ledgerSummary: String? { ledger.summary(on: Date(), calendar: .current) }

    private func perform(_ effect: MachineEffect) {
        switch effect {
        case .syncExtension:
            sendSync()
        case let .locateAppWindow(app):
            startLocatingApp(app)
        case let .locateNativeWindow(_, bounds):
            startLocating(bounds)
        case .stopWindowTracking:
            locateTimer?.invalidate()
            locateTimer = nil
            tracker.stop()
        case .showOverlays:
            guard let sid = machine.session?.sid else { return }
            guard !NSScreen.screens.isEmpty else {
                dispatch(.overlayFailed(sid: sid))
                return
            }
            overlays.show(hole: tracker.focusInfo()?.bounds, shielded: false)
            startFocusLoop()
            dispatch(.overlaysShown(sid: sid))
        case .hideOverlays:
            stopFocusLoop()
            confirmPanel.dismiss()
            overlays.hide()
        case .persist:
            guard let s = machine.session else { return }
            do {
                try store.save(PersistedSession(sid: s.sid, target: s.target, startedAt: s.startedAt, deadline: s.deadline, app: s.app))
            } catch {
                Log.info("could not save session: \(error)")
                message = "This session couldn't be saved, so it won't survive a restart. It is still running."
            }
        case .clearPersisted:
            store.clear()
        case .sessionStarted:
            lastSessionMinutes = sessionMinutes
            sessionSpan = machine.session.map { (start: $0.startedAt, end: $0.deadline.wall, app: $0.app) }
            closeMenuWindow()
            runShortcut(settings.startShortcut)
        case let .sessionEnded(reason):
            runShortcut(settings.endShortcut)
            let span = sessionSpan
            sessionSpan = nil
            if let span, [EndReason.expired, .userEnded, .extensionEnded].contains(reason) {
                let now = Date()
                let focused = max(0, min(now.timeIntervalSince1970, span.end) - span.start)
                ledger.record(seconds: focused, endedAt: now, calendar: .current)
                if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: "focusLedger") }
            }
            if reason == .expired {
                let minutes = lastSessionMinutes
                var text = "Session complete"
                if minutes > 0 {
                    if let app = span?.app {
                        let title = app.title.count > 40 ? String(app.title.prefix(39)) + "…" : app.title
                        let what = title.isEmpty ? app.appName : title
                        text += " · \(minutes) minutes with \(what)"
                    } else {
                        text += " · \(minutes) minutes of one-pointed attention"
                    }
                }
                let today = ledger.seconds(on: Date(), calendar: .current)
                if today > minutes * 60 + 60 { text += " · \(FocusLedger.format(seconds: today)) today" }
                toast.show(text, for: 5)
                if settings.playEndSound { NSSound(named: "Glass")?.play() }
            }
            switch reason {
            case .expired, .userEnded: message = nil
            case .startFailed:
                message = message ?? (span?.app != nil
                    ? "That window couldn't be found. Is it still open?"
                    : "The focus window could not be set up. Is the Chrome extension enabled?")
            case .recoveryFailed: message = "The previous session could not be restored and was ended."
            case .extensionEnded: message = nil
            case .degradedTimeout: message = "The focus window could not be restored, so the session was ended."
            case .overlayFailed: message = "The screen overlay could not be created, so the session was not started."
            }
        case .refocus:
            refocus(force: true)
        }
    }

    private func sendSync() {
        guard let id = activeConnection else { return }
        seq += 1
        bridge.send(.sync(epoch: epoch, seq: seq, session: SessionStateMachine.desiredSession(machine, now: clock.now())), to: id)
    }

    private func tick() {
        ticks += 1
        checkPendingStart()
        dispatch(.tick)
        if isSessionRunning, ticks % 10 == 0 { sendSync() } // heals anything lost in transit
        if ticks % 2 == 0 { accessibilityTrusted = Permissions.accessibilityTrusted }
        updateHUD()
    }

    /// 0 at the start of the session, 1 at its end.
    var sessionProgress: Double {
        guard let s = machine.session else { return 0 }
        let total = s.deadline.wall - s.startedAt
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    /// The planned length of the current session, in whole minutes.
    var sessionMinutes: Int {
        guard let s = machine.session else { return 0 }
        return Int(((s.deadline.wall - s.startedAt) / 60).rounded())
    }

    private func updateRemaining() {
        remaining = machine.session.map { $0.deadline.remaining(at: clock.now()) } ?? 0
    }

    // MARK: - Bridge

    private func handle(_ msg: AppInbound, from id: BridgeServer.ConnectionID) {
        switch msg {
        case let .hostHello(pid, _):
            browserPids[id] = pid
            return
        case let .hello(protocolVersion, extVersion, _, standalone):
            guard protocolVersion == BridgeProtocol.version else {
                bridge.send(.error(code: "protocol_mismatch", message: "Ekagrachit app speaks protocol v\(BridgeProtocol.version)"), to: id)
                bridgeError = "The Chrome extension uses protocol v\(protocolVersion); please update both components."
                return
            }
            helloed.removeAll { $0 == id }
            helloed.append(id)
            activeConnection = id
            extensionVersion = extVersion
            bridgeError = nil
            bridge.send(.helloAck(appVersion: appVersion, epoch: epoch), to: id)
            if let s = standalone, machine.phase == .idle, case let .success(target) = TargetValidation.normalize(s.target) {
                // A session started in the browser while the app was not running: adopt it.
                if let pid = browserPids[id] { tracker.beginSession(browserPid: pid) }
                dispatch(.adoptRequested(sid: s.sid, target: target, remaining: s.remainingMs / 1000))
            }
            dispatch(.extensionConnected)
            if let bundled = bundledExtensionVersion, bundled != extVersion, machine.phase == .idle, !reloadRequested.contains(extVersion) {
                // This app ships a different extension build (it was just copied
                // to the extension folder): have the idle extension reload itself.
                reloadRequested.insert(extVersion)
                bridge.send(.reload, to: id)
            }
            checkPendingStart()
            return
        default:
            break
        }
        guard id == activeConnection else {
            // Only the active (hello'd) extension may drive the session. Answer
            // requests explicitly instead of letting the caller time out.
            if case let .startRequest(cid, _, _) = msg {
                bridge.send(.startResult(cid: cid, ok: false, error: "Handshake not complete; try again."), to: id)
            }
            return
        }

        switch msg {
        case let .startRequest(cid, target, minutes):
            let t0 = Date()
            Log.info("start_request received")
            let error = startSession(target: target, minutes: minutes)
            bridge.send(.startResult(cid: cid, ok: error == nil, error: error), to: id)
            Log.info("start_result sent after \(Int(Date().timeIntervalSince(t0) * 1000)) ms (ok: \(error == nil))")
        case let .endRequest(sid):
            // The extension UI already required a hold-to-confirm.
            if machine.session?.sid == sid { dispatch(.endRequested(.userEnded)) }
        case let .windowReady(sid, windowId, tabId, bounds, _):
            if let pid = browserPids[id] ?? currentBrowserPid() { tracker.setBrowserPid(pid) }
            dispatch(.windowReady(sid: sid, windowId: windowId, tabId: tabId, bounds: bounds))
        case let .windowBounds(sid, windowId, bounds, _):
            dispatch(.windowBounds(sid: sid, windowId: windowId, bounds: bounds))
        case let .windowLost(sid):
            dispatch(.windowLost(sid: sid))
        case let .violation(_, _, host):
            flashHUD(host.map { "Saved for later: \($0)" } ?? "Back to your focus")
            evaluateFocus()
        case let .activeTab(cid, url):
            if cid == quickStartWebCID {
                quickStartWebCID = nil
                if url.hasPrefix("http") {
                    if let error = startSession(target: url, minutes: pendingQuickMinutes) { toast.show(error, for: 6) }
                } else {
                    toast.show("Open the page you want to focus on, then press \(HotKey.quickStartDisplay)", for: 5)
                }
            } else if cid == pendingTabCID, url.hasPrefix("http") {
                suggestedTarget = url
            }
        case let .sessionClosed(sid, _):
            dispatch(.extensionClosed(sid: sid))
        case let .error(sid, code, text):
            // Technical detail goes to the log; people get a sentence.
            Log.info("extension error \(code): \(text)")
            if sid == nil || sid == machine.session?.sid { message = Self.friendly(code: code) }
        case .showMenu:
            openMenuWindow()
        case .hostHello, .hello:
            break
        }
    }

    static func friendly(code: String) -> String {
        switch code {
        case "window_create_failed": return "Chrome couldn't open a focus window. Try again in a moment."
        case "invalid_target": return "That link can't be focused on. Try copying it from the address bar."
        default: return "Something went wrong in Chrome. Try again in a moment."
        }
    }

    private func connectionClosed(_ id: BridgeServer.ConnectionID) {
        browserPids[id] = nil
        helloed.removeAll { $0 == id }
        guard id == activeConnection else { return }
        activeConnection = helloed.last
        if activeConnection == nil {
            extensionVersion = nil
            dispatch(.extensionDisconnected)
        } else {
            dispatch(.extensionConnected)
        }
    }

    private func currentBrowserPid() -> Int32? {
        if let id = activeConnection, let pid = browserPids[id] { return pid }
        guard activeConnection != nil else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.processIdentifier
    }

    // MARK: - Window tracking

    /// Native target: look for its window until found (the state machine's
    /// timeouts end the session if it never appears).
    private func startLocatingApp(_ app: NativeWindowTarget) {
        locateTimer?.invalidate()
        let attempt: () -> Bool = { [weak self] in
            guard let self, let sid = self.machine.session?.sid, self.machine.session?.app != nil else { return true }
            if let c = self.tracker.locateApp(app) {
                self.dispatch(.nativeWindowFound(sid: sid, window: c.number))
                return true
            }
            return false
        }
        if attempt() { return }
        locateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if attempt() {
                    timer.invalidate()
                    if self?.locateTimer === timer { self?.locateTimer = nil }
                }
            }
        }
    }

    private func startLocating(_ bounds: Rect) {
        locateTimer?.invalidate()
        var attempts = 0
        let attempt: () -> Bool = { [weak self] in
            guard let self, let sid = self.machine.session?.sid else { return true }
            attempts += 1
            if let number = self.tracker.locate(reported: bounds, allowFallback: attempts > 15) {
                self.dispatch(.nativeWindowFound(sid: sid, window: number))
                return true
            }
            return attempts >= 80 // ~8 s; the state machine's timeouts take it from there
        }
        if attempt() { return }
        locateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if attempt() {
                    timer.invalidate()
                    if self?.locateTimer === timer { self?.locateTimer = nil }
                }
            }
        }
    }

    // MARK: - Focus enforcement loop

    private func startFocusLoop() {
        guard focusTimer == nil else { return }
        // 10 Hz: two cheap CGWindowList queries for a single window. Event
        // notifications (app activation, Space change, extension violations)
        // trigger immediate evaluations in between.
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateFocus() }
        }
        focusTimer?.tolerance = 0.02
    }

    private func stopFocusLoop() {
        focusTimer?.invalidate()
        focusTimer = nil
    }

    private func evaluateFocus() {
        guard let session = machine.session, overlays.isShown, machine.phase != .ending, machine.phase != .idle else { return }
        let info = tracker.focusInfo()
        if session.nativeWindow != nil, info == nil {
            dispatch(.nativeWindowGone(sid: session.sid))
        }
        let front = NSWorkspace.shared.frontmostApplication
        let above = info == nil ? [] : tracker.windowsAbove()
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let patches = info.map {
            FocusPolicy.intruderPatches(focus: $0.bounds, above: above, browserPid: tracker.browserPid, ownPid: ownPid,
                                        overlayLayer: overlayLevel.rawValue, excludedPids: patchExcludedPids())
        } ?? []
        let assessment = FocusPolicy.assess(
            focus: info,
            above: above,
            frontmostPid: front?.processIdentifier,
            frontmostBundleID: front?.bundleIdentifier,
            browserPid: tracker.browserPid,
            ownPid: ProcessInfo.processInfo.processIdentifier
        )
        let summary = "\(assessment) front=\(front?.bundleIdentifier ?? "-") focus=\(info.map { "\($0.number)@\($0.bounds)" } ?? "none")"
        if summary != lastAssessmentLog {
            lastAssessmentLog = summary
            Log.info("focus: \(summary)")
        }
        switch focusDebouncer.next(assessment, frontmostIsBrowser: front?.processIdentifier == tracker.browserPid, now: clock.now()) {
        case .openHole:
            overlays.setSuspended(false)
            overlays.show(hole: info?.bounds, shielded: false, patches: patches)
        case .closeHoleAndRefocus:
            if hudFlash == nil || hudFlash!.until < Date() { flashHUD("Back to your focus") }
            overlays.setSuspended(false)
            overlays.show(hole: info?.bounds, shielded: true) // close the hole first, then restore
            refocus(force: false)
        case .coverAllAndRefocus:
            overlays.setSuspended(false)
            overlays.show(hole: nil, shielded: true)
            refocus(force: false)
        case .standAside:
            overlays.setSuspended(true)
        }
    }

    /// Pids never patched over: system security UI, and the Dock (handled by
    /// clipping the hole to each screen's visible frame). Cached for 2 s.
    private func patchExcludedPids() -> Set<Int32> {
        let now = Date()
        if now.timeIntervalSince(exemptPidsAt) > 2 {
            exemptPidsCache = Set(NSWorkspace.shared.runningApplications
                .filter { app in app.bundleIdentifier.map { FocusPolicy.exemptBundleIDs.contains($0) || $0 == "com.apple.dock" } ?? false }
                .map(\.processIdentifier))
            exemptPidsAt = now
        }
        return exemptPidsCache
    }

    private func refocus(force: Bool) {
        guard let sid = machine.session?.sid, machine.phase == .active || machine.phase == .degraded || machine.phase == .preparing else { return }
        if confirmPanel.isVisible { return } // the user is deciding; don't steal focus from the panel
        let now = Date()
        if !force, now.timeIntervalSince(lastRefocus) < 0.3 { return }
        lastRefocus = now
        tracker.raise(info: tracker.focusInfo())
        if machine.session?.isWeb == true, let id = activeConnection { bridge.send(.focus(sid: sid), to: id) }
    }

    /// Brief, quiet feedback in the pill so a blocked action isn't silent.
    private func flashHUD(_ text: String) {
        hudFlash = (text, Date().addingTimeInterval(2.5))
        updateHUD()
    }

    private func updateHUD() {
        guard overlays.isShown else { return }
        var detail: String?
        if let flash = hudFlash, flash.until > Date() {
            detail = flash.text
        } else if machine.phase == .active, remaining <= 60 {
            detail = "Ending soon"
        } else if machine.phase == .degraded {
            switch machine.session?.degradedReason {
            case .extensionDisconnected?: detail = "Chrome extension disconnected"
            case .focusWindowMissing?: detail = "Reopening focus window…"
            case nil: detail = nil
            }
        } else if !accessibilityTrusted {
            detail = "Limited: Accessibility off"
        }
        overlays.hud.update(remaining: remaining, fraction: sessionProgress, detailText: detail)
    }

    // MARK: - System events

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let evaluate: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.evaluateFocus() } }
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.lastExternalApp = app }
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: evaluate))
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: evaluate))
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlays.invalidate()
                self?.tick() // a session whose deadline passed during sleep ends now
                self?.evaluateFocus()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlays.invalidate()
                self?.evaluateFocus()
            }
        })
    }

    // MARK: - Shortcuts integration (optional Focus / Do Not Disturb)

    /// Runs a user-chosen Shortcut via the supported `shortcuts` CLI. macOS has
    /// no public API for apps to toggle Focus modes; a Shortcut with
    /// "Set Focus" is the supported, user-controlled way.
    private func runShortcut(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", trimmed]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            message = "Could not run Shortcut \"\(trimmed)\": \(error.localizedDescription)"
        }
    }
}
