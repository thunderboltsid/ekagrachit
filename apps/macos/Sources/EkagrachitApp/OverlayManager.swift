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
final class OverlayPanel: NSPanel {
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
        }
    }
    var onClick: (() -> Void)?

    let hud = HUDPanel()

    /// - Parameters:
    ///   - hole: focus window rect in global top-left coordinates, or nil to cover everything
    ///   - shielded: cover the hole too (something else is in front of the focus window)
    func show(hole: Rect?, shielded: Bool) {
        isShown = true
        layout(hole: shielded ? nil : hole)
        hud.place(near: hole)
        if !isSuspended { hud.orderFrontRegardless() }
    }

    func hide() {
        isShown = false
        isSuspended = false
        pool.forEach { $0.orderOut(nil) }
        lastLayout = []
        hud.orderOut(nil)
    }

    /// Temporarily step aside for system security UI (password prompts, permission dialogs).
    func setSuspended(_ suspended: Bool) {
        guard isShown, suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            pool.forEach { $0.orderOut(nil) }
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

    private func layout(hole: Rect?) {
        guard !isSuspended else { return }
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let primaryHeight = Double(primary.frame.height)
        let holeCocoa = hole.map { OverlayGeometry.flip($0, primaryHeight: primaryHeight) }
        var rects: [CGRect] = []
        for screen in screens {
            let f = screen.frame
            let sr = Rect(x: f.minX, y: f.minY, width: f.width, height: f.height)
            for r in OverlayGeometry.coverRects(screen: sr, hole: holeCocoa) {
                rects.append(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
            }
        }
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

/// Small, unobtrusive status pill: remaining time, state, and "End…".
final class HUDPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let endButton = NSButton(title: "End…", target: nil, action: nil)
    var onEnd: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = hudLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 15
        bg.layer?.masksToBounds = true

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        endButton.bezelStyle = .inline
        endButton.controlSize = .small
        endButton.target = self
        endButton.action = #selector(endPressed)
        endButton.setAccessibilityLabel("End focus session early")

        let stack = NSStackView(views: [label, detail, endButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        contentView = bg
    }

    override var canBecomeKey: Bool { false }

    @objc private func endPressed() {
        onEnd?()
    }

    func update(remaining: TimeInterval, detailText: String?) {
        label.stringValue = Self.format(remaining)
        detail.stringValue = detailText ?? ""
        detail.isHidden = (detailText ?? "").isEmpty
        let size = contentView?.fittingSize ?? NSSize(width: 160, height: 30)
        if abs(size.width - frame.width) > 1 {
            var f = frame
            f.origin.x += f.width - max(120, size.width)
            f.size = NSSize(width: max(120, size.width), height: 30)
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
        let origin = NSPoint(x: f.maxX - w - 12, y: f.maxY - 30 - 4)
        if frame.origin != origin { setFrame(NSRect(origin: origin, size: NSSize(width: w, height: 30)), display: true) }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
