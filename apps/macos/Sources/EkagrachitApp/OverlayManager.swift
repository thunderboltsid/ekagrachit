import AppKit
import EkagrachitCore

/// Window level for the obscuring overlays: above normal windows, floating
/// panels, the Dock (20) and the menu bar (24); below pop-up menus (101) so
/// Chrome's context menus still appear; well below the system's own
/// screen-saver/shielding levels used for authentication and Force Quit.
let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
let hudLevel = NSWindow.Level(rawValue: overlayLevel.rawValue + 1)
let confirmLevel = NSWindow.Level(rawValue: overlayLevel.rawValue + 2)

enum OverlayStyle: String, CaseIterable, Identifiable {
    case frosted, opaque
    var id: String { rawValue }
    var label: String { self == .frosted ? "Frosted glass" : "Solid" }
}

/// A borderless, non-activating panel that blocks clicks and hides what is behind it.
class OverlayPanel: NSPanel {
    var onClick: (() -> Void)?

    init(style: OverlayStyle) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        contentView = OverlayPanel.makeContent(style: style)
    }

    static func makeContent(style: OverlayStyle) -> NSView {
        let root = NSView()
        root.wantsLayer = true
        switch style {
        case .frosted:
            // Blurs whatever is behind, composited by the window server: no
            // screen capture and no Screen Recording permission involved.
            let blur = NSVisualEffectView()
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            root.addSubview(blur)
            let dim = NSView()
            dim.wantsLayer = true
            dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            dim.autoresizingMask = [.width, .height]
            root.addSubview(dim)
        case .opaque:
            root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        return root
    }

    func apply(style: OverlayStyle) {
        let content = OverlayPanel.makeContent(style: style)
        content.frame = contentView?.bounds ?? .zero
        contentView = content
        for v in content.subviews { v.frame = content.bounds }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Owns every overlay panel. Layout per display: up to four panels around the
/// focus window's rectangle ("hole"), or one full-screen panel when the hole
/// must be closed (focus lost / window missing).
@MainActor
final class OverlayManager {
    private var pool: [OverlayPanel] = []
    private var lastLayout: [CGRect] = []
    private(set) var isShown = false
    private(set) var isSuspended = false
    var style: OverlayStyle = .frosted {
        didSet {
            guard style != oldValue else { return }
            pool.forEach { $0.apply(style: style) }
            fillets.values.forEach { $0.orderOut(nil) }
            fillets = [:]
        }
    }
    var onClick: (() -> Void)?

    let hud = HUDPanel()
    private var fillets: [Corner: CornerPanel] = [:]
    /// Window corner radius on macOS 26 (slightly generous: covering a few
    /// pixels of the focus window's own corner is harmless, exposing what is
    /// behind it is not).
    static let cornerRadius: CGFloat = 18

    /// - Parameters:
    ///   - hole: focus window rect in global top-left coordinates, or nil to cover everything
    ///   - shielded: cover the hole too (something else is in front of the focus window)
    ///   - patches: extra rects (global top-left) inside the hole to cover, e.g. the Dock over the focus window
    func show(hole: Rect?, shielded: Bool, patches: [Rect] = []) {
        isShown = true
        layout(hole: shielded ? nil : hole, patches: shielded ? [] : patches)
        hud.place(near: hole)
        if !isSuspended { hud.orderFrontRegardless() }
    }

    func hide() {
        isShown = false
        isSuspended = false
        pool.forEach { $0.orderOut(nil) }
        fillets.values.forEach { $0.orderOut(nil) }
        lastLayout = []
        hud.orderOut(nil)
    }

    /// Temporarily step aside for system security UI (password prompts, permission dialogs).
    func setSuspended(_ suspended: Bool) {
        guard isShown, suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            pool.forEach { $0.orderOut(nil) }
            fillets.values.forEach { $0.orderOut(nil) }
            hud.orderOut(nil)
            lastLayout = []
        } else {
            hud.orderFrontRegardless()
        }
    }

    /// Rebuild after display changes.
    func invalidate() {
        lastLayout = []
    }

    private func layout(hole: Rect?, patches: [Rect]) {
        guard !isSuspended else { return }
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let primaryHeight = Double(primary.frame.height)
        let holeCocoa = hole.map { OverlayGeometry.flip($0, primaryHeight: primaryHeight) }
        var rects: [CGRect] = []
        for screen in screens {
            let f = screen.frame
            let v = screen.visibleFrame
            let sr = Rect(x: f.minX, y: f.minY, width: f.width, height: f.height)
            let vr = Rect(x: v.minX, y: v.minY, width: v.width, height: v.height)
            let screenHole = holeCocoa.flatMap { OverlayGeometry.hole(window: $0, screen: sr, visible: vr) }
            for r in OverlayGeometry.coverRects(screen: sr, hole: screenHole) {
                rects.append(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
            }
        }
        for p in patches {
            let r = OverlayGeometry.flip(p.integral, primaryHeight: primaryHeight)
            rects.append(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
        }
        layoutFillets(window: holeCocoa, screens: screens)
        if rects == lastLayout { return }
        lastLayout = rects
        while pool.count < rects.count {
            let p = OverlayPanel(style: style)
            p.onClick = { [weak self] in self?.onClick?() }
            pool.append(p)
        }
        for (i, panel) in pool.enumerated() {
            if i < rects.count {
                panel.setFrame(rects[i], display: true)
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
        }
    }
}

extension OverlayManager {
    /// Covers the four slivers between the focus window's rounded corners and
    /// the rectangular hole, where whatever is behind the window would show.
    fileprivate func layoutFillets(window: Rect?, screens: [NSScreen]) {
        let r = OverlayManager.cornerRadius
        let fullScreen = screens.contains { NSRect(x: window?.x ?? 0, y: window?.y ?? 0, width: window?.width ?? 0, height: window?.height ?? 0).contains($0.frame) }
        guard let w = window, !w.isEmpty, !fullScreen else {
            fillets.values.forEach { $0.orderOut(nil) }
            return
        }
        for corner in Corner.allCases {
            let origin: NSPoint
            switch corner {
            case .bottomLeft: origin = NSPoint(x: w.minX, y: w.minY)
            case .bottomRight: origin = NSPoint(x: w.maxX - r, y: w.minY)
            case .topLeft: origin = NSPoint(x: w.minX, y: w.maxY - r)
            case .topRight: origin = NSPoint(x: w.maxX - r, y: w.maxY - r)
            }
            let frame = NSRect(origin: origin, size: NSSize(width: r, height: r))
            // Only where the window's corner is actually exposed: inside some
            // screen's visible frame (elsewhere the cover panels already cover it).
            let exposed = screens.contains { $0.visibleFrame.contains(frame) }
            let panel = fillets[corner] ?? {
                let p = CornerPanel(corner: corner, radius: r, style: style)
                p.onClick = { [weak self] in self?.onClick?() }
                fillets[corner] = p
                return p
            }()
            if exposed {
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else {
                panel.orderOut(nil)
            }
        }
    }
}

enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

/// An r×r overlay square with a transparent quarter disc toward the window:
/// draws the overlay only outside the window's rounded corner. Fully
/// transparent pixels let clicks through to the window.
final class CornerPanel: OverlayPanel {
    init(corner: Corner, radius: CGFloat, style: OverlayStyle) {
        super.init(style: style)
        let mask = NSImage(size: NSSize(width: radius, height: radius), flipped: false) { rect in
            // Disc centre: the inner corner of the square (toward the window's interior).
            let c: NSPoint
            switch corner {
            case .bottomLeft: c = NSPoint(x: rect.maxX, y: rect.maxY)
            case .bottomRight: c = NSPoint(x: rect.minX, y: rect.maxY)
            case .topLeft: c = NSPoint(x: rect.maxX, y: rect.minY)
            case .topRight: c = NSPoint(x: rect.minX, y: rect.minY)
            }
            let path = NSBezierPath(rect: rect)
            path.appendOval(in: NSRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = mask
        if style == .opaque { blur.material = .windowBackground }
        contentView = blur
    }
}

/// Small, unobtrusive status pill: remaining time, state, and "End…".
/// A small capsule button drawn by hand: system buttons in a non-activating
/// panel of a background app always render in their dimmed "inactive" style.
final class PillButton: NSView {
    private let title: String
    var onPress: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
    }

    override var intrinsicContentSize: NSSize {
        let t = (title as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(t.width) + 18, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.labelColor.withAlphaComponent(pressed ? 0.22 : 0.1).setFill()
        path.fill()
        let t = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: r.midX - t.width / 2, y: r.midY - t.height / 2), withAttributes: attrs)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

final class HUDPanel: NSPanel {
    static let height: CGFloat = 22
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let endButton = PillButton(title: "End…")
    var onEnd: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: HUDPanel.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = hudLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        endButton.onPress = { [weak self] in self?.onEnd?() }
        endButton.setAccessibilityLabel("End focus session early")
        endButton.toolTip = "End early (\(HotKey.emergencyDisplay))"

        let stack = NSStackView(views: [label, detail, endButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 3)
        let glass = NSGlassEffectView()
        glass.cornerRadius = HUDPanel.height / 2
        glass.contentView = stack
        contentView = glass
    }

    override var canBecomeKey: Bool { false }


    func update(remaining: TimeInterval, detailText: String?) {
        label.stringValue = Self.format(remaining)
        detail.stringValue = detailText ?? ""
        detail.isHidden = (detailText ?? "").isEmpty
        let size = contentView?.fittingSize ?? NSSize(width: 160, height: HUDPanel.height)
        if abs(size.width - frame.width) > 1 {
            var f = frame
            f.origin.x += f.width - max(120, size.width)
            f.size = NSSize(width: max(120, size.width), height: HUDPanel.height)
            setFrame(f, display: true)
        }
    }

    /// Top-right corner of the display that contains the focus window, inside the menu-bar strip.
    func place(near hole: Rect?) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        var target = NSScreen.main ?? primary
        if let hole {
            let c = OverlayGeometry.flip(hole, primaryHeight: Double(primary.frame.height))
            let center = NSPoint(x: c.x + c.width / 2, y: c.y + c.height / 2)
            target = screens.first { $0.frame.contains(center) } ?? target
        }
        let f = target.frame
        let w = max(120, frame.width)
        // Inside the menu-bar strip, which windows (other than full-screen ones) never occupy.
        let strip = max(HUDPanel.height + 2, f.maxY - target.visibleFrame.maxY)
        let origin = NSPoint(x: f.maxX - w - 10, y: f.maxY - (strip + HUDPanel.height) / 2)
        if frame.origin != origin { setFrame(NSRect(origin: origin, size: NSSize(width: w, height: HUDPanel.height)), display: true) }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// A small transient notice shown after a session ends (e.g. "Focus session
/// complete"): non-activating, click-through, fades out on its own.
final class ToastPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = hudLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        glass.contentView = container
        contentView = glass
    }

    override var canBecomeKey: Bool { false }

    func show(_ text: String, for seconds: TimeInterval = 3.5) {
        label.stringValue = text
        let width = max(220, label.intrinsicContentSize.width + 48)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            setFrame(NSRect(x: f.midX - width / 2, y: f.maxY - 44 - 24, width: width, height: 44), display: true)
        }
        alphaValue = 1
        orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self?.animator().alphaValue = 0
            }, completionHandler: { self?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
