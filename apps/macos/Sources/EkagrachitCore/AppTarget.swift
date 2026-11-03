import Foundation

/// A native Mac window chosen as the focus target (Word, Pages, Cursor, Xcode,
/// iTerm2, …). Identified by its app and, after the window server forgets it
/// (app relaunch), by title.
public struct NativeWindowTarget: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var title: String
    public var pid: Int32
    public var windowNumber: UInt32?

    public init(bundleID: String, appName: String, title: String, pid: Int32, windowNumber: UInt32?) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.pid = pid
        self.windowNumber = windowNumber
    }

    /// "Design review.docx — Microsoft Word", or just the app name for untitled windows.
    public var displayName: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == appName ? appName : "\(t) — \(appName)"
    }
}

/// An on-screen window that could become the focus target.
public struct WindowCandidate: Equatable, Sendable {
    public var number: UInt32
    public var pid: Int32
    public var bundleID: String
    public var appName: String
    public var title: String
    public var bounds: Rect
    public var zIndex: Int // 0 = frontmost

    public init(number: UInt32, pid: Int32, bundleID: String, appName: String, title: String, bounds: Rect, zIndex: Int) {
        self.number = number
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.zIndex = zIndex
    }

    public var target: NativeWindowTarget {
        NativeWindowTarget(bundleID: bundleID, appName: appName, title: title, pid: pid, windowNumber: number)
    }
}

public enum WindowCandidates {
    /// Apps that are never focus targets: Ekagrachit itself, the desktop and
    /// system chrome, and browsers (web pages are focused by URL instead,
    /// which gives link-level isolation).
    public static let excludedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.WindowManager",
        "com.apple.loginwindow", "com.apple.screencaptureui",
    ]
    public static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.google.chrome.for.testing", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.apple.Safari", "org.mozilla.firefox",
    ]

    /// Real document/app windows, front to back, at most `limit`, without
    /// duplicates or tiny utility windows.
    public static func rank(_ all: [WindowCandidate], ownBundleID: String?, limit: Int = 8) -> [WindowCandidate] {
        var seen = Set<String>()
        return all
            .filter { c in
                c.bounds.width >= 160 && c.bounds.height >= 120
                    && c.bundleID != ownBundleID
                    && !excludedBundleIDs.contains(c.bundleID)
                    && !browserBundleIDs.contains(c.bundleID)
            }
            .sorted { $0.zIndex < $1.zIndex }
            .filter { seen.insert("\($0.pid)|\($0.title)|\($0.number)").inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Finds the target's window again: same window number while it exists;
    /// otherwise (the app was relaunched, the window recreated) the same app
    /// with the same title; otherwise, if the app has exactly one window, that.
    public static func relocate(_ target: NativeWindowTarget, in all: [WindowCandidate]) -> WindowCandidate? {
        if let n = target.windowNumber, let c = all.first(where: { $0.number == n && $0.pid == target.pid }) { return c }
        let sameApp = all.filter { $0.bundleID == target.bundleID }
        if !target.title.isEmpty, let c = sameApp.filter({ $0.title == target.title }).min(by: { $0.zIndex < $1.zIndex }) { return c }
        return sameApp.count == 1 ? sameApp[0] : nil
    }
}
