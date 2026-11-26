import AppKit

enum ScreenClipTone {
    case blue
    case amber
    case indigo
    case teal
    case green
    case slate
    case red

    var foreground: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch self {
            case .blue: return dark ? NSColor(srgbRed: 0.40, green: 0.67, blue: 1.00, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.42, blue: 0.90, alpha: 1)
            case .amber: return dark ? NSColor(srgbRed: 0.99, green: 0.76, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.80, green: 0.45, blue: 0.04, alpha: 1)
            case .indigo: return dark ? NSColor(srgbRed: 0.65, green: 0.69, blue: 1.00, alpha: 1) : NSColor(srgbRed: 0.31, green: 0.27, blue: 0.86, alpha: 1)
            case .teal: return dark ? NSColor(srgbRed: 0.22, green: 0.83, blue: 0.75, alpha: 1) : NSColor(srgbRed: 0.05, green: 0.56, blue: 0.52, alpha: 1)
            case .green: return dark ? NSColor(srgbRed: 0.30, green: 0.86, blue: 0.50, alpha: 1) : NSColor(srgbRed: 0.09, green: 0.55, blue: 0.27, alpha: 1)
            case .slate: return dark ? NSColor(srgbRed: 0.78, green: 0.82, blue: 0.89, alpha: 1) : NSColor(srgbRed: 0.28, green: 0.34, blue: 0.43, alpha: 1)
            case .red: return dark ? NSColor(srgbRed: 1.00, green: 0.45, blue: 0.42, alpha: 1) : NSColor(srgbRed: 0.82, green: 0.17, blue: 0.17, alpha: 1)
            }
        }
    }

    var softBackground: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return self.foreground.withAlphaComponent(dark ? 0.18 : 0.11)
        }
    }

    var hoverBackground: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return self.foreground.withAlphaComponent(dark ? 0.26 : 0.18)
        }
    }

    var pressedBackground: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return self.foreground.withAlphaComponent(dark ? 0.34 : 0.24)
        }
    }

    var solidFill: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch self {
            case .blue: return dark ? NSColor(srgbRed: 0.20, green: 0.51, blue: 0.98, alpha: 1) : NSColor(srgbRed: 0.14, green: 0.44, blue: 0.92, alpha: 1)
            case .amber: return dark ? NSColor(srgbRed: 0.90, green: 0.58, blue: 0.08, alpha: 1) : NSColor(srgbRed: 0.84, green: 0.49, blue: 0.05, alpha: 1)
            case .indigo: return dark ? NSColor(srgbRed: 0.40, green: 0.43, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.33, green: 0.29, blue: 0.87, alpha: 1)
            case .teal: return dark ? NSColor(srgbRed: 0.09, green: 0.65, blue: 0.60, alpha: 1) : NSColor(srgbRed: 0.06, green: 0.56, blue: 0.52, alpha: 1)
            case .green: return dark ? NSColor(srgbRed: 0.18, green: 0.76, blue: 0.40, alpha: 1) : NSColor(srgbRed: 0.15, green: 0.68, blue: 0.34, alpha: 1)
            case .slate: return dark ? NSColor(srgbRed: 0.35, green: 0.39, blue: 0.46, alpha: 1) : NSColor(srgbRed: 0.30, green: 0.35, blue: 0.43, alpha: 1)
            case .red: return NSColor.systemRed
            }
        }
    }
}

extension NSColor {
    static var screenClipAccent: NSColor { ScreenClipTone.blue.foreground }

    static var screenClipSecondaryLabel: NSColor {
        NSColor(name: nil) { appearance in
            NSColor(calibratedWhite: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.74 : 0.32, alpha: 1)
        }
    }

    static var screenClipCardFill: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                return dark ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)
            }
            return dark ? NSColor.white.withAlphaComponent(0.065) : NSColor.white.withAlphaComponent(0.74)
        }
    }

    static var screenClipCardHoverFill: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor.white.withAlphaComponent(0.11) : NSColor.white.withAlphaComponent(0.95)
        }
    }

    static var screenClipCardBorder: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            if dark { return NSColor.white.withAlphaComponent(highContrast ? 0.32 : 0.11) }
            return NSColor.black.withAlphaComponent(highContrast ? 0.28 : 0.085)
        }
    }

    static var screenClipHairline: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor.white.withAlphaComponent(0.095) : NSColor.black.withAlphaComponent(0.075)
        }
    }

    static var screenClipKeycapFill: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor.white.withAlphaComponent(0.095) : NSColor(calibratedWhite: 0.99, alpha: 0.95)
        }
    }

    static var screenClipKeycapBorder: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)
        }
    }
}

