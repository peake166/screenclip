import AppKit

private extension ShortcutAction {
    var tone: ScreenClipTone {
        switch self {
        case .copy: return .blue
        case .scroll: return .teal
        case .translate: return .indigo
        case .pinCapture: return .amber
        case .pinClipboard: return .amber
        case .clipboard: return .slate
        }
    }

    var subtitle: String {
        switch self {
        case .copy: return "冻结画面并复制"
        case .scroll: return "自动拼接长页面"
        case .translate: return "原位覆盖显示译文"
        case .pinCapture: return "常驻置顶悬浮窗"
        case .pinClipboard: return "剪贴板图片"
        case .clipboard: return "搜索与粘贴"
        }
    }

    var compactDisplayTitle: String {
        switch self {
        case .pinClipboard: return "贴出剪贴板"
        default: return title
        }
    }
}

@MainActor
private final class HeroActionTile: NSButton {
    private let actionName: String
    private let subtitleText: String
    private let symbolName: String
    private let tone: ScreenClipTone
    private var hovered = false
    private var tracking: NSTrackingArea?

    var shortcut: Shortcut? {
        didSet {
            needsDisplay = true
            updateAccessibility()
        }
    }

    init(action: ShortcutAction) {
        actionName = action.title
        subtitleText = action.subtitle
        symbolName = action.symbolName
        tone = action.tone
        super.init(frame: .zero)
        title = ""; isBordered = false; setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 92).isActive = true
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateAccessibility() {
        setAccessibilityLabel(actionName + (shortcut.map { "，快捷键 " + $0.display } ?? ""))
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        let fill = pressed ? tone.softBackground : (hovered ? NSColor.screenClipCardHoverFill : NSColor.screenClipCardFill)
        fill.setFill()
        shape.fill()
        let border = (hovered || pressed) ? tone.foreground.withAlphaComponent(pressed ? 0.55 : 0.38) : NSColor.screenClipCardBorder
        border.setStroke()
        shape.lineWidth = (hovered || pressed) ? 1.1 : 0.8
        shape.stroke()

        // NSButton uses a flipped coordinate system (y = 0 at top).
        // Top-left semantic icon badge.
        let badge = CGRect(x: 13, y: 12, width: 34, height: 34)
        tone.softBackground.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
        ScreenClipDrawing.drawSymbol(symbolName, pointSize: 16, weight: .semibold, color: tone.foreground, centeredIn: badge)

        // Top-right keycap badge.
        if let text = shortcut?.display {
            let capSize = ScreenClipDrawing.keycapSize(for: text, fontSize: 11)
            let capRect = CGRect(
                x: bounds.width - 13 - capSize.width,
                y: (badge.midY - capSize.height / 2).rounded(),
                width: capSize.width,
                height: capSize.height
            )
            ScreenClipDrawing.drawKeycap(text, in: capRect, fontSize: 11, emphasized: hovered)
        }

        // Bottom title & subtitle.
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.screenClipSecondaryLabel
        ]
        (actionName as NSString).draw(at: CGPoint(x: 13, y: 52), withAttributes: titleAttrs)
        (subtitleText as NSString).draw(at: CGPoint(x: 13, y: 70), withAttributes: subAttrs)
    }
}

@MainActor
private final class CompactStripActionButton: NSButton {
    private let accessibilityName: String
    private let displayName: String
    private let fallbackMeta: String
    private let symbolName: String
    private let tone: ScreenClipTone
    private var hovered = false
    private var tracking: NSTrackingArea?

    var shortcut: Shortcut? {
        didSet {
            needsDisplay = true
            updateAccessibility()
        }
    }

