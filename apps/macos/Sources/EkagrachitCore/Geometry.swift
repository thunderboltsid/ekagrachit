import Foundation

/// Minimal rectangle type so geometry logic is testable without CoreGraphics.
/// Coordinate space is stated at each use site:
///  - "global top-left": Quartz window-server space (CGWindowList, Chrome's
///    window bounds): origin at the top-left of the primary display, y down.
///  - "Cocoa": AppKit screen space: origin at the bottom-left of the primary
///    display, y up.
public struct Rect: Equatable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Double { isEmpty ? 0 : width * height }

    public func intersection(_ o: Rect) -> Rect? {
        let x0 = max(minX, o.minX), y0 = max(minY, o.minY)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func contains(_ o: Rect, tolerance: Double = 0) -> Bool {
        o.minX >= minX - tolerance && o.minY >= minY - tolerance && o.maxX <= maxX + tolerance && o.maxY <= maxY + tolerance
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }

    /// Rounded outward to whole points (window frames are integral).
    public var integral: Rect {
        let x0 = floor(minX), y0 = floor(minY)
        return Rect(x: x0, y: y0, width: ceil(maxX) - x0, height: ceil(maxY) - y0)
    }

    public func approximatelyEquals(_ o: Rect, tolerance: Double) -> Bool {
        abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance && abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }

    public var description: String { "(\(x), \(y), \(width)x\(height))" }
}

public enum OverlayGeometry {
    /// The rectangles that cover `screen` except for `hole`.
    ///
    /// Up to four non-overlapping rectangles: a full-width band above and below
    /// the hole, and left/right pieces beside it. Using separate opaque windows
    /// (rather than one window with a transparent cutout) keeps hit-testing
    /// exact: there is simply no overlay window where the focus window is, so
    /// clicks there always reach it. Both rects must be in the same space.
    public static func coverRects(screen: Rect, hole: Rect?) -> [Rect] {
        guard let hole = hole?.integral, let h = screen.intersection(hole) else { return [screen] }
        var out: [Rect] = []
        // Band between screen.minY and h.minY (full width)
        if h.minY > screen.minY { out.append(Rect(x: screen.minX, y: screen.minY, width: screen.width, height: h.minY - screen.minY)) }
        // Band between h.maxY and screen.maxY (full width)
        if h.maxY < screen.maxY { out.append(Rect(x: screen.minX, y: h.maxY, width: screen.width, height: screen.maxY - h.maxY)) }
        // Left and right of the hole, hole height
        if h.minX > screen.minX { out.append(Rect(x: screen.minX, y: h.minY, width: h.minX - screen.minX, height: h.height)) }
        if h.maxX < screen.maxX { out.append(Rect(x: h.maxX, y: h.minY, width: screen.maxX - h.maxX, height: h.height)) }
        return out.filter { !$0.isEmpty }
    }

    /// The part of the focus window that may stay uncovered on one screen: the
    /// window clipped to the screen's visible frame (which excludes the menu bar
    /// and the Dock, both drawn above normal windows), except for a full-screen
    /// window, which owns the whole screen. Same coordinate space for all rects.
    public static func hole(window: Rect, screen: Rect, visible: Rect) -> Rect? {
        if window.contains(screen, tolerance: 2) { return screen }
        return window.intersection(visible)
    }

    /// Converts a rect between global top-left (Quartz) and Cocoa coordinates.
    /// The transform is its own inverse. `primaryHeight` is the height of the
    /// primary display (the one whose Cocoa frame has origin (0,0)).
    public static func flip(_ r: Rect, primaryHeight: Double) -> Rect {
        Rect(x: r.x, y: primaryHeight - r.y - r.height, width: r.width, height: r.height)
    }
}
