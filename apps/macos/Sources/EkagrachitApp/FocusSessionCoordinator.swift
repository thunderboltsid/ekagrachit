import AppKit
import Combine
import EkagrachitCore
import ServiceManagement

/// User preferences (UserDefaults). Never stores URLs or history.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var startShortcut: String { didSet { d.set(startShortcut, forKey: "startShortcut") } }
    @Published var endShortcut: String { didSet { d.set(endShortcut, forKey: "endShortcut") } }
    @Published var overlayStyle: OverlayStyle { didSet { d.set(overlayStyle.rawValue, forKey: "overlayStyle") } }
    @Published var defaultMinutes: Int { didSet { d.set(defaultMinutes, forKey: "defaultMinutes") } }

    init() {
        startShortcut = d.string(forKey: "startShortcut") ?? ""
        endShortcut = d.string(forKey: "endShortcut") ?? ""
        overlayStyle = OverlayStyle(rawValue: d.string(forKey: "overlayStyle") ?? "") ?? .frosted
        let m = d.integer(forKey: "defaultMinutes")
        defaultMinutes = m > 0 ? m : 25
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
    private var lastRefocus = Date.distantPast
    private var focusDebouncer = FocusLossDebouncer()
    private var ticks = 0
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"

    var phase: Phase { machine.phase }
    var isSessionRunning: Bool { machine.phase != .idle }
    var extensionConnected: Bool { machine.extensionConnected }

    // MARK: - Lifecycle

    func start() {
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
    }

    /// Called on app termination (logout, update, kill via Quit when idle).
    /// Overlays die with the process; the persisted session (if any) lets a
    /// relaunch resume it until its deadline.
    func prepareForTermination() {
        overlays.hide()
        bridge.stop()
    }

    // MARK: - User intents

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
        guard accessibilityTrusted else {
            Permissions.requestAccessibility()
            return report("Ekagrachit needs the Accessibility permission to keep the focus window in front. Grant it in System Settings → Privacy & Security → Accessibility, then start again.")
        }
        guard let pid = currentBrowserPid() else {
            return report("The Ekagrachit Chrome extension is not connected. Open Chrome and make sure the extension is installed.")
        }
        tracker.beginSession(browserPid: pid)
        if let rejection = dispatch(.startRequested(sid: BridgeProtocol.newSid(), target: normalized, duration: TimeInterval(minutes * 60))) {
            return report(rejection)
        }
        message = nil
        return nil
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

    private func perform(_ effect: MachineEffect) {
        switch effect {
        case .syncExtension:
            sendSync()
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
                try store.save(PersistedSession(sid: s.sid, target: s.target, startedAt: s.startedAt, deadline: s.deadline))
            } catch {
                message = "Could not save session state: \(error.localizedDescription)"
            }
        case .clearPersisted:
            store.clear()
        case .sessionStarted:
            runShortcut(settings.startShortcut)
        case let .sessionEnded(reason):
            runShortcut(settings.endShortcut)
            switch reason {
            case .expired, .userEnded: message = nil
            case .startFailed: message = message ?? "The focus window could not be set up. Is the Chrome extension enabled?"
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
        dispatch(.tick)
        if isSessionRunning, ticks % 10 == 0 { sendSync() } // heals anything lost in transit
        if ticks % 2 == 0 { accessibilityTrusted = Permissions.accessibilityTrusted }
        updateHUD()
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
            return
        default:
            break
        }
        guard id == activeConnection else { return } // only the active extension may drive the session

        switch msg {
        case let .startRequest(cid, target, minutes):
            let error = startSession(target: target, minutes: minutes)
            bridge.send(.startResult(cid: cid, ok: error == nil, error: error), to: id)
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
        case .violation:
            evaluateFocus()
        case let .sessionClosed(sid, _):
            dispatch(.extensionClosed(sid: sid))
        case let .error(sid, _, text):
            if sid == nil || sid == machine.session?.sid { message = text }
        case .hostHello, .hello:
            break
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
        let assessment = FocusPolicy.assess(
            focus: info,
            above: info == nil ? [] : tracker.windowsAbove(),
            frontmostPid: front?.processIdentifier,
            frontmostBundleID: front?.bundleIdentifier,
            browserPid: tracker.browserPid,
            ownPid: ProcessInfo.processInfo.processIdentifier
        )
        switch focusDebouncer.next(assessment, frontmostIsBrowser: front?.processIdentifier == tracker.browserPid, now: clock.now()) {
        case .openHole:
            overlays.setSuspended(false)
            overlays.show(hole: info?.bounds, shielded: false)
        case .closeHoleAndRefocus:
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

    private func refocus(force: Bool) {
        guard let sid = machine.session?.sid, machine.phase == .active || machine.phase == .degraded || machine.phase == .preparing else { return }
        if confirmPanel.isVisible { return } // the user is deciding; don't steal focus from the panel
        let now = Date()
        if !force, now.timeIntervalSince(lastRefocus) < 0.3 { return }
        lastRefocus = now
        tracker.raise(info: tracker.focusInfo())
        if let id = activeConnection { bridge.send(.focus(sid: sid), to: id) }
    }

    private func updateHUD() {
        guard overlays.isShown else { return }
        var detail: String?
        if machine.phase == .degraded {
            switch machine.session?.degradedReason {
            case .extensionDisconnected?: detail = "Chrome extension disconnected"
            case .focusWindowMissing?: detail = "Reopening focus window…"
            case nil: detail = nil
            }
        } else if !accessibilityTrusted {
            detail = "Limited: Accessibility off"
        }
        overlays.hud.update(remaining: remaining, detailText: detail)
    }

    // MARK: - System events

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let evaluate: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.evaluateFocus() } }
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
