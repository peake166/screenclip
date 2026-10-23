import AppKit

@MainActor final class TranslationOverlayController {
    var onSettings: (() -> Void)?
    var onRecapture: (() -> Void)?
    var onClose: (() -> Void)?
    private let store: TranslationSettingsStore
    private let system = SystemTranslation()
    private let cloud = CloudTranslation()
    private let recognize: (Raster) async throws -> OCRDocument
    private let translator: ((String, TranslationSettings) async throws -> String)?
    private let board: NSPasteboard
    private var source: Raster?
    private var settingsUpdated = false
    private var original = false
    private(set) var panel: NSPanel?
    private(set) var toolbar: OverlayToolbar?
    private(set) var canvas: TranslationCanvas?
    private(set) var focusBackdrops: [TranslationFocusBackdrop] = []
    var phase: TranslationWorkflow.Phase { workflow.phase }
    private lazy var workflow = TranslationWorkflow(recognizeLayout: recognize, translate: { [weak self] text, settings in
        guard let self else { throw CancellationError() }
        if let translator = self.translator { return try await translator(text, settings) }
        if settings.provider == .system { return try await self.system.translate(text, to: settings.target) }
        guard let key = try self.store.key(for: settings.provider), !key.isEmpty else { throw TranslationFailure.missingKey }
        return try await self.cloud.translate(text, settings: settings, key: key)
    }, translateBatch: { [weak self] texts, settings in
        guard let self else { throw CancellationError() }
        if let translator = self.translator {
            var values: [String] = []
            for text in texts { values.append(try await translator(text, settings)) }
            return values
        }
        return try await self.system.translateBatch(texts, to: settings.target)
    })

    init(store: TranslationSettingsStore,
         recognize: @escaping (Raster) async throws -> OCRDocument = { try await TextRecognizer.recognizeDocument($0) },
         translate: ((String, TranslationSettings) async throws -> String)? = nil,
         pasteboard: NSPasteboard = .general) {
        self.store = store; self.recognize = recognize; translator = translate; board = pasteboard
        workflow.onChange = { [weak self] in self?.refresh() }
        system.onPreparationChanged = { [weak self] in self?.workflow.preparingLanguage($0) }
    }

