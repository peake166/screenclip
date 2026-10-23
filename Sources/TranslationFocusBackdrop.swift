import AppKit

@MainActor final class TranslationFocusView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    let cutout: CGRect?

    init(screenFrame: CGRect, selection: CGRect) {
        let intersection = selection.intersection(screenFrame)
        if intersection.isNull || intersection.isEmpty { cutout = nil }
        else {
            cutout = CGRect(x: intersection.minX - screenFrame.minX,
                            y: screenFrame.maxY - intersection.maxY,
                            width: intersection.width, height: intersection.height)
        }
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let mask = NSBezierPath(rect: bounds)
        if let cutout { mask.appendRect(cutout) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        mask.fill()
    }
}

@MainActor final class TranslationFocusBackdrop: OverlayPanel {
    override var canBecomeKey: Bool { false }

    init(screen: NSScreen, selection: CGRect) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        title = "截图翻译背景"
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        ignoresMouseEvents = true
        animationBehavior = .none
        contentView = TranslationFocusView(screenFrame: screen.frame, selection: selection)
        setFrame(screen.frame, display: false)
    }
}
