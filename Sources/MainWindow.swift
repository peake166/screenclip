import AppKit

private final class CaptureActionButton: NSButton {
    private let actionName: String
    private let symbol: NSImage?
    private let nameLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var hovered = false
    private var tracking: NSTrackingArea?
    var shortcut: Shortcut? {
        didSet {
            shortcutLabel.stringValue = shortcut?.display ?? ""
            shortcutLabel.isHidden = shortcut == nil
            needsDisplay = true
            updateAccessibility()
        }
    }

    init(action: ShortcutAction, symbolName: String) {
        actionName = action.title
        symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 19, weight: .medium))
        super.init(frame: .zero)
        title = ""; isBordered = false; setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 52).isActive = true
        nameLabel.stringValue = actionName
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .labelColor
        shortcutLabel.font = .systemFont(ofSize: 12, weight: .medium)
        shortcutLabel.textColor = .screenClipSecondaryLabel
        shortcutLabel.isHidden = true
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [nameLabel, shortcutLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 60),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -12),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
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
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (hovered || pressed ? NSColor.screenClipAccent.withAlphaComponent(pressed ? 0.14 : 0.07) : NSColor.clear).setFill()
        shape.fill()
        NSColor.separatorColor.withAlphaComponent(hovered ? 0.45 : 0).setStroke(); shape.lineWidth = 0.7; shape.stroke()
        let tile = CGRect(x: 12, y: 8, width: 36, height: 36)
        NSColor.screenClipAccent.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 9, yRadius: 9).fill()
        if let symbol {
            let symbolColor = NSColor.screenClipAccent
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbolColor.setFill(); rect.fill()
                symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
            let size = symbol.size
            tinted.draw(in: CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height))
        }
        if !shortcutLabel.isHidden {
            let badge = shortcutLabel.convert(shortcutLabel.bounds, to: self).insetBy(dx: -7, dy: -4)
            NSColor.labelColor.withAlphaComponent(0.035).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        }
    }
}

@MainActor
final class MainWindow: NSWindow, NSWindowDelegate {
    var onCapture: ((ShortcutAction) -> Void)?
    var onPermission: (() -> Void)?
    var onTranslationSettings: (() -> Void)?
    var onLoginItemChange: ((Bool) -> Void)?
    var onLoginItemSettings: (() -> Void)?
    var onBeginRecording: (() -> Bool)?
    var onEndRecording: (() -> Void)?
    var onShortcutChange: ((ShortcutAction, Shortcut?) -> String?)?
    var onReset: (() -> String?)?
    private let permission = NSButton()
    private let toggle = NSButton()
    private let loginItem = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let loginItemApproval = NSButton(title: "允许…", target: nil, action: nil)
    private let feedback = NSTextField(labelWithString: "")
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var captureButtons: [ShortcutAction: CaptureActionButton] = [:]
    private let settings = NSStackView()
    private var expanded = false
    private var collapsedFrameHeight: CGFloat = 0