    func begin(_ image: Raster, region: CaptureRegion, present: Bool = true) {
        close()
        source = image; original = false; settingsUpdated = false
        let canvas = TranslationCanvas(image: image, size: region.rect.size)
        self.canvas = canvas
        let panel = OverlayPanel(contentRect: region.rect, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "原位截图翻译"; panel.contentView = canvas
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        focusBackdrops = NSScreen.screens.map { TranslationFocusBackdrop(screen: $0, selection: region.rect) }
        let toolbar = OverlayToolbar()
        toolbar.onOriginal = { [weak self] in
            guard let self else { return }; self.original.toggle(); self.refresh()
        }
        toolbar.onCopy = { [weak self] in self?.copyText() }
        toolbar.onRetry = { [weak self] in self?.retry() }
        toolbar.onSettings = { [weak self] in self?.onSettings?() }
        toolbar.onCancel = { [weak self] in self?.close() }
        self.toolbar = toolbar
        toolbar.contentView!.addSubview(system.view)
        system.view.frame = CGRect(x: 4, y: 4, width: 1, height: 1)
        let visible = region.screen.visibleFrame
        let width = min(540, visible.width - 16)
        let x = min(visible.maxX - width - 8, max(visible.minX + 8, region.rect.midX - width / 2))
        let below = region.rect.minY - toolbar.frame.height - 8
        let above = region.rect.maxY + 8
        let y = below >= visible.minY + 8 ? below : min(visible.maxY - toolbar.frame.height - 8, max(visible.minY + 8, above))
        toolbar.setFrame(CGRect(x: x, y: y, width: width, height: 64), display: true)
        if present {
            NSApp.activate(ignoringOtherApps: true)
            focusBackdrops.forEach { $0.orderFrontRegardless() }
            panel.orderFrontRegardless(); toolbar.makeKeyAndOrderFront(nil)
        }
        workflow.begin(image, settings: store.settings)
    }

    func settingsChanged() {
        settingsUpdated = workflow.settings != store.settings
        refresh()
    }

    func close() {
        let existed = panel != nil
        canvas?.dismissExpanded()
        focusBackdrops.forEach { $0.orderOut(nil); $0.close() }
        focusBackdrops = []
        panel?.orderOut(nil); toolbar?.orderOut(nil)
        panel?.close(); toolbar?.close()
        panel = nil; toolbar = nil; canvas = nil; source = nil
        system.cancel(); workflow.clear()
        if existed { onClose?() }
    }

    private func refresh() {
        guard let toolbar, let canvas else { return }
        if let document = workflow.document {
            canvas.update(document: document, translations: workflow.translatedBlocks, original: original)
        }
        toolbar.originalButton.isEnabled = !workflow.original.isEmpty
        toolbar.originalButton.state = original ? .on : .off
        toolbar.originalButton.title = original ? "显示译文" : "查看原文"
        toolbar.copyButton.title = original ? "复制原文" : "复制译文"
        toolbar.copyButton.isEnabled = original ? !workflow.original.isEmpty : workflow.phase == .finished
        toolbar.retryButton.isHidden = true
        toolbar.status.textColor = .secondaryLabelColor
        if workflow.phase.isBusy { toolbar.spinner.startAnimation(nil) } else { toolbar.spinner.stopAnimation(nil) }
        switch workflow.phase {
        case .idle: toolbar.status.stringValue = ""
        case .recognizing: toolbar.status.stringValue = "正在识别…"
        case .preparingLanguage: toolbar.status.stringValue = "正在准备语言…"
        case .translating(let index, let total):
            toolbar.status.stringValue = total == 1 ? "正在翻译…" : "正在翻译 \(index)/\(total)…"
        case .finished:
            toolbar.status.stringValue = canvas.overflowCount > 0
                ? "\(canvas.overflowCount) 处较长，点按译文展开" : workflow.settings.provider.title + " · 已完成"
        case .failed(let message):
            toolbar.status.stringValue = message; toolbar.status.textColor = .systemRed
            toolbar.retryButton.title = workflow.original.isEmpty ? "重选" : "重试"
            toolbar.retryButton.isHidden = false
        }
        if settingsUpdated, !workflow.phase.isBusy, !workflow.original.isEmpty {
            toolbar.status.stringValue = "设置已更新"; toolbar.status.textColor = .secondaryLabelColor
            toolbar.retryButton.title = "重译"; toolbar.retryButton.isHidden = false
        }
    }

    private func copyText() {
        guard toolbar?.copyButton.isEnabled == true else { return }
        let text = original ? workflow.original : workflow.translated
        board.clearContents()
        toolbar?.status.stringValue = board.setString(text, forType: .string) ? "已复制" : "复制失败，请重试。"
    }

    private func retry() {
        if workflow.original.isEmpty { onRecapture?(); return }
        if settingsUpdated || workflow.settings != store.settings {
            settingsUpdated = false; workflow.retranslate(settings: store.settings)
        } else { workflow.retry() }
    }
}

@MainActor class OverlayPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        isOpaque = false; backgroundColor = .clear; hasShadow = false; level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor final class OverlayToolbar: OverlayPanel {
    let status = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let originalButton = NSButton(title: "查看原文", target: nil, action: nil)
    let copyButton = NSButton(title: "复制译文", target: nil, action: nil)
    let retryButton = NSButton(title: "重试", target: nil, action: nil)
    var onOriginal: (() -> Void)?, onCopy: (() -> Void)?, onRetry: (() -> Void)?, onSettings: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 540, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
        title = "翻译工具栏"; hasShadow = true
        let effect = NSVisualEffectView(); effect.material = .hudWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.masksToBounds = true
        contentView = effect
        let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fill
        row.spacing = 7; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "翻译设置")!, target: self, action: #selector(settingsAction))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭原位翻译")!, target: self, action: #selector(closeAction))
        settings.toolTip = "翻译设置"; close.toolTip = "关闭（Esc）"
        originalButton.setButtonType(.toggle)
        for button in [originalButton, copyButton, retryButton, settings, close] {
            button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 12)
        }
        originalButton.target = self; originalButton.action = #selector(originalAction)
        copyButton.target = self; copyButton.action = #selector(copyAction)
        retryButton.target = self; retryButton.action = #selector(retryAction)
        for view in [spinner, status, retryButton, originalButton, copyButton, settings, close] { row.addArrangedSubview(view) }
    }
    @objc private func originalAction() { onOriginal?() }
    @objc private func copyAction() { onCopy?() }
    @objc private func retryAction() { onRetry?() }
    @objc private func settingsAction() { onSettings?() }
    @objc private func closeAction() { onCancel?() }
}

