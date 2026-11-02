import Foundation

/// A window as reported by the window server (CGWindowListCopyWindowInfo).
/// `bounds` are in global top-left coordinates. Titles are deliberately not
/// part of this model: reading them requires Screen Recording permission.
public struct WindowInfo: Equatable, Sendable {
    public var number: UInt32
    public var pid: Int32
    public var layer: Int
    public var bounds: Rect
    public var onScreen: Bool
    public var alpha: Double

    public init(number: UInt32, pid: Int32, layer: Int, bounds: Rect, onScreen: Bool, alpha: Double = 1) {
        self.number = number
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.onScreen = onScreen
        self.alpha = alpha
    }
}

public enum WindowMatching {
    /// Tolerance between Chrome's reported window bounds and the window server's.
    public static let boundsTolerance: Double = 4

    /// Finds the native window corresponding to the extension-created popup.
    ///
    /// Identity is established by (owner pid == browser pid) AND (bounds equal to
    /// what chrome.windows reported, within a few points) AND layer 0. Among
    /// several equal candidates the highest window number wins: window numbers
    /// are allocated increasingly, so it is the most recently created window,
    /// i.e. the popup the extension just opened.
    public static func findFocusWindow(candidates: [WindowInfo], browserPid: Int32, reported: Rect) -> WindowInfo? {
        candidates
            .filter { $0.pid == browserPid && $0.layer == 0 && $0.bounds.approximatelyEquals(reported, tolerance: boundsTolerance) }
            .max { $0.number < $1.number }
    }
}

/// Outcome of a focus check, evaluated every few ms during a session.
public enum FocusAssessment: Equatable, Sendable {
    /// The focus window is frontmost: open the hole.
    case focused
    /// Something else is in front: cover the hole and bring the focus window back.
    case lost(reason: String)
    /// A system/security UI is frontmost: stand aside (hide overlays) until it is gone.
    case exempt
    /// Ekagrachit's own UI (confirmation panel, menu) is frontmost: keep overlays, don't fight.
    case ownUI
    /// The focus window isn't on the current Space/screen (minimised, hidden, other Space).
    case offscreen
}

public enum FocusPolicy {
    /// System processes whose UI must never be hidden or fought with
    /// (authentication prompts, permission dialogs, the login window, ...).
    public static let exemptBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.CoreServicesUIAgent",
        "com.apple.coreservices.uiagent",
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.AccessibilityUIServer",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.systempreferences", // System Settings: needed to grant permissions
        "com.apple.Passwords",
        "com.apple.keychainaccess",
    ]

    /// - Parameters:
    ///   - focus: the focus window's current info (nil if it no longer exists)
    ///   - above: on-screen windows in front of the focus window, front to back
    ///   - frontmostPid / frontmostBundleID: the active application
    ///   - browserPid: Chrome's pid
    ///   - ownPid: Ekagrachit's pid
    public static func assess(
        focus: WindowInfo?,
        above: [WindowInfo],
        frontmostPid: Int32?,
        frontmostBundleID: String?,
        browserPid: Int32,
        ownPid: Int32
    ) -> FocusAssessment {
        if let bid = frontmostBundleID, exemptBundleIDs.contains(bid) { return .exempt }
        if frontmostPid == ownPid { return .ownUI }
        guard let focus else { return .offscreen }
        guard focus.onScreen else { return .offscreen }
        if let pid = frontmostPid, pid != browserPid {
            return .lost(reason: "another application is active")
        }
        // Any normal-level window in front of the focus window that is not one
        // of Chrome's own child surfaces (menus, bubbles, autofill popups stay
        // inside the window's frame) means something else is on top.
        for w in above where w.layer == 0 && w.alpha > 0.01 && !w.bounds.isEmpty {
            if w.pid == browserPid && focus.bounds.contains(w.bounds, tolerance: 2) { continue }
            if w.pid == ownPid { continue }
            if w.bounds.intersection(focus.bounds) == nil { continue } // covered by the overlay anyway
            return .lost(reason: w.pid == browserPid ? "another browser window is in front" : "another window is in front")
        }
        return .focused
    }
}

/// Turns successive focus assessments into overlay actions, with one safety
/// valve: if focus stays "lost" while the browser itself is frontmost for
/// longer than `stuckAfter` (some window we cannot dislodge sits above the
/// focus window), the hole is reopened rather than locking the user out of
/// their own document. Everything outside the focus window stays covered.
public struct FocusLossDebouncer: Sendable {
    public enum Action: Equatable, Sendable {
        case openHole
        case closeHoleAndRefocus
        case coverAllAndRefocus
        case standAside
    }

    public var stuckAfter: TimeInterval
    private var lostSince: Instant?

    public init(stuckAfter: TimeInterval = 2.5) {
        self.stuckAfter = stuckAfter
    }

    public mutating func next(_ assessment: FocusAssessment, frontmostIsBrowser: Bool, now: Instant) -> Action {
        switch assessment {
        case .focused, .ownUI:
            lostSince = nil
            return .openHole
        case .exempt:
            lostSince = nil
            return .standAside
        case .offscreen:
            lostSince = nil
            return .coverAllAndRefocus
        case .lost:
            guard frontmostIsBrowser else {
                lostSince = nil
                return .closeHoleAndRefocus
            }
            let since = lostSince ?? now
            lostSince = since
            return now.seconds(since: since) >= stuckAfter ? .openHole : .closeHoleAndRefocus
        }
    }
}

extension FocusPolicy {
    /// Windows that the window server draws *on top of* the focus window inside
    /// its uncovered rectangle: the Dock (layer 20) when the focus window extends
    /// over it, other apps' floating panels, notification banners. Their
    /// intersection with the focus window must be covered too, or they are
    /// visible and clickable through the hole.
    ///
    /// Excluded: the browser's own surfaces, Ekagrachit's windows, system
    /// security UI (`exemptPids`), invisible windows, and anything at or above
    /// the overlay level (which we could not cover anyway).
    public static func intruderPatches(focus: Rect, above: [WindowInfo], browserPid: Int32, ownPid: Int32,
                                       overlayLayer: Int, exemptPids: Set<Int32> = []) -> [Rect] {
        above.compactMap { w in
            guard w.layer > 0, w.layer < overlayLayer, w.alpha > 0.01,
                  w.pid != browserPid, w.pid != ownPid, !exemptPids.contains(w.pid)
            else { return nil }
            return w.bounds.intersection(focus)
        }
    }
}