    init(accessibilityName: String, displayName: String, fallbackMeta: String, symbolName: String, tone: ScreenClipTone) {
        self.accessibilityName = accessibilityName
        self.displayName = displayName
        self.fallbackMeta = fallbackMeta
        self.symbolName = symbolName
        self.tone = tone
        super.init(frame: .zero)
        title = ""; isBordered = false; setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 80).isActive = true
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateAccessibility() {
        setAccessibilityLabel(accessibilityName + (shortcut.map { "，快捷键 " + $0.display } ?? ""))
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        if hovered || pressed {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bg = pressed
                ? tone.softBackground
                : (dark ? NSColor.white.withAlphaComponent(0.065) : NSColor.black.withAlphaComponent(0.04))
            bg.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
        }

        // NSButton uses a flipped coordinate system (y = 0 at top).
        let badge = CGRect(x: ((bounds.width - 28) / 2).rounded(), y: 11, width: 28, height: 28)
        tone.softBackground.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        ScreenClipDrawing.drawSymbol(symbolName, pointSize: 13.5, weight: .semibold, color: tone.foreground, centeredIn: badge)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let tSize = (displayName as NSString).size(withAttributes: titleAttrs)
        (displayName as NSString).draw(at: CGPoint(x: ((bounds.width - tSize.width) / 2).rounded(), y: 44), withAttributes: titleAttrs)

        let metaText = shortcut?.display ?? fallbackMeta
        let metaFont = shortcut != nil
            ? NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
            : NSFont.systemFont(ofSize: 10.5, weight: .regular)
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: metaFont,
            .foregroundColor: NSColor.screenClipSecondaryLabel
        ]
        let mSize = (metaText as NSString).size(withAttributes: metaAttrs)
        (metaText as NSString).draw(at: CGPoint(x: ((bounds.width - mSize.width) / 2).rounded(), y: 61), withAttributes: metaAttrs)
    }
}

@MainActor
private final class StatusBadgeButton: NSButton {
    var isGranted = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false; focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("截图权限")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var labelText: String { isGranted ? "就绪" : "授权截图" }

    override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]
        let sz = (labelText as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(sz.width) + 26, height: 22)
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
        let tone: ScreenClipTone = isGranted ? .green : .amber
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (hovered ? tone.hoverBackground : tone.softBackground).setFill()
        path.fill()
        tone.foreground.withAlphaComponent(hovered ? 0.38 : 0.18).setStroke()
        path.lineWidth = 0.7; path.stroke()

        let dot = CGRect(x: 8.5, y: ((bounds.height - 6) / 2).rounded(), width: 6, height: 6)
        tone.foreground.setFill()
        NSBezierPath(ovalIn: dot).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: tone.foreground
        ]
        let sz = (labelText as NSString).size(withAttributes: attrs)
        (labelText as NSString).draw(at: CGPoint(x: dot.maxX + 5, y: (bounds.midY - sz.height / 2).rounded()), withAttributes: attrs)
    }
}

@MainActor
private final class ShortcutIconBadge: NSView {
    private let symbolName: String
    private let tone: ScreenClipTone
    init(symbolName: String, tone: ScreenClipTone) {
        self.symbolName = symbolName; self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        tone.softBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6.5, yRadius: 6.5).fill()
        ScreenClipDrawing.drawSymbol(symbolName, pointSize: 11.5, weight: .semibold, color: tone.foreground, centeredIn: bounds)
    }
}

@MainActor
final class MainWindow: NSWindow, NSWindowDelegate {
    var onCapture: ((ShortcutAction) -> Void)?
    var onPermission: (() -> Void)?
    var onTranslationSettings: (() -> Void)?
    var onPinImageFile: (() -> Void)?
    var onLoginItemChange: ((Bool) -> Void)?
    var onLoginItemSettings: (() -> Void)?
    var onBeginRecording: (() -> Bool)?
    var onEndRecording: (() -> Void)?
    var onShortcutChange: ((ShortcutAction, Shortcut?) -> String?)?
    var onReset: (() -> String?)?

    private let permission = StatusBadgeButton(target: nil, action: #selector(permissionPressed))
    private let tabs = SegmentedPillControl(titles: ["操作", "快捷键"])
    private let loginItem = PillToggleSwitch(title: "登录时启动")
    private let loginItemApproval = NSButton(title: "允许…", target: nil, action: nil)
    private let feedback = NSTextField(labelWithString: "")
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var heroTiles: [ShortcutAction: HeroActionTile] = [:]
    private var stripButtons: [ShortcutAction: CompactStripActionButton] = [:]
    private let operationsPanel = NSStackView()
    private let shortcutsPanel = NSStackView()

    init(icon: NSImage?) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 484, height: 404),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "截图助手"; titleVisibility = .hidden; titlebarAppearsTransparent = true
        isReleasedWhenClosed = false; isMovableByWindowBackground = true
        delegate = self
        let effect = FrostedSurface(radius: 18)
        contentView = effect