@MainActor final class TranslationCanvas: NSView {
    override var isFlipped: Bool { true }
    private let image: Raster
    private var replacements: [NSView] = []
    private var lastDocument: OCRDocument?
    private var lastTranslations: [Int: String] = [:]
    private var popover: NSPopover?
    private(set) var overflowCount = 0

    init(image: Raster, size: CGSize) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: size))
        let background = NSImageView(frame: bounds)
        if let cg = try? image.cgImage() { background.image = NSImage(cgImage: cg, size: size) }
        background.imageScaling = .scaleAxesIndependently
        addSubview(background)
        setAccessibilityLabel("原位截图翻译")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func dismissExpanded() { popover?.close(); popover = nil }

    func update(document: OCRDocument, translations: [Int: String], original: Bool) {
        if document != lastDocument || translations != lastTranslations {
            popover?.close(); replacements.forEach { $0.removeFromSuperview() }; replacements = []
            lastDocument = document; lastTranslations = translations
            let placements = TranslationOverlayLayout.placements(document: document, translations: translations, image: image, size: bounds.size)
            overflowCount = placements.filter(\.overflow).count
            // Paint every source mask before text, so adjacent translated text is never erased by a later mask.
            for placement in placements {
                for rect in placement.covers {
                    let cover = NSView(frame: rect); cover.wantsLayer = true; cover.layer?.backgroundColor = placement.background.cgColor
                    addSubview(cover); replacements.append(cover)
                }
            }
            for placement in placements {
                let label = OverlayTextField(wrappingLabelWithString: placement.text)
                label.font = .systemFont(ofSize: placement.fontSize); label.textColor = placement.foreground
                label.drawsBackground = true; label.backgroundColor = placement.background
                label.frame = placement.frame; label.maximumNumberOfLines = 0
                if placement.overflow {
                    label.lineBreakMode = .byWordWrapping
                    label.cell?.truncatesLastVisibleLine = true
                    label.maximumNumberOfLines = max(1, Int(placement.frame.height / (placement.fontSize * 1.2)))
                    label.toolTip = "点按查看完整译文"
                    label.setAccessibilityRole(.button)
                    label.setAccessibilityLabel("展开完整译文：" + placement.text)
                    label.onExpand = { [weak self, weak label] in
                        guard let label else { return }; self?.expand(placement.text, from: label)
                    }
                }
                addSubview(label); replacements.append(label)
            }
        }
        replacements.forEach { $0.isHidden = original }
        if original { popover?.close() }
    }

    private func expand(_ text: String, from view: NSView) {
        popover?.close()
        let controller = NSViewController()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 380, height: 260))
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.font = .systemFont(ofSize: 14); textView.string = text
        textView.textContainerInset = CGSize(width: 12, height: 12)
        textView.isVerticallyResizable = true; textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView; controller.view = scroll
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        popover.contentSize = scroll.frame.size; self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
}

@MainActor private final class OverlayTextField: NSTextField {
    var onExpand: (() -> Void)?
    override var acceptsFirstResponder: Bool { onExpand != nil }
    override func mouseDown(with event: NSEvent) { onExpand?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onExpand?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { guard let onExpand else { return false }; onExpand(); return true }
}