enum ScreenClipDrawing {
    static func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium, color: NSColor, centeredIn rect: CGRect) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { area in
            color.setFill(); area.fill()
            symbol.draw(in: area, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        let size = symbol.size
        tinted.draw(in: CGRect(
            x: (rect.midX - size.width / 2).rounded(),
            y: (rect.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        ))
    }

    static func keycapSize(for text: String, fontSize: CGFloat = 11) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        return CGSize(width: ceil(sz.width) + 12, height: ceil(sz.height) + 5)
    }

    static func drawKeycap(_ text: String, in rect: CGRect, fontSize: CGFloat = 11, emphasized: Bool = false) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        (emphasized ? ScreenClipTone.blue.softBackground : NSColor.screenClipKeycapFill).setFill()
        path.fill()
        (emphasized ? ScreenClipTone.blue.foreground.withAlphaComponent(0.55) : NSColor.screenClipKeycapBorder).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: emphasized ? ScreenClipTone.blue.foreground : NSColor.screenClipSecondaryLabel
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(
            x: (rect.midX - sz.width / 2).rounded(),
            y: (rect.midY - sz.height / 2).rounded()
        ), withAttributes: attrs)
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
        glass.isHidden = reduce; glass.alphaValue = 0.70
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let solid = dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)
            layer?.backgroundColor = (reduce ? solid : .clear).cgColor
            tint.layer?.backgroundColor = (reduce ? .clear : dark
                ? NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.24)
                : NSColor(srgbRed: 0.97, green: 0.98, blue: 1.00, alpha: 0.22)).cgColor
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            layer?.borderColor = (dark
                ? NSColor.white.withAlphaComponent(highContrast ? 0.40 : 0.14)
                : NSColor.black.withAlphaComponent(highContrast ? 0.35 : 0.11)).cgColor
        }
        layer?.borderWidth = 0.8; layer?.cornerRadius = radius
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
        NSColor.screenClipCardBorder.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        path.lineWidth = 0.7; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Clean Apple-style inset card container for grouped rows or form fields.
@MainActor
final class InsetCardView: NSView {
    var radius: CGFloat
    init(frame: NSRect = .zero, radius: CGFloat = 12) {
        self.radius = radius
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.screenClipCardFill.setFill()
        shape.fill()
        NSColor.screenClipCardBorder.setStroke()
        shape.lineWidth = 0.8
        shape.stroke()
    }
}

/// Crisp 1px hairline divider usable inside InsetCardView or floating HUD bars.
@MainActor
final class HairlineDivider: NSView {
    private let vertical: Bool
    init(vertical: Bool = false) {
        self.vertical = vertical
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            widthAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.screenClipHairline.setFill()
        bounds.fill()
    }
}

/// Modern tinted/primary/subtle pill button matching ScreenClip's HUD & toolbar aesthetic.
@MainActor
final class PillActionButton: NSButton {
    enum Style {
        case tinted(ScreenClipTone)
        case primary(ScreenClipTone)
        case subtle
        case iconCircle
    }

    var pillStyle: Style { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var horizontalPadding: CGFloat = 11 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var fixedHeight: CGFloat = 28 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var showsToggleState: Bool = false { didSet { needsDisplay = true } }
    var isToggledOn: Bool = false { didSet { needsDisplay = true } }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String = "", symbolName: String? = nil, style: Style = .subtle, target: AnyObject? = nil, action: Selector? = nil) {
        self.pillStyle = style
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        if case .iconCircle = pillStyle {
            return NSSize(width: fixedHeight, height: fixedHeight)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium)]
        let textWidth = title.isEmpty ? 0 : ceil((title as NSString).size(withAttributes: attrs).width)
        let iconWidth: CGFloat = symbolName == nil ? 0 : 13
        let gap: CGFloat = (symbolName != nil && !title.isEmpty) ? 5 : 0
        return NSSize(width: max(fixedHeight, horizontalPadding * 2 + iconWidth + gap + textWidth), height: fixedHeight)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let pressed = isHighlighted
        let active = isToggledOn || (showsToggleState && state == .on)
        let alphaScale: CGFloat = isEnabled ? 1.0 : 0.42