        // Keep native traffic-light window controls together at upper-left inside the glass surface.
        let windowControls = NSStackView()
        windowControls.orientation = .horizontal; windowControls.alignment = .centerY
        windowControls.distribution = .fill; windowControls.spacing = 9
        windowControls.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(windowControls)
        let controlActions: [(NSWindow.ButtonType, String, Selector)] = [
            (.closeButton, "关闭窗口", #selector(NSWindow.performClose(_:))),
            (.miniaturizeButton, "最小化窗口", #selector(NSWindow.performMiniaturize(_:))),
            (.zoomButton, "缩放窗口", #selector(NSWindow.performZoom(_:)))
        ]
        for (type, label, action) in controlActions {
            let native = standardWindowButton(type)
            let enabled = native?.isEnabled ?? false
            native?.isHidden = true
            guard let button = NSWindow.standardWindowButton(type, for: styleMask) else { continue }
            button.target = self; button.action = action; button.isEnabled = enabled
            button.setAccessibilityLabel(label); button.toolTip = label
            windowControls.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 14), button.heightAnchor.constraint(equalToConstant: 14)
            ])
        }

        // Brand mark aligned beside traffic lights.
        let iconView = NSImageView()
        iconView.image = icon; iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let brandName = NSTextField(labelWithString: "截图助手")
        brandName.font = .systemFont(ofSize: 13, weight: .semibold)
        brandName.textColor = .labelColor
        let brand = NSStackView(views: [iconView, brandName])
        brand.orientation = .horizontal; brand.spacing = 6; brand.alignment = .centerY
        brand.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(brand)

        tabs.onSelectionChange = { [weak self] index in self?.switchTab(index) }
        effect.addSubview(tabs)

        permission.target = self; permission.action = #selector(permissionPressed)
        effect.addSubview(permission)

        NSLayoutConstraint.activate([
            windowControls.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            windowControls.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            brand.leadingAnchor.constraint(equalTo: windowControls.trailingAnchor, constant: 14),
            brand.centerYAnchor.constraint(equalTo: windowControls.centerYAnchor),
            tabs.centerXAnchor.constraint(equalTo: effect.centerXAnchor, constant: 14),
            tabs.centerYAnchor.constraint(equalTo: windowControls.centerYAnchor),
            permission.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            permission.centerYAnchor.constraint(equalTo: windowControls.centerYAnchor)
        ])

        // Main content slot (shared fixed height between Operations and Shortcuts tabs).
        let bodyContainer = NSView()
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(bodyContainer)

        buildOperationsPanel()
        buildShortcutsPanel()

