import AppKit

/// Deliberate early exit: an explicit confirmation panel with a button that
/// must be held for `holdDuration` (mouse, or Space/Return on the keyboard).
/// Escape or "Keep focusing" cancels. Nothing ends on a single click.
final class ConfirmEndPanel: NSPanel {
    static let holdDuration: TimeInterval = 2.5

    private let hold = HoldToConfirmView(duration: ConfirmEndPanel.holdDuration)
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 168), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        level = confirmLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        let title = NSTextField(labelWithString: "End this session early?")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: "Restrictions lift and the focus window closes. You'll be asked about any unsaved changes.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        // The teachable moment: the urge to leave is the wandering mind.
        let verse = NSTextField(wrappingLabelWithString: "“Wherever the restless mind wanders, draw it back from there, and let it rest within.”")
        let citation = NSTextField(labelWithString: "— Bhagavad Gītā 6.26")
        citation.font = .systemFont(ofSize: 11)
        citation.textColor = .tertiaryLabelColor
        citation.alignment = .right
        verse.font = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        verse.textColor = .secondaryLabelColor
        // Wrapping labels size to their longest line unless told the width.
        body.preferredMaxLayoutWidth = 320
        verse.preferredMaxLayoutWidth = 320
        let cancel = NSButton(title: "Keep focusing", target: nil, action: nil)
        cancel.bezelStyle = .glass
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        hold.onComplete = { [weak self] in self?.onConfirm?() }

        let buttons = NSStackView(views: [cancel, hold])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let stack = NSStackView(views: [title, body, verse, citation, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: verse)
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: 320),
            verse.widthAnchor.constraint(equalToConstant: 320),
            citation.widthAnchor.constraint(equalToConstant: 320),
            hold.widthAnchor.constraint(equalToConstant: 170),
            hold.heightAnchor.constraint(equalToConstant: 28),
        ])
        contentView = root
        setContentSize(root.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        cancelPressed()
    }

    @objc private func cancelPressed() {
        hold.reset()
        onCancel?()
    }

    func present() {
        hold.reset()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.frame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2 + 80))
        }
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(hold)
    }

    func dismiss() {
        hold.reset()
        orderOut(nil)
    }
}

/// A button that only fires after being held continuously.
final class HoldToConfirmView: NSView {
    let duration: TimeInterval
    var onComplete: (() -> Void)?
    private var start: Date?
    private var timer: Timer?
    private var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    init(duration: TimeInterval) {
        self.duration = duration
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Hold to end session")
        setAccessibilityHelp("Press and hold for \(Int(duration.rounded())) seconds, with the mouse or the Space or Return key.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.systemRed.withAlphaComponent(0.35).setFill()
        NSRect(x: r.minX, y: r.minY, width: r.width * progress, height: r.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        (window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = progress > 0 ? "Keep holding…" : "Hold to end session"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    private func begin() {
        guard start == nil else { return }
        start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let start = self.start else { return }
            self.progress = min(1, CGFloat(Date().timeIntervalSince(start) / self.duration))
            if self.progress >= 1 {
                self.reset()
                self.onComplete?()
            }
        }
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        start = nil
        progress = 0
    }

    override func mouseDown(with event: NSEvent) { begin() }
    override func mouseUp(with event: NSEvent) { if progress < 1 { reset() } }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 { begin() } else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 { reset() } else { super.keyUp(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        reset()
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        // VoiceOver users get the same deliberate confirmation via the panel itself.
        onComplete?()
        return true
    }
}