        let fillColor: NSColor
        let borderColor: NSColor
        let contentColor: NSColor

        switch pillStyle {
        case .tinted(let tone):
            if active {
                fillColor = tone.solidFill
                borderColor = .clear
                contentColor = .white
            } else {
                fillColor = pressed ? tone.pressedBackground : (hovered ? tone.hoverBackground : tone.softBackground)
                borderColor = tone.foreground.withAlphaComponent(hovered ? 0.35 : 0.16)
                contentColor = tone.foreground
            }
        case .primary(let tone):
            let base = tone.solidFill
            fillColor = pressed ? base.blended(withFraction: 0.18, of: .black) ?? base
                : (hovered ? base.blended(withFraction: 0.10, of: .white) ?? base : base)
            borderColor = .clear
            contentColor = .white
        case .subtle:
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if active {
                fillColor = ScreenClipTone.blue.softBackground
                borderColor = ScreenClipTone.blue.foreground.withAlphaComponent(0.35)
                contentColor = ScreenClipTone.blue.foreground
            } else {
                fillColor = pressed ? (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12))
                    : hovered ? (dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.08))
                    : (dark ? NSColor.white.withAlphaComponent(0.075) : NSColor.black.withAlphaComponent(0.05))
                borderColor = NSColor.screenClipCardBorder
                contentColor = .labelColor
            }
        case .iconCircle:
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            fillColor = pressed ? (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12))
                : hovered ? (dark ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.07))
                : .clear
            borderColor = .clear
            contentColor = hovered ? .labelColor : .screenClipSecondaryLabel
        }

        fillColor.withAlphaComponent(fillColor.alphaComponent * alphaScale).setFill()
        shape.fill()
        if borderColor.alphaComponent > 0 {
            borderColor.withAlphaComponent(borderColor.alphaComponent * alphaScale).setStroke()
            shape.lineWidth = 0.75
            shape.stroke()
        }

        let fg = contentColor.withAlphaComponent(contentColor.alphaComponent * alphaScale)
        if case .iconCircle = pillStyle, let symbolName {
            ScreenClipDrawing.drawSymbol(symbolName, pointSize: 11.5, weight: .semibold, color: fg, centeredIn: bounds)
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: fg
        ]
        let textSize = title.isEmpty ? .zero : (title as NSString).size(withAttributes: attrs)
        let iconWidth: CGFloat = symbolName == nil ? 0 : 13
        let gap: CGFloat = (symbolName != nil && !title.isEmpty) ? 5 : 0
        let totalWidth = iconWidth + gap + textSize.width
        var x = (bounds.midX - totalWidth / 2).rounded()

        if let symbolName {
            ScreenClipDrawing.drawSymbol(symbolName, pointSize: 11, weight: .semibold, color: fg, centeredIn: CGRect(x: x, y: bounds.minY, width: iconWidth, height: bounds.height))
            x += iconWidth + gap
        }
        if !title.isEmpty {
            (title as NSString).draw(at: CGPoint(x: x, y: (bounds.midY - textSize.height / 2).rounded()), withAttributes: attrs)
        }
    }
}

/// Modern macOS pill switch that subclasses NSButton for full compatibility & accessibility.
@MainActor
final class PillToggleSwitch: NSButton {
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    init(title: String, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        setButtonType(.switch)
        isBordered = false
        self.title = title
        self.target = target
        self.action = action
        font = .systemFont(ofSize: 12, weight: .regular)
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12)]
        let textSize = (title as NSString).size(withAttributes: attrs)
        return NSSize(width: 30 + 8 + ceil(textSize.width) + 2, height: 22)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let track = CGRect(x: 0, y: ((bounds.height - 17) / 2).rounded(), width: 30, height: 17)
        let isOn = state == .on
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let trackFill = isOn
            ? ScreenClipTone.green.solidFill
            : (dark ? NSColor.white.withAlphaComponent(0.20) : NSColor.black.withAlphaComponent(0.18))
        trackFill.setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()

        let knobSize: CGFloat = 13
        let knobX = isOn ? track.maxX - knobSize - 2 : track.minX + 2
        let knob = CGRect(x: knobX, y: track.minY + 2, width: knobSize, height: knobSize)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: isEnabled ? NSColor.screenClipSecondaryLabel : NSColor.tertiaryLabelColor
        ]
        let sz = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: track.maxX + 8, y: (bounds.midY - sz.height / 2).rounded()), withAttributes: attrs)
    }
}