    init(icon: NSImage?) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 420, height: 428),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "截图助手"; titleVisibility = .hidden; titlebarAppearsTransparent = true
        isReleasedWhenClosed = false; isMovableByWindowBackground = true
        delegate = self
        let effect = FrostedSurface()
        contentView = effect
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(root)
        // Keep the native close control above the layer-backed full-size glass content.
        if let close = NSWindow.standardWindowButton(.closeButton, for: styleMask) {
            standardWindowButton(.closeButton)?.isHidden = true
            close.target = self; close.action = #selector(NSWindow.performClose(_:))
            close.setAccessibilityLabel("关闭窗口"); close.toolTip = "关闭窗口"
            close.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(close)
            NSLayoutConstraint.activate([
                close.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
                close.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
                close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16)
            ])
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: effect.topAnchor, constant: 50)
        ])
        let image = NSImageView()
        image.image = icon; image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 40).isActive = true
        image.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let name = NSTextField(labelWithString: "截图助手")
        name.font = .systemFont(ofSize: 18, weight: .medium)
        permission.target = self; permission.action = #selector(permissionPressed)
        permission.isBordered = false; permission.font = .systemFont(ofSize: 11, weight: .medium)
        permission.setAccessibilityLabel("截图权限")
        let spacer = NSView()
        let header = NSStackView(views: [image, name, spacer, permission])
        header.spacing = 9; header.alignment = .centerY
        root.addArrangedSubview(header)
        let buttons = NSStackView(); buttons.orientation = .vertical; buttons.spacing = 1
        for action in ShortcutAction.allCases {
            let button = CaptureActionButton(action: action, symbolName: action.symbolName)
            button.target = self
            switch action { case .copy: button.action = #selector(copyPressed); case .scroll: button.action = #selector(scrollPressed); case .translate: button.action = #selector(translatePressed); case .clipboard: button.action = #selector(clipboardPressed) }
            captureButtons[action] = button; buttons.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: buttons.widthAnchor).isActive = true
        }
        root.addArrangedSubview(buttons)
        let separator = NSBox(); separator.boxType = .separator
        root.addArrangedSubview(separator)
        toggle.title = "快捷键"; toggle.isBordered = false
        toggle.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        toggle.imagePosition = .imageLeft; toggle.imageHugsTitle = true
        toggle.contentTintColor = .screenClipSecondaryLabel; toggle.font = .systemFont(ofSize: 12, weight: .medium)
        toggle.target = self; toggle.action = #selector(toggleSettings)
        toggle.setAccessibilityLabel("快捷键设置")
        let translationSettings = NSButton(title: "翻译设置…", target: self, action: #selector(translationSettingsPressed))
        translationSettings.isBordered = false; translationSettings.font = .systemFont(ofSize: 12)
        translationSettings.contentTintColor = .screenClipSecondaryLabel
        let toggleRow = NSStackView(views: [toggle, NSView(), translationSettings]); toggleRow.heightAnchor.constraint(equalToConstant: 26).isActive = true
        root.addArrangedSubview(toggleRow)
        loginItem.target = self; loginItem.action = #selector(loginItemPressed)
        loginItem.font = .systemFont(ofSize: 12)
        loginItem.setAccessibilityLabel("登录时启动")
        loginItemApproval.target = self; loginItemApproval.action = #selector(loginItemSettingsPressed)
        loginItemApproval.isBordered = false; loginItemApproval.font = .systemFont(ofSize: 12)
        loginItemApproval.contentTintColor = .screenClipAccent
        loginItemApproval.setAccessibilityLabel("在系统设置中允许登录时启动")
        loginItemApproval.isHidden = true
        let loginItemRow = NSStackView(views: [loginItem, NSView(), loginItemApproval])
        loginItemRow.heightAnchor.constraint(equalToConstant: 26).isActive = true
        root.addArrangedSubview(loginItemRow)
        settings.orientation = .vertical; settings.alignment = .leading; settings.spacing = 10
        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            label.font = .systemFont(ofSize: 12); label.textColor = .screenClipSecondaryLabel
            let recorder = ShortcutRecorder()
            recorder.setAccessibilityLabel(action.title + "快捷键")
            recorder.onBegin = { [weak self] in
                guard let self else { return false }
                return self.onBeginRecording?() ?? true
            }
            recorder.onEnd = { [weak self] in self?.onEndRecording?() }
            recorder.onApply = { [weak self] shortcut in self?.onShortcutChange?(action, shortcut) }
            recorder.onError = { [weak self] message in self?.showFeedback(message, isError: message != nil) }
            recorders[action] = recorder
            let row = NSStackView(views: [label, NSView(), recorder]); row.alignment = .centerY
            settings.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true
        }
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetPressed))
        reset.isBordered = false; reset.font = .systemFont(ofSize: 11)
        reset.contentTintColor = .screenClipSecondaryLabel
        feedback.font = .systemFont(ofSize: 11); feedback.alignment = .right
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [reset, feedback]); footer.spacing = 12
        footer.heightAnchor.constraint(equalToConstant: 22).isActive = true
        settings.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true
        settings.isHidden = true; root.addArrangedSubview(settings)
        for view in [header, buttons, separator, toggleRow, loginItemRow, settings] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        collapsedFrameHeight = frame.height
        center()
    }

    func update(bindings: [ShortcutAction: Shortcut], permissionGranted: Bool) {
        for action in ShortcutAction.allCases {
            captureButtons[action]?.shortcut = bindings[action]
            recorders[action]?.shortcut = bindings[action]
        }
        permission.attributedTitle = NSAttributedString(string: permissionGranted ? "● 就绪" : "授权截图", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: permissionGranted ? NSColor.screenClipSecondaryLabel : NSColor.screenClipAccent
        ])
        permission.contentTintColor = permissionGranted ? .screenClipSecondaryLabel : .screenClipAccent
        permission.toolTip = permissionGranted ? "截图权限已开启" : "开启屏幕录制权限"
    }
    func revealSettings() { if !expanded { toggleSettings() } }
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
        feedback.stringValue = message ?? ""
        feedback.textColor = isError ? .systemRed : .screenClipSecondaryLabel
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
    @objc private func clipboardPressed() { onCapture?(.clipboard) }
    @objc private func translationSettingsPressed() { stopRecording(); onTranslationSettings?() }
    @objc private func loginItemPressed() { onLoginItemChange?(loginItem.state == .on) }
    @objc private func loginItemSettingsPressed() { onLoginItemSettings?() }
    @objc private func permissionPressed() { onPermission?() }
    @objc private func toggleSettings() {
        if expanded { stopRecording() }
        expanded.toggle(); settings.isHidden = !expanded
        toggle.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        var newFrame = frame
        let height = collapsedFrameHeight + (expanded ? 186 : 0)
        newFrame.origin.y += newFrame.height - height; newFrame.size.height = height
        setFrame(newFrame, display: true)
    }
    @objc private func resetPressed() {
        stopRecording()
        if let error = onReset?() { showFeedback(error, isError: true) }
        else { showFeedback("已恢复默认") }
    }
}