        for panel in [operationsPanel, shortcutsPanel] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            bodyContainer.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                panel.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
                panel.bottomAnchor.constraint(lessThanOrEqualTo: bodyContainer.bottomAnchor)
            ])
        }
        shortcutsPanel.isHidden = true

        // Bottom utility bar.
        let bottomDivider = HairlineDivider(vertical: false)
        effect.addSubview(bottomDivider)

        loginItem.target = self; loginItem.action = #selector(loginItemPressed)
        loginItem.setAccessibilityLabel("登录时启动")
        loginItemApproval.target = self; loginItemApproval.action = #selector(loginItemSettingsPressed)
        loginItemApproval.isBordered = false; loginItemApproval.font = .systemFont(ofSize: 12, weight: .medium)
        loginItemApproval.contentTintColor = .screenClipAccent
        loginItemApproval.setAccessibilityLabel("在系统设置中允许登录时启动")
        loginItemApproval.isHidden = true

        let translationSettings = PillActionButton(
            title: "翻译设置…",
            symbolName: "gearshape",
            style: .subtle,
            target: self,
            action: #selector(translationSettingsPressed)
        )
        translationSettings.fixedHeight = 26
        translationSettings.horizontalPadding = 10

        let footerBar = NSStackView(views: [loginItem, loginItemApproval, NSView(), translationSettings])
        footerBar.orientation = .horizontal; footerBar.alignment = .centerY; footerBar.spacing = 8
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(footerBar)

        NSLayoutConstraint.activate([
            bodyContainer.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            bodyContainer.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            bodyContainer.topAnchor.constraint(equalTo: effect.topAnchor, constant: 52),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -14),

            bottomDivider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: footerBar.topAnchor, constant: -10),

            footerBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            footerBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            footerBar.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -11),
            footerBar.heightAnchor.constraint(equalToConstant: 28)
        ])

        center()
    }

    private func buildOperationsPanel() {
        operationsPanel.orientation = .vertical
        operationsPanel.alignment = .leading
        operationsPanel.spacing = 12

        // 2x2 Hero Tile Grid.
        let row1 = makeHeroRow([.copy, .pinCapture])
        let row2 = makeHeroRow([.translate, .scroll])
        let grid = NSStackView(views: [row1, row2])
        grid.orientation = .vertical; grid.spacing = 10; grid.alignment = .leading
        operationsPanel.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: operationsPanel.widthAnchor).isActive = true
        row1.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        row2.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        // Bottom 3-column InsetCard for Clipboard Pin, Pick Local File, Clipboard History.
        let stripCard = InsetCardView(radius: 13)
        stripCard.translatesAutoresizingMaskIntoConstraints = false
        let pinClipBtn = CompactStripActionButton(
            accessibilityName: ShortcutAction.pinClipboard.title,
            displayName: ShortcutAction.pinClipboard.compactDisplayTitle,
            fallbackMeta: ShortcutAction.pinClipboard.subtitle,
            symbolName: ShortcutAction.pinClipboard.symbolName,
            tone: ShortcutAction.pinClipboard.tone
        )
        pinClipBtn.target = self; pinClipBtn.action = #selector(pinClipboardPressed)
        stripButtons[.pinClipboard] = pinClipBtn

        let pickFileBtn = CompactStripActionButton(
            accessibilityName: "选择本地图片贴到屏幕",
            displayName: "选图贴屏…",
            fallbackMeta: "本地图片",
            symbolName: "folder",
            tone: .blue
        )
        pickFileBtn.target = self; pickFileBtn.action = #selector(pinFilePressed)

        let historyBtn = CompactStripActionButton(
            accessibilityName: ShortcutAction.clipboard.title,
            displayName: ShortcutAction.clipboard.compactDisplayTitle,
            fallbackMeta: ShortcutAction.clipboard.subtitle,
            symbolName: ShortcutAction.clipboard.symbolName,
            tone: ShortcutAction.clipboard.tone
        )
        historyBtn.target = self; historyBtn.action = #selector(clipboardPressed)
        stripButtons[.clipboard] = historyBtn

        let sep1 = HairlineDivider(vertical: true)
        let sep2 = HairlineDivider(vertical: true)
        let stripRow = NSStackView(views: [pinClipBtn, sep1, pickFileBtn, sep2, historyBtn])
        stripRow.orientation = .horizontal; stripRow.spacing = 0; stripRow.alignment = .centerY
        stripRow.distribution = .fill
        stripRow.translatesAutoresizingMaskIntoConstraints = false
        stripCard.addSubview(stripRow)
        NSLayoutConstraint.activate([
            stripRow.leadingAnchor.constraint(equalTo: stripCard.leadingAnchor),
            stripRow.trailingAnchor.constraint(equalTo: stripCard.trailingAnchor),
            stripRow.topAnchor.constraint(equalTo: stripCard.topAnchor),
            stripRow.bottomAnchor.constraint(equalTo: stripCard.bottomAnchor),
            pinClipBtn.widthAnchor.constraint(equalTo: pickFileBtn.widthAnchor),
            pickFileBtn.widthAnchor.constraint(equalTo: historyBtn.widthAnchor),
            sep1.heightAnchor.constraint(equalTo: stripCard.heightAnchor, constant: -20),
            sep2.heightAnchor.constraint(equalTo: stripCard.heightAnchor, constant: -20)
        ])
        operationsPanel.addArrangedSubview(stripCard)
        stripCard.widthAnchor.constraint(equalTo: operationsPanel.widthAnchor).isActive = true
    }

    private func makeHeroRow(_ actions: [ShortcutAction]) -> NSStackView {
        let tiles = actions.map { action -> HeroActionTile in
            let tile = HeroActionTile(action: action)
            tile.target = self
            switch action {
            case .copy: tile.action = #selector(copyPressed)
            case .scroll: tile.action = #selector(scrollPressed)
            case .translate: tile.action = #selector(translatePressed)
            case .pinCapture: tile.action = #selector(pinCapturePressed)
            case .pinClipboard: tile.action = #selector(pinClipboardPressed)
            case .clipboard: tile.action = #selector(clipboardPressed)
            }
            heroTiles[action] = tile
            return tile
        }
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal; row.spacing = 10; row.distribution = .fillEqually
        return row
    }

    private func buildShortcutsPanel() {
        shortcutsPanel.orientation = .vertical
        shortcutsPanel.alignment = .leading
        shortcutsPanel.spacing = 10

        let card = InsetCardView(radius: 13)
        card.translatesAutoresizingMaskIntoConstraints = false
        let list = NSStackView()
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            list.topAnchor.constraint(equalTo: card.topAnchor),
            list.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        for (index, action) in ShortcutAction.allCases.enumerated() {
            if index > 0 {
                let divider = HairlineDivider(vertical: false)
                list.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            let badge = ShortcutIconBadge(symbolName: action.symbolName, tone: action.tone)
            let label = NSTextField(labelWithString: action.title)
            label.font = .systemFont(ofSize: 12.5, weight: .medium)
            label.textColor = .labelColor
            let recorder = ShortcutRecorder()
            recorder.setAccessibilityLabel(action.title + "快捷键")
            recorder.onBegin = { [weak self] in self?.onBeginRecording?() ?? true }
            recorder.onEnd = { [weak self] in self?.onEndRecording?() }
            recorder.onApply = { [weak self] shortcut in self?.onShortcutChange?(action, shortcut) }
            recorder.onError = { [weak self] message in self?.showFeedback(message, isError: message != nil) }
            recorders[action] = recorder

            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            let content = NSStackView(views: [badge, label, NSView(), recorder])
            content.orientation = .horizontal; content.alignment = .centerY; content.spacing = 10
            content.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                content.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        shortcutsPanel.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: shortcutsPanel.widthAnchor).isActive = true

        let reset = PillActionButton(title: "恢复默认", style: .subtle, target: self, action: #selector(resetPressed))
        reset.fixedHeight = 24; reset.horizontalPadding = 10
        feedback.font = .systemFont(ofSize: 11.5); feedback.textColor = .screenClipSecondaryLabel
        feedback.stringValue = "点击右侧键帽录制，Delete 清除"
        feedback.lineBreakMode = .byTruncatingTail
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [feedback, NSView(), reset])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 10
        shortcutsPanel.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: shortcutsPanel.widthAnchor).isActive = true
    }

    private func switchTab(_ index: Int) {
        if index == 0 { stopRecording() }
        operationsPanel.isHidden = index != 0
        shortcutsPanel.isHidden = index != 1
    }

    func update(bindings: [ShortcutAction: Shortcut], permissionGranted: Bool) {
        for action in ShortcutAction.allCases {
            heroTiles[action]?.shortcut = bindings[action]
            stripButtons[action]?.shortcut = bindings[action]
            recorders[action]?.shortcut = bindings[action]
        }
        permission.isGranted = permissionGranted
        permission.toolTip = permissionGranted ? "截图权限已开启" : "开启屏幕录制权限"
    }

    func revealSettings() {
        tabs.select(1, notify: true)
    }

    func updateLoginItem(_ state: LoginItemState) {
        loginItem.state = state.isRequested ? .on : .off
        loginItem.title = state == .requiresApproval ? "登录时启动 · 待允许" : "登录时启动"
        loginItemApproval.isHidden = state != .requiresApproval
        loginItem.toolTip = state == .requiresApproval ? "请在系统设置的“登录项”中允许截图助手" : nil
    }

    func showLoginItemError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "登录启动设置未能更改"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: self)
    }

    func showFeedback(_ message: String?, isError: Bool = false) {
        if let message, !message.isEmpty {
            feedback.stringValue = message
            feedback.textColor = isError ? .systemRed : ScreenClipTone.green.foreground
        } else {
            feedback.stringValue = "点击右侧键帽录制，Delete 清除"
            feedback.textColor = .screenClipSecondaryLabel
        }
    }

    func stopRecording() { recorders.values.forEach { $0.cancelRecording() } }
    func windowWillClose(_ notification: Notification) { stopRecording() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = firstResponder as? ShortcutRecorder, recorder.isRecording {
            recorder.keyDown(with: event); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func copyPressed() { onCapture?(.copy) }
    @objc private func scrollPressed() { onCapture?(.scroll) }
    @objc private func translatePressed() { onCapture?(.translate) }
    @objc private func pinCapturePressed() { onCapture?(.pinCapture) }
    @objc private func pinClipboardPressed() { onCapture?(.pinClipboard) }
    @objc private func clipboardPressed() { onCapture?(.clipboard) }
    @objc private func translationSettingsPressed() { stopRecording(); onTranslationSettings?() }
    @objc private func pinFilePressed() { stopRecording(); onPinImageFile?() }
    @objc private func loginItemPressed() { onLoginItemChange?(loginItem.state == .on) }
    @objc private func loginItemSettingsPressed() { onLoginItemSettings?() }
    @objc private func permissionPressed() { onPermission?() }
    @objc private func resetPressed() {
        stopRecording()
        if let error = onReset?() { showFeedback(error, isError: true) }
        else { showFeedback("已恢复默认") }
    }
}