/// Compact pill segmented switcher (e.g., 操作 | 快捷键) without heavy native borders.
@MainActor
final class SegmentedPillControl: NSView {
    private var buttons: [NSButton] = []
    private(set) var selectedIndex: Int = 0
    var onSelectionChange: ((Int) -> Void)?

    init(titles: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal; stack.spacing = 2; stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        for (index, title) in titles.enumerated() {
            let button = SegmentItemButton(title: title)
            button.tag = index
            button.target = self
            button.action = #selector(segmentPressed(_:))
            button.setAccessibilityLabel(title)
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        select(0, notify: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ index: Int, notify: Bool = false) {
        guard buttons.indices.contains(index) else { return }
        selectedIndex = index
        for (i, button) in buttons.enumerated() {
            (button as? SegmentItemButton)?.isActiveSegment = (i == index)
        }
        needsDisplay = true
        if notify { onSelectionChange?(index) }
    }

    @objc private func segmentPressed(_ sender: NSButton) {
        guard sender.tag != selectedIndex else { return }
        select(sender.tag, notify: true)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = dark ? NSColor.white.withAlphaComponent(0.085) : NSColor.black.withAlphaComponent(0.065)
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8.5, yRadius: 8.5).fill()
    }
}

@MainActor
private final class SegmentItemButton: NSButton {
    var isActiveSegment = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium)]
        let sz = (title as NSString).size(withAttributes: attrs)
        return NSSize(width: max(54, ceil(sz.width) + 18), height: 22)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isActiveSegment {
            let pill = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.white).setFill()
            pill.fill()
            (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.06)).setStroke()
            pill.lineWidth = 0.6; pill.stroke()
        } else if hovered {
            let pill = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.035)).setFill()
            pill.fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isActiveSegment ? .semibold : .medium),
            .foregroundColor: isActiveSegment ? NSColor.labelColor : NSColor.screenClipSecondaryLabel
        ]
        let sz = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(
            x: (bounds.midX - sz.width / 2).rounded(),
            y: (bounds.midY - sz.height / 2).rounded()
        ), withAttributes: attrs)
    }
}

/// Modern pill segmented control subclassing NSSegmentedControl for full AppKit & test compatibility.
@MainActor
final class PillSegmentedControl: NSSegmentedControl {
    private var hoveredIndex: Int?
    private var tracking: NSTrackingArea?

    override var selectedSegment: Int { didSet { needsDisplay = true } }

    init(titles: [String]) {
        super.init(frame: .zero)
        segmentCount = titles.count
        trackingMode = .selectOne
        for (i, title) in titles.enumerated() { setLabel(title, forSegment: i) }
        selectedSegment = 0
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func segmentWidths() -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return (0..<segmentCount).map { idx in
            let text = label(forSegment: idx) ?? ""
            let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            return max(46, w + 20)
        }
    }

