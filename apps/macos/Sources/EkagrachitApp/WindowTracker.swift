import AppKit
import ApplicationServices
import EkagrachitCore

/// Reads window geometry from the window server and raises the focus window.
///
/// - Geometry/ordering uses CGWindowListCopyWindowInfo, which needs no
///   permission for bounds, owner pid and layer (titles would need Screen
///   Recording, and are never read).
/// - Raising a specific window of another app uses the Accessibility API
///   (requires the Accessibility permission). Without it we fall back to
///   NSRunningApplication activation plus the extension's own
///   chrome.windows.update(focused: true).
@MainActor
final class WindowTracker {
    private(set) var focusWindow: UInt32?
    private(set) var browserPid: Int32 = 0
    private var preSessionWindows: Set<UInt32> = []

    // MARK: Queries

    static func parse(_ dict: [String: Any]) -> WindowInfo? {
        guard let number = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
              let cg = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        let onScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return WindowInfo(number: number, pid: pid, layer: layer,
                          bounds: Rect(x: cg.origin.x, y: cg.origin.y, width: cg.width, height: cg.height),
                          onScreen: onScreen, alpha: alpha)
    }

    static func list(_ option: CGWindowListOption, relativeTo window: UInt32 = 0) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(option, CGWindowID(window)) as? [[String: Any]] else { return [] }
        return raw.compactMap(parse)
    }

    /// Current info for the tracked focus window (nil if it no longer exists).
    func focusInfo() -> WindowInfo? {
        guard let focusWindow else { return nil }
        return Self.list([.optionIncludingWindow], relativeTo: focusWindow).first { $0.number == focusWindow }
    }

    /// On-screen windows in front of the focus window, front to back.
    func windowsAbove() -> [WindowInfo] {
        guard let focusWindow else { return [] }
        return Self.list([.optionOnScreenAboveWindow, .excludeDesktopElements], relativeTo: focusWindow)
    }

    // MARK: Session

    func beginSession(browserPid: Int32) {
        self.browserPid = browserPid
        focusWindow = nil
        preSessionWindows = Set(Self.list([.optionAll]).filter { $0.pid == browserPid }.map(\.number))
    }

    func stop() {
        focusWindow = nil
    }

    func setBrowserPid(_ pid: Int32) {
        browserPid = pid
    }

    /// Finds the native window for the extension's popup: same pid, same bounds
    /// (within a few points), layer 0, newest. After `allowFallback`, a newly
    /// created browser window with the same size is accepted (Chrome may have
    /// nudged the position to fit the screen).
    func locate(reported: Rect, allowFallback: Bool) -> UInt32? {
        let candidates = Self.list([.optionAll]).filter { $0.pid == browserPid && $0.layer == 0 }
        if let w = WindowMatching.findFocusWindow(candidates: candidates, browserPid: browserPid, reported: reported, current: focusWindow) {
            focusWindow = w.number
            return w.number
        }
        if allowFallback {
            let fresh = candidates.filter {
                !preSessionWindows.contains($0.number)
                    && abs($0.bounds.width - reported.width) <= WindowMatching.boundsTolerance
                    && abs($0.bounds.height - reported.height) <= WindowMatching.boundsTolerance
            }
            if let w = fresh.max(by: { $0.number < $1.number }) {
                focusWindow = w.number
                return w.number
            }
        }
        return nil
    }

    // MARK: Native-app targets

    /// Normal-level windows with their app and (via Accessibility) title,
    /// front to back. `onScreenOnly: false` also includes minimised windows and
    /// windows on other Spaces (used to find a target again).
    ///
    /// Titles cost one Accessibility round trip per app, so they are read only
    /// for apps that can be targets (never browsers: querying Chrome makes it
    /// build accessibility data for heavy pages such as Google Docs), and only
    /// for `titlesFor` when given.
    func candidates(onScreenOnly: Bool = true, titlesFor bundles: Set<String>? = nil) -> [WindowCandidate] {
        let infos = Self.list(onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll])
            .filter { $0.layer == 0 && $0.alpha > 0.01 }
        var titlesByPid: [Int32: [(Rect, String)]] = [:]
        var out: [WindowCandidate] = []
        let own = Bundle.main.bundleIdentifier
        for (z, w) in infos.enumerated() {
            guard let app = NSRunningApplication(processIdentifier: w.pid), app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier else { continue }
            let wantsTitle = bundles.map { $0.contains(bundleID) } ?? true
            if titlesByPid[w.pid] == nil {
                titlesByPid[w.pid] = wantsTitle && !WindowCandidates.browserBundleIDs.contains(bundleID)
                    && !WindowCandidates.excludedBundleIDs.contains(bundleID) && bundleID != own
                    ? AX.windowTitles(pid: w.pid) : []
            }
            let title = titlesByPid[w.pid]?.first { $0.0.approximatelyEquals(w.bounds, tolerance: WindowMatching.boundsTolerance) }?.1 ?? ""
            out.append(WindowCandidate(number: w.number, pid: w.pid, bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                       title: title, bounds: w.bounds, zIndex: z))
        }
        return out
    }

    /// Finds the target's window (again) and makes it the tracked focus window.
    func locateApp(_ target: NativeWindowTarget) -> WindowCandidate? {
        guard let c = WindowCandidates.relocate(target, in: candidates(onScreenOnly: false, titlesFor: [target.bundleID])) else { return nil }
        focusWindow = c.number
        browserPid = c.pid
        return c
    }

    /// Frame of the app's focused (key) window, via Accessibility.
    func focusedWindowBounds(pid: Int32) -> Rect? { AX.focusedWindowFrame(pid: pid) }

    // MARK: Raising

    private let raiser = AXRaiser()

    /// Brings the focus window to the front. Best effort, never blocks: the
    /// Accessibility work runs on its own queue (a busy app can't freeze
    /// Ekagrachit), and overlapping requests collapse into one.
    func raise(info: WindowInfo?) {
        guard browserPid > 0, let app = NSRunningApplication(processIdentifier: browserPid) else { return }
        if app.isHidden { app.unhide() }
        guard AXIsProcessTrusted() else {
            app.activate()
            return
        }
        raiser.raise(pid: browserPid, window: info.map { ($0.number, $0.bounds, $0.onScreen) })
    }
}

