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
        if let w = WindowMatching.findFocusWindow(candidates: candidates, browserPid: browserPid, reported: reported) {
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

    // MARK: Raising

    /// Brings the focus window to the front. Best effort, never throws.
    func raise(info: WindowInfo?) {
        guard browserPid > 0, let app = NSRunningApplication(processIdentifier: browserPid) else { return }
        if app.isHidden { app.unhide() }
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(browserPid)
            if let info, let win = Self.axWindow(of: axApp, matching: info.bounds) {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            }
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        } else {
            app.activate()
        }
    }

    private static func axWindow(of app: AXUIElement, matching bounds: Rect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for w in windows {
            guard let frame = frame(of: w) else { continue }
            if frame.approximatelyEquals(bounds, tolerance: WindowMatching.boundsTolerance) { return w }
        }
        return nil
    }

    private static func frame(of w: AXUIElement) -> Rect? {
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