    private func segmentRects(in rect: NSRect) -> [CGRect] {
        let widths = segmentWidths()
        let totalPreferred = widths.reduce(0, +)
        let inner = rect.insetBy(dx: 3, dy: 3)
        let scale = totalPreferred > 0 ? inner.width / totalPreferred : 1
        var x = inner.minX
        return widths.enumerated().map { idx, width in
            let w = idx == widths.count - 1 ? max(0, inner.maxX - x) : (width * scale).rounded()
            let seg = CGRect(x: x, y: inner.minY, width: w, height: inner.height)
            x += w
            return seg
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segmentWidths().reduce(0, +) + 6, height: 28)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = segmentRects(in: bounds).firstIndex { $0.contains(p) }
        if idx != hoveredIndex { hoveredIndex = idx; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil { hoveredIndex = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let idx = segmentRects(in: bounds).firstIndex(where: { $0.contains(p) }), idx != selectedSegment {
            selectedSegment = idx
            needsDisplay = true
            if let action { sendAction(action, to: target) }
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = dark ? NSColor.white.withAlphaComponent(0.085) : NSColor.black.withAlphaComponent(0.065)
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8.5, yRadius: 8.5).fill()

        let rects = segmentRects(in: bounds)
        for (idx, rect) in rects.enumerated() {
            let active = idx == selectedSegment
            if active {
                let pill = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                (dark ? NSColor.white.withAlphaComponent(0.19) : NSColor.white).setFill()
                pill.fill()
                (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.07)).setStroke()
                pill.lineWidth = 0.6; pill.stroke()
            } else if hoveredIndex == idx {
                let pill = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)).setFill()
                pill.fill()
            }
            let text = label(forSegment: idx) ?? ""
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .medium),
                .foregroundColor: active ? NSColor.labelColor : NSColor.screenClipSecondaryLabel
            ]
            let sz = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(
                x: (rect.midX - sz.width / 2).rounded(),
                y: (rect.midY - sz.height / 2).rounded()
            ), withAttributes: attrs)
        }
    }
}

/// Non-interactive tinted tag pill with optional leading SF Symbol.
@MainActor
final class TagPillView: NSView {
    var text: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var symbolName: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var tone: ScreenClipTone { didSet { needsDisplay = true } }

    init(text: String = "", symbolName: String? = nil, tone: ScreenClipTone = .slate) {
        self.text = text; self.symbolName = symbolName; self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let textW = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let iconW: CGFloat = symbolName == nil ? 0 : 12
        let gap: CGFloat = (symbolName != nil && !text.isEmpty) ? 5 : 0
        return NSSize(width: max(22, 18 + iconW + gap + textW), height: 22)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty || symbolName != nil else { return }
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        tone.softBackground.setFill(); path.fill()
        tone.foreground.withAlphaComponent(0.18).setStroke(); path.lineWidth = 0.7; path.stroke()

        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tone.foreground]
        let textSize = text.isEmpty ? .zero : (text as NSString).size(withAttributes: attrs)
        let iconW: CGFloat = symbolName == nil ? 0 : 12
        let gap: CGFloat = (symbolName != nil && !text.isEmpty) ? 5 : 0
        var x = (bounds.midX - (iconW + gap + textSize.width) / 2).rounded()
        if let symbolName {
            ScreenClipDrawing.drawSymbol(symbolName, pointSize: 10.5, weight: .semibold, color: tone.foreground,
                                         centeredIn: CGRect(x: x, y: bounds.minY, width: iconW, height: bounds.height))
            x += iconW + gap
        }
        if !text.isEmpty {
            (text as NSString).draw(at: CGPoint(x: x, y: (bounds.midY - textSize.height / 2).rounded()), withAttributes: attrs)
        }
    }
}

/// Keycap shortcut hint (e.g., [⌘↵] 仅复制) for compact window footers.
@MainActor
final class KeycapHintView: NSView {
    private let keyText: String
    private let labelText: String

    init(key: String, label: String) {
        self.keyText = key; self.labelText = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let cap = ScreenClipDrawing.keycapSize(for: keyText, fontSize: 10.5)
        let lbl = (labelText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .regular)])
        return NSSize(width: cap.width + 6 + ceil(lbl.width), height: max(20, cap.height))
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let capSize = ScreenClipDrawing.keycapSize(for: keyText, fontSize: 10.5)
        let capRect = CGRect(x: 0, y: ((bounds.height - capSize.height) / 2).rounded(), width: capSize.width, height: capSize.height)
        ScreenClipDrawing.drawKeycap(keyText, in: capRect, fontSize: 10.5, emphasized: false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.screenClipSecondaryLabel
        ]
        let sz = (labelText as NSString).size(withAttributes: attrs)
        (labelText as NSString).draw(at: CGPoint(x: capRect.maxX + 6, y: (bounds.midY - sz.height / 2).rounded()), withAttributes: attrs)
    }
}
