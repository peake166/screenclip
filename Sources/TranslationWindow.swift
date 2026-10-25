import AppKit

@MainActor
final class TranslationWindow: NSPanel, NSWindowDelegate {
    var onSettings: (() -> Void)?
    var onRecapture: (() -> Void)?
    private let store: TranslationSettingsStore
    private let system = SystemTranslation()
    private let cloud = CloudTranslation()
    private let recognize: (Raster) async throws -> String
    private let translator: ((String, TranslationSettings) async throws -> String)?
    private let board: NSPasteboard
    private let service = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let tabs = NSSegmentedControl(labels: ["译文", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let copy = NSButton(title: "复制译文", target: nil, action: nil)
    private let copyOriginal = NSButton(title: "复制原文", target: nil, action: nil)
    private let retry = NSButton(title: "重试", target: nil, action: nil)
    private let text = NSTextView()
    private var settingsUpdated = false
    private lazy var workflow = TranslationWorkflow(recognize: recognize, translate: { [weak self] text, settings in
        guard let self else { throw CancellationError() }
        if let translator = self.translator { return try await translator(text, settings) }
        if settings.provider == .system { return try await self.system.translate(text, to: settings.target) }
        guard let key = try self.store.key(for: settings.provider), !key.isEmpty else { throw TranslationFailure.missingKey }
        return try await self.cloud.translate(text, settings: settings, key: key)
    })

    init(store: TranslationSettingsStore,
         recognize: @escaping (Raster) async throws -> String = { try await TextRecognizer.recognize($0) },
         translate: ((String, TranslationSettings) async throws -> String)? = nil,
         pasteboard: NSPasteboard = .general) {
        self.store = store
        self.recognize = recognize; translator = translate; board = pasteboard
        super.init(contentRect: CGRect(x: 0, y: 0, width: 560, height: 470),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        title = "截图翻译"; isReleasedWhenClosed = false; delegate = self
        minSize = CGSize(width: 480, height: 340)
        level = .floating; hidesOnDeactivate = false; isMovableByWindowBackground = true
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let effect = FrostedSurface()
        contentView = effect
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -18)
        ])
        service.font = .systemFont(ofSize: 12, weight: .medium); service.textColor = .screenClipSecondaryLabel
        let settings = NSButton(title: "翻译设置…", target: self, action: #selector(openSettings))
        settings.isBordered = false; settings.font = .systemFont(ofSize: 12); settings.contentTintColor = .screenClipSecondaryLabel
        let top = NSStackView(views: [service, NSView(), settings]); top.alignment = .centerY
        root.addArrangedSubview(top)
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(switchTab)
        tabs.setAccessibilityLabel("译文或原文")
        copy.target = self; copy.action = #selector(copyText); copy.bezelStyle = .rounded
        copy.contentTintColor = .screenClipAccent
        copyOriginal.target = self; copyOriginal.action = #selector(copyOriginalText); copyOriginal.bezelStyle = .rounded
        let actions = NSStackView(views: [tabs, NSView(), copyOriginal, copy]); actions.alignment = .centerY
        root.addArrangedSubview(actions)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12; scroll.layer?.masksToBounds = true
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.drawsBackground = false; text.font = .systemFont(ofSize: 15); text.textColor = .labelColor
        text.textContainerInset = CGSize(width: 14, height: 12)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("翻译内容")
        scroll.documentView = text
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        root.addArrangedSubview(scroll)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        status.font = .systemFont(ofSize: 12); status.textColor = .screenClipSecondaryLabel
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retry.target = self; retry.action = #selector(retryTranslation); retry.bezelStyle = .rounded
        let footer = NSStackView(views: [spinner, status, NSView(), retry]); footer.alignment = .centerY; footer.spacing = 8
        root.addArrangedSubview(footer)
        for view in [top, actions, scroll, footer] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        system.view.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(system.view)
        NSLayoutConstraint.activate([
            system.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor), system.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            system.view.widthAnchor.constraint(equalToConstant: 1), system.view.heightAnchor.constraint(equalToConstant: 1)
        ])
        workflow.onChange = { [weak self] in self?.refresh() }
        system.onPreparationChanged = { [weak self] in self?.workflow.preparingLanguage($0) }
        refresh(); center()
    }

    func begin(_ image: Raster, present: Bool = true) {
        settingsUpdated = false; tabs.selectedSegment = 0
        system.cancel(); workflow.begin(image, settings: store.settings)
        if present { NSApp.activate(ignoringOtherApps: true); makeKeyAndOrderFront(nil) }
    }
    func settingsChanged() {
        settingsUpdated = workflow.settings != store.settings
        if !workflow.phase.isBusy, !workflow.original.isEmpty { refresh() }
    }
    private func refresh() {
        let original = tabs.selectedSegment == 1
        service.stringValue = workflow.settings.provider.title + " → " + workflow.settings.target.title
        let value = original ? workflow.original : workflow.translated
        if text.string != value {
            let selection = text.selectedRange()
            text.string = value
            text.setSelectedRange(NSRange(location: min(selection.location, (value as NSString).length), length: 0))
        }
        text.textColor = .labelColor
        copyOriginal.isEnabled = !workflow.original.isEmpty
        copy.isEnabled = !workflow.translated.isEmpty && workflow.phase == .finished
        status.textColor = .screenClipSecondaryLabel
        retry.isHidden = true
        if workflow.phase.isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        switch workflow.phase {
        case .idle: status.stringValue = ""
        case .recognizing: status.stringValue = "正在识别文字…"
        case .preparingLanguage: status.stringValue = "正在准备语言…"
        case .translating(let index, let total):
            status.stringValue = total == 1 ? "正在翻译…" : "正在翻译 \(index)/\(total)…"
        case .finished: status.stringValue = "已完成"
        case .failed(let message):
            status.stringValue = message; status.textColor = .systemRed
            retry.title = workflow.original.isEmpty ? "重新截图" : "重试"; retry.isHidden = false
        }
        if settingsUpdated, !workflow.phase.isBusy, !workflow.original.isEmpty {
            status.stringValue = "设置已更新"; status.textColor = .screenClipSecondaryLabel
            retry.title = "重新翻译"; retry.isHidden = false
        }
    }
    @objc private func switchTab() { refresh() }
    @objc private func copyText() { copyValue(workflow.translated, enabled: copy.isEnabled, message: "已复制译文") }
    @objc private func copyOriginalText() { copyValue(workflow.original, enabled: copyOriginal.isEnabled, message: "已复制原文") }
    private func copyValue(_ value: String, enabled: Bool, message: String) {
        guard !value.isEmpty, enabled else { return }
        board.clearContents()
        if board.setString(value, forType: .string) { status.stringValue = message }
        else { status.stringValue = "复制失败，请重试。" }
    }
    @objc private func retryTranslation() {
        if workflow.original.isEmpty { onRecapture?(); return }
        if settingsUpdated || workflow.settings != store.settings {
            settingsUpdated = false; workflow.retranslate(settings: store.settings)
        } else { workflow.retry() }
    }
    @objc private func openSettings() { onSettings?() }
    func windowWillClose(_ notification: Notification) { system.cancel(); workflow.clear(); text.string = "" }
    override func cancelOperation(_ sender: Any?) { close() }
}