/// Accessibility helpers. Every element gets a short messaging timeout: the
/// default (~6 s) turns one unresponsive app into a frozen Ekagrachit.
enum AX {
    static let timeout: Float = 0.3

    static func app(_ pid: Int32) -> AXUIElement {
        let a = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(a, timeout)
        return a
    }

    static func windowTitles(pid: Int32) -> [(Rect, String)] {
        guard AXIsProcessTrusted() else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { w in
            guard let f = frame(of: w) else { return nil }
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return (f, (t as? String) ?? "")
        }
    }

    static func focusedWindowFrame(pid: Int32) -> Rect? {
        guard AXIsProcessTrusted() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return frame(of: v as! AXUIElement) // swiftlint:disable:this force_cast
    }

    static func window(of app: AXUIElement, matching bounds: Rect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { frame(of: $0)?.approximatelyEquals(bounds, tolerance: WindowMatching.boundsTolerance) ?? false }
    }

    static func frame(of w: AXUIElement) -> Rect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        // swiftlint:enable force_cast
        return Rect(x: p.x, y: p.y, width: s.width, height: s.height)
    }
}

/// Raises a window through Accessibility on a private serial queue. Keeps the
/// window's AX element between raises (finding it means listing the app's
/// windows and reading each frame), and drops a request while one is running:
/// the running one already does the job.
final class AXRaiser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ekagrachit.ax-raise", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    // Confined to `queue`.
    private var cached: (pid: Int32, number: UInt32, element: AXUIElement)?

    func raise(pid: Int32, window: (number: UInt32, bounds: Rect, onScreen: Bool)?) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            let app = AX.app(pid)
            if let window {
                var element: AXUIElement?
                if let c = cached, c.pid == pid, c.number == window.number { element = c.element }
                if element == nil, let found = AX.window(of: app, matching: window.bounds) {
                    element = found
                    cached = (pid, window.number, found)
                }
                if let element {
                    if !window.onScreen { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
                    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                    if AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .invalidUIElement { cached = nil }
                }
            }
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }
}

enum Permissions {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once per app identity) and returns the current state.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
