import AppKit

extension NSColor {
    // A quiet blue accent, independent of the green used by earlier builds.
    static var screenClipAccent: NSColor { .systemBlue }
    static var screenClipSecondaryLabel: NSColor {
        NSColor(name: nil) { appearance in
            NSColor(calibratedWhite: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.78 : 0.24, alpha: 1)
        }
    }
}

@MainActor
private final class FrostedTint: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class FrostedBackdrop: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class FrostedSurface: NSView {
    private let radius: CGFloat
    private let glass = FrostedBackdrop()
    private let tint = FrostedTint()
    private var accessibilityObserver: NSObjectProtocol?
    init(frame: NSRect = .zero, radius: CGFloat = 18) {
        self.radius = radius
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = radius; layer?.masksToBounds = true
        glass.material = .underWindowBackground; glass.blendingMode = .behindWindow; glass.state = .active
        glass.frame = bounds; glass.autoresizingMask = [.width, .height]
        glass.setAccessibilityElement(false); addSubview(glass)
        tint.frame = bounds; tint.autoresizingMask = [.width, .height]; tint.wantsLayer = true
        tint.setAccessibilityElement(false); addSubview(tint)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshMaterial() } }
        refreshMaterial()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false; window?.backgroundColor = .clear
        refreshMaterial()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshMaterial() }
    private func refreshMaterial() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        glass.isHidden = reduce; glass.alphaValue = 0.68
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let solid = dark ? NSColor.windowBackgroundColor : NSColor.white
            layer?.backgroundColor = (reduce ? solid : .clear).cgColor
            tint.layer?.backgroundColor = (reduce ? .clear : dark ? NSColor.black.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.14)).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.55).cgColor
        }
        layer?.borderWidth = 0.7; layer?.cornerRadius = radius
        needsDisplay = true
    }
}

/// Reading surfaces can opt into a solid background while retaining the outer glass.
@MainActor
final class ReadableSurface: NSView {
    var radius: CGFloat = 12
    var usesOpaqueBackground = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.withAlphaComponent(usesOpaqueBackground ? 1 : 0.30).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        NSColor.separatorColor.withAlphaComponent(0.32).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        path.lineWidth = 0.6; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
