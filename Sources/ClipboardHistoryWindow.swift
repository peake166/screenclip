import AppKit
import OSLog

// Content fills an assigned viewport; its natural width must not size the panel.
private final class ClipboardContentLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
}

private final class ClipboardPreviewImage: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private final class ClipboardRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 9, yRadius: 9)
        ScreenClipTone.blue.softBackground.setFill()
        pill.fill()
        ScreenClipTone.blue.foreground.withAlphaComponent(0.28).setStroke()
        pill.lineWidth = 0.75
        pill.stroke()
    }
}

@MainActor
private final class ClipboardItemIconView: NSView {
    var thumbnail: NSImage? { didSet { needsDisplay = true } }
    var isImageEntry = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if isImageEntry, let thumbnail {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.screenClipCardFill.setFill(); bounds.fill()
            let imgSize = thumbnail.size
            if imgSize.width > 0, imgSize.height > 0 {
                let scale = max(bounds.width / imgSize.width, bounds.height / imgSize.height)
                let drawSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
                let drawRect = CGRect(
                    x: (bounds.width - drawSize.width) / 2,
                    y: (bounds.height - drawSize.height) / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
                thumbnail.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.screenClipCardBorder.setStroke()
            shape.lineWidth = 0.8; shape.stroke()
        } else {
            let tone: ScreenClipTone = isImageEntry ? .amber : .blue
            tone.softBackground.setFill(); shape.fill()
            ScreenClipDrawing.drawSymbol(
                isImageEntry ? "photo" : "doc.text",
                pointSize: 13.5,
                weight: .semibold,
                color: tone.foreground,
                centeredIn: bounds
            )
        }
    }
}

private final class ClipboardCell: NSTableCellView {
    let iconBadge = ClipboardItemIconView()
    let name = ClipboardContentLabel(labelWithString: "")
    let meta = ClipboardContentLabel(labelWithString: "")
    let pinned = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "已置顶")!)
    var entryID: UUID?
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingTail
        meta.font = .systemFont(ofSize: 11); meta.textColor = .screenClipSecondaryLabel; meta.lineBreakMode = .byTruncatingTail
        for label in [name, meta] { label.maximumNumberOfLines = 1; label.usesSingleLineMode = true }
        pinned.contentTintColor = ScreenClipTone.amber.foreground
        let labels = NSStackView(views: [name, meta]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        for view in [iconBadge, labels, pinned] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            iconBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13), iconBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 32), iconBadge.heightAnchor.constraint(equalToConstant: 32),
            labels.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 10), labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: pinned.leadingAnchor, constant: -8),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor), meta.widthAnchor.constraint(equalTo: labels.widthAnchor),
            pinned.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13), pinned.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinned.widthAnchor.constraint(equalToConstant: 11), pinned.heightAnchor.constraint(equalToConstant: 13)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
private final class ClipboardBrandBadge: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        ScreenClipTone.blue.softBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        ScreenClipDrawing.drawSymbol("doc.on.clipboard", pointSize: 11.5, weight: .semibold, color: ScreenClipTone.blue.foreground, centeredIn: bounds)
    }
}

private final class ClipboardListTable: NSTableView {
    var onActivate: (() -> Void)?, onCopy: (() -> Void)?, onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) { onCopy?() } else { onActivate?() }; return
        }
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}

private final class CachedClipboardPreview: NSObject {
    let value: ClipboardHistoryPreview
    init(_ value: ClipboardHistoryPreview) { self.value = value }
}

@MainActor
final class ClipboardHistoryWindow: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    typealias PreviewLoader = (UUID, Int, @escaping (ClipboardHistoryPreview?) -> Void) -> Void
    private enum Row { case group(String), entry(ClipboardHistoryEntry) }
    private let history: ClipboardHistory
    private let loadPreview: PreviewLoader
    private let previewIdleDelay: TimeInterval
    private let search = NSSearchField()
    private let table = ClipboardListTable()
    private let record = PillActionButton(title: "已暂停", symbolName: "play.fill", style: .tinted(.amber))
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private let previewTitle = ClipboardContentLabel(labelWithString: "")
    private let previewSource = ClipboardContentLabel(labelWithString: "")
    private let expiry = NSTextField(labelWithString: "")
    private let textScroll = NSScrollView()
    private let image = ClipboardPreviewImage()
    private let primary = PillActionButton(title: "粘贴", style: .primary(.blue))
    private let actions = PillActionButton(title: "操作  ⌘K", style: .subtle)
    private let hint = KeycapHintView(key: "⌘↵", label: "仅复制")
    private let filters = PillSegmentedControl(titles: ["全部", "文字", "图片", "置顶"])
    private let countBadge = TagPillView(text: "", tone: .slate)
    private let formatTag = TagPillView(text: "", tone: .slate)
    private let pinToScreen = PillActionButton(title: "贴到屏幕", symbolName: "pin", style: .tinted(.amber))
    private let pinPreview = PillActionButton(symbolName: "pin", style: .iconCircle)
    private var rows: [Row] = []
    private var settingsWindow: ClipboardHistorySettingsWindow?
    private var searchWork: Task<[ClipboardHistoryEntry], Never>?
    private var searchUpdate: Task<Void, Never>?
    private var previewToken = UUID(), sessionToken = UUID()
    private let previewCache = NSCache<NSUUID, CachedClipboardPreview>()
    private let thumbnailCache = NSCache<NSUUID, NSImage>()
    private var imagePreviewIDs: Set<UUID> = []
    private var previewCacheEpoch = UUID()
    private var idlePreviewRelease: DispatchWorkItem?
    private var idlePreviewToken = UUID()
    private var previewID: UUID?
    private var targetName: String?
    private var busy = false, hidingForAction = false
    private var selectingLatestOnOpen = false, applyingRows = false
    private var pendingAction: (ClipboardPrimaryAction, Bool)?
    var onAction: ((ClipboardPrimaryAction) -> Void)?
    var onPinImageData: ((Data) -> Void)?
    var onDismiss: (() -> Void)?

    init(history: ClipboardHistory, previewIdleDelay: TimeInterval = 60, previewLoader: PreviewLoader? = nil) {
        self.history = history
        self.previewIdleDelay = previewIdleDelay
        loadPreview = previewLoader ?? { id, size, completion in history.loadPreview(id, maximumPixelSize: size, completion: completion) }
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable], backing: .buffered, defer: false)
        title = "剪贴板"; titleVisibility = .hidden; titlebarAppearsTransparent = true; isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        delegate = self; isFloatingPanel = true; level = .floating; hidesOnDeactivate = false
        animationBehavior = .none; isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        minSize = NSSize(width: 600, height: 400); maxSize = NSSize(width: 700, height: 480)
        previewCache.totalCostLimit = 32 * 1024 * 1024; previewCache.countLimit = 80
        thumbnailCache.totalCostLimit = 4 * 1024 * 1024; thumbnailCache.countLimit = 150
        let root = FrostedSurface(); contentView = root
        // NSWindow.maxSize only limits manual resizing; Auto Layout also needs bounds.
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: minSize.width),
            root.widthAnchor.constraint(lessThanOrEqualToConstant: maxSize.width),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: minSize.height),
            root.heightAnchor.constraint(lessThanOrEqualToConstant: maxSize.height)
        ])
        let brandBadge = ClipboardBrandBadge()
        let brand = NSTextField(labelWithString: "剪贴板历史")
        brand.font = .systemFont(ofSize: 13.5, weight: .semibold); brand.textColor = .labelColor
        record.target = self; record.action = #selector(toggleRecording)
        record.fixedHeight = 24; record.horizontalPadding = 9; record.font = .systemFont(ofSize: 11, weight: .medium)
        record.setAccessibilityLabel("暂停或开启剪贴板记录")
        let settings = PillActionButton(symbolName: "slider.horizontal.3", style: .iconCircle, target: self, action: #selector(openSettings))
        settings.fixedHeight = 24; settings.setAccessibilityLabel("剪贴板设置"); settings.toolTip = "剪贴板设置"
        let titlebar = NSStackView(views: [brandBadge, brand, countBadge, NSView(), record, settings])
        titlebar.spacing = 8; titlebar.alignment = .centerY

        // Borderless search field nestled inside a soft glass InsetCardView.
        let searchCard = InsetCardView(radius: 11)
        searchCard.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "搜索复制过的文字、链接或来源应用…"; search.delegate = self
        search.setAccessibilityLabel("搜索剪贴板历史"); search.sendsSearchStringImmediately = true
        search.font = .systemFont(ofSize: 14); search.isBordered = false; search.drawsBackground = false
        search.focusRingType = .none; search.translatesAutoresizingMaskIntoConstraints = false
        searchCard.addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: searchCard.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: searchCard.trailingAnchor, constant: -10),
            search.centerYAnchor.constraint(equalTo: searchCard.centerYAnchor)
        ])

        filters.selectedSegment = 0
        filters.target = self; filters.action = #selector(changeFilter); filters.setAccessibilityLabel("剪贴板内容类型")

        let list = NSScrollView(); list.hasVerticalScroller = true; list.autohidesScrollers = true
        list.drawsBackground = true; list.backgroundColor = .textBackgroundColor
        list.wantsLayer = true; list.layer?.cornerRadius = 12; list.layer?.masksToBounds = true
        list.layer?.borderWidth = 0.7; list.layer?.borderColor = NSColor.screenClipCardBorder.cgColor
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain; table.backgroundColor = .textBackgroundColor; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(defaultAction)
        table.onActivate = { [weak self] in self?.defaultAction() }
        table.onCopy = { [weak self] in self?.copyOnly() }
        table.onCancel = { [weak self] in self?.cancelOperation(nil) }
        table.setAccessibilityLabel("剪贴板历史列表"); list.documentView = table
        list.contentView.drawsBackground = true; list.contentView.backgroundColor = .textBackgroundColor
        let detail = ReadableSurface(); detail.usesOpaqueBackground = true
        previewTitle.font = .systemFont(ofSize: 15, weight: .semibold); previewTitle.lineBreakMode = .byTruncatingTail
        previewSource.font = .systemFont(ofSize: 11.5, weight: .medium); previewSource.textColor = .screenClipSecondaryLabel; previewSource.lineBreakMode = .byTruncatingTail
        for label in [previewTitle, previewSource] { label.maximumNumberOfLines = 1; label.usesSingleLineMode = true }
        pinToScreen.fixedHeight = 22; pinToScreen.horizontalPadding = 8; pinToScreen.font = .systemFont(ofSize: 11, weight: .medium)
        pinToScreen.target = self; pinToScreen.action = #selector(pinSelectedToScreen)
        pinToScreen.setAccessibilityLabel("贴到屏幕")
        pinToScreen.toolTip = "将图片固定在屏幕上  ⌥⌘P"
        pinToScreen.isHidden = true
        pinPreview.fixedHeight = 24; pinPreview.showsToggleState = true
        pinPreview.target = self; pinPreview.action = #selector(pinSelected)
        pinPreview.setAccessibilityLabel("置顶或取消置顶")
        pinPreview.toolTip = "置顶或取消置顶  ⇧⌘P"
        let detailHeader = NSStackView(views: [previewSource, pinToScreen, pinPreview]); detailHeader.alignment = .centerY; detailHeader.spacing = 6
        let detailTopDivider = HairlineDivider(vertical: false)
        let detailBottomDivider = HairlineDivider(vertical: false)
        preview.isEditable = false; preview.isSelectable = true; preview.drawsBackground = false
        preview.font = .systemFont(ofSize: 13); preview.textColor = .labelColor
        preview.textContainerInset = NSSize(width: 0, height: 6)
        preview.isVerticallyResizable = true; preview.isHorizontallyResizable = false
        preview.autoresizingMask = .width; preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("剪贴板内容预览")
        textScroll.hasVerticalScroller = true; textScroll.drawsBackground = false; textScroll.documentView = preview
        image.imageScaling = .scaleProportionallyUpOrDown; image.setAccessibilityLabel("剪贴板图片预览")
        image.wantsLayer = true; image.layer?.cornerRadius = 8; image.layer?.masksToBounds = true
        image.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        image.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let previewBody = NSView()
        for view in [textScroll, image] { pin(view, in: previewBody) }
        expiry.font = .systemFont(ofSize: 11); expiry.textColor = .screenClipSecondaryLabel
        expiry.setContentCompressionResistancePriority(.required, for: .horizontal)
        let detailFooter = NSStackView(views: [formatTag, NSView(), expiry]); detailFooter.alignment = .centerY
        for view in [detailHeader, detailTopDivider, previewTitle, previewBody, detailBottomDivider, detailFooter] {
            view.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(view)
            let pad: CGFloat = (view === detailTopDivider || view === detailBottomDivider) ? 0 : 16
            view.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: pad).isActive = true
            view.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -pad).isActive = true
        }
        NSLayoutConstraint.activate([
            detailHeader.topAnchor.constraint(equalTo: detail.topAnchor, constant: 10), detailHeader.heightAnchor.constraint(equalToConstant: 24),
            detailTopDivider.topAnchor.constraint(equalTo: detailHeader.bottomAnchor, constant: 8),
            previewTitle.topAnchor.constraint(equalTo: detailTopDivider.bottomAnchor, constant: 10), previewTitle.heightAnchor.constraint(equalToConstant: 22),
            previewBody.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 6), previewBody.bottomAnchor.constraint(equalTo: detailBottomDivider.topAnchor, constant: -8),
            detailBottomDivider.bottomAnchor.constraint(equalTo: detailFooter.topAnchor, constant: -8),
            detailFooter.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -10), detailFooter.heightAnchor.constraint(equalToConstant: 22)
        ])
        let split = NSStackView(views: [list, detail]); split.spacing = 10; split.distribution = .fill
        list.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        detail.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        list.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.48).isActive = true
        detail.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.52, constant: -10).isActive = true
        empty.font = .systemFont(ofSize: 13); empty.textColor = .screenClipSecondaryLabel; empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(empty); empty.setAccessibilityLabel("剪贴板空状态")
        status.font = .systemFont(ofSize: 11); status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.target = self; actions.action = #selector(openActions)
        actions.fixedHeight = 26; actions.horizontalPadding = 9; actions.font = .systemFont(ofSize: 11.5, weight: .medium)
        primary.target = self; primary.action = #selector(defaultAction)
        primary.fixedHeight = 28; primary.horizontalPadding = 12
        primary.keyEquivalent = "\r"; primary.keyEquivalentModifierMask = []
        primary.setAccessibilityLabel("使用选中的剪贴板内容")
        let footer = NSStackView(views: [actions, status, NSView(), hint, primary]); footer.spacing = 10; footer.alignment = .centerY
        for view in [titlebar, searchCard, filters, split, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16).isActive = true
            if view != filters { view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16).isActive = true }
        }
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), titlebar.heightAnchor.constraint(equalToConstant: 26),
            searchCard.topAnchor.constraint(equalTo: titlebar.bottomAnchor, constant: 9), searchCard.heightAnchor.constraint(equalToConstant: 34),
            filters.topAnchor.constraint(equalTo: searchCard.bottomAnchor, constant: 9), filters.heightAnchor.constraint(equalToConstant: 28),
            split.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 10), split.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -11), footer.heightAnchor.constraint(equalToConstant: 28),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor), empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            empty.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -30)
        ])
        history.onChange = { [weak self] in if self?.isVisible == true { self?.refresh() } }
        center(); refresh()
    }
    deinit { idlePreviewRelease?.cancel() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        schedulePreviewRelease()
    }
    private func schedulePreviewRelease() {
        guard idlePreviewRelease == nil else { return }
        let delay = previewIdleDelay
        let token = UUID(); idlePreviewToken = token
        let release = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
            guard let self, self.idlePreviewToken == token else { return }
            self.idlePreviewRelease = nil
            guard !self.isVisible else { return }
            // Invalidate decoders that were queued before this reclamation.
            let hadImages = !self.imagePreviewIDs.isEmpty || self.image.image != nil
            self.previewCacheEpoch = UUID(); self.previewToken = UUID(); self.previewID = nil
            for id in self.imagePreviewIDs { self.previewCache.removeObject(forKey: id as NSUUID) }
            self.imagePreviewIDs.removeAll()
            self.image.image = nil; self.image.isHidden = true; self.textScroll.isHidden = false
            if hadImages {
                Logger(subsystem: "com.local.screenclip", category: "Clipboard").notice("Idle clipboard image previews released")
            }
            }
        }
        idlePreviewRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: release)
    }
    private func pin(_ view: NSView, in parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    func present(targetName: String? = nil) {
        idlePreviewToken = UUID()
        idlePreviewRelease?.cancel(); idlePreviewRelease = nil
        self.targetName = targetName; sessionToken = UUID(); busy = false; hidingForAction = false
        pendingAction = nil; selectingLatestOnOpen = true
        // Capture before focusing the picker so a just-copied item keeps its source application.
        history.poll()
        // A payload is immutable: keep a warm or pending preview when the same item is reopened.
        search.stringValue = ""; filters.selectedSegment = 0; refresh()
        orderFrontRegardless(); makeKey(); makeFirstResponder(search)
    }
    func refresh() {
        let entries = history.entries, revealLatest = selectingLatestOnOpen
        let selected = revealLatest ? entries.max(by: { $0.copiedAt < $1.copiedAt })?.id : selectedEntry?.id
        if revealLatest && history.pendingOperations == 0 { selectingLatestOnOpen = false }
        countBadge.text = entries.isEmpty ? "" : "\(entries.count) 条"
        countBadge.isHidden = entries.isEmpty
        record.title = history.settings.isRecording ? "正在记录" : "已暂停"
        record.symbolName = history.settings.isRecording ? "pause.fill" : "play.fill"
        record.pillStyle = history.settings.isRecording ? .tinted(.green) : .tinted(.amber)
        record.toolTip = history.settings.isRecording ? "暂停记录" : "开启记录"
        status.stringValue = history.errorMessage ?? ""; status.toolTip = history.errorMessage
        status.textColor = history.errorMessage == nil ? .screenClipSecondaryLabel : .systemRed
        hint.isHidden = history.errorMessage != nil
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = filters.selectedSegment
        searchWork?.cancel(); searchUpdate?.cancel(); searchWork = nil; searchUpdate = nil
        if query.isEmpty {
            apply(entries.filter { Self.includes($0, filter: filter) }, selected: selected, reveal: revealLatest)
            resumePendingAction(); return
        }
        let work = Task.detached(priority: .userInitiated) { () -> [ClipboardHistoryEntry] in
            var result: [ClipboardHistoryEntry] = []
            for entry in entries {
                if Task.isCancelled { return [] }
                if Self.includes(entry, filter: filter), entry.text.localizedStandardContains(query) || entry.applicationName.localizedStandardContains(query) { result.append(entry) }
            }
            return result
        }
        searchWork = work
        searchUpdate = Task { [weak self] in
            let values = await work.value
            guard !Task.isCancelled, !work.isCancelled, let self else { return }
            self.apply(values, selected: selected, reveal: true)
            self.searchUpdate = nil
            self.resumePendingAction()
        }
    }
    nonisolated private static func includes(_ entry: ClipboardHistoryEntry, filter: Int) -> Bool {
        switch filter { case 1: return !entry.hasImage; case 2: return entry.hasImage; case 3: return entry.pinned; default: return true }
    }
    private func apply(_ entries: [ClipboardHistoryEntry], selected: UUID?, reveal: Bool) {
        applyingRows = true; defer { applyingRows = false }
        rows = []; var currentGroup = ""
        for entry in entries {
            let group = entry.pinned ? "置顶" : Calendar.current.isDateInToday(entry.copiedAt) ? "今天" : Calendar.current.isDateInYesterday(entry.copiedAt) ? "昨天" : "更早"
            if group != currentGroup { rows.append(.group(group)); currentGroup = group }
            rows.append(.entry(entry))
        }
        table.reloadData()
        let index = rows.firstIndex { row in if case .entry(let entry) = row { return entry.id == selected }; return false }
            ?? rows.firstIndex { if case .entry = $0 { return true }; return false }
        if let index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if reveal { table.scrollRowToVisible(index) }
        }
        empty.isHidden = !entries.isEmpty
        empty.stringValue = !search.stringValue.isEmpty || filters.selectedSegment != 0 ? "没有匹配的内容"
            : history.settings.isRecording ? "还没有历史\n复制文字或图片后会出现在这里" : "记录已暂停\n点击右上角开启记录"
        updatePreview()
    }
    func waitForSearch() async { await searchUpdate?.value }
    private var selectedEntry: ClipboardHistoryEntry? {
        guard rows.indices.contains(table.selectedRow), case .entry(let entry) = rows[table.selectedRow] else { return nil }; return entry
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .group = rows[row] { return 25 }; return 60 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .entry = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClipboardRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = title == "置顶" ? ScreenClipTone.amber.foreground : .screenClipSecondaryLabel
            let view = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return view
        case .entry(let entry):
            let id = NSUserInterfaceItemIdentifier("clipboard-entry")
            let cell = (table.makeView(withIdentifier: id, owner: self) as? ClipboardCell) ?? ClipboardCell(frame: .zero)
            cell.identifier = id; cell.entryID = entry.id; cell.name.stringValue = entry.title; cell.pinned.isHidden = !entry.pinned
            let relative = RelativeDateTimeFormatter(); relative.unitsStyle = .short
            let now = Date()
            let age = abs(now.timeIntervalSince(entry.copiedAt)) < 60 ? "刚刚" : relative.localizedString(for: entry.copiedAt, relativeTo: now)
            cell.meta.stringValue = entry.applicationName + " · " + age
            cell.iconBadge.isImageEntry = entry.hasImage
            cell.iconBadge.thumbnail = nil
            if entry.hasImage {
                if let image = thumbnailCache.object(forKey: entry.id as NSUUID) { cell.iconBadge.thumbnail = image }
                else { loadPreview(entry.id, 80) { [weak self, weak cell] preview in
                    guard let cg = preview?.image else { return }; let image = NSImage(cgImage: cg, size: .zero)
                    self?.thumbnailCache.setObject(image, forKey: entry.id as NSUUID, cost: cg.bytesPerRow * cg.height)
                    if cell?.entryID == entry.id { cell?.iconBadge.thumbnail = image }
                } }
            }
            return cell
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !applyingRows { selectingLatestOnOpen = false; pendingAction = nil }
        updatePreview()
    }
    func controlTextDidChange(_ obj: Notification) { selectingLatestOnOpen = false; pendingAction = nil; refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch NSStringFromSelector(selector) {
        case "moveDown:": moveSelection(1); return true
        case "moveUp:": moveSelection(-1); return true
        case "insertNewline:": defaultAction(); return true
        case "cancelOperation:": cancelOperation(nil); return true
        default: return false
        }
    }
    private func moveSelection(_ delta: Int) {
        selectingLatestOnOpen = false; pendingAction = nil
        let indexes = rows.indices.filter { if case .entry = rows[$0] { return true }; return false }
        guard !indexes.isEmpty else { return }
        let current = indexes.firstIndex(of: table.selectedRow) ?? 0
        let next = indexes[max(0, min(indexes.count - 1, current + delta))]
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 35 && flags.intersection([.command, .shift, .control, .option]) == [.command, .shift] {
            pinSelected(); return true
        }
        if event.keyCode == 35 && flags.intersection([.command, .shift, .control, .option]) == [.command, .option] {
            if selectedEntry?.hasImage == true { pinSelectedToScreen(); return true }
        }
        if flags.contains(.command) {
            switch event.keyCode {
            case 36, 76: flags.contains(.shift) ? pastePlain() : copyOnly(); return true
            case 40: openActions(); return true
            case 51: deleteSelected(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    func dismiss() {
        sessionToken = UUID(); pendingAction = nil; busy = false; selectingLatestOnOpen = false
        searchWork?.cancel(); searchUpdate?.cancel(); searchWork = nil; searchUpdate = nil
        hidingForAction = true; orderOut(nil); hidingForAction = false
    }
    override func cancelOperation(_ sender: Any?) {
        if let sheet = attachedSheet { endSheet(sheet); sheet.orderOut(nil); return }
        dismiss(); onDismiss?()
    }
    func windowWillClose(_ notification: Notification) {
        sessionToken = UUID(); pendingAction = nil; selectingLatestOnOpen = false
        schedulePreviewRelease(); onDismiss?()
    }
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, !hidingForAction, attachedSheet == nil, NSApp.modalWindow == nil else { return }
        // Outside clicks dismiss the picker without reactivating the previous application.
        sessionToken = UUID(); pendingAction = nil; busy = false; selectingLatestOnOpen = false; orderOut(nil)
    }
    private func updatePreview() {
        let entry = selectedEntry
        primary.isEnabled = entry != nil && !busy; pinPreview.isEnabled = entry != nil
        pinToScreen.isHidden = entry?.hasImage != true
        pinToScreen.isEnabled = entry?.hasImage == true && !busy
        primary.title = busy ? "准备中…" : history.settings.primaryAction == .copy ? "复制  ↵" : "粘贴到\(targetName ?? "原应用")  ↵"
        pinPreview.symbolName = entry?.pinned == true ? "pin.fill" : "pin"
        pinPreview.pillStyle = entry?.pinned == true ? .tinted(.amber) : .iconCircle
        pinPreview.isToggledOn = false
        if let entry {
            previewTitle.stringValue = String(entry.title.prefix(80)); previewSource.stringValue = entry.applicationName
            formatTag.isHidden = false
            formatTag.text = entry.hasImage ? "图片" : ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
            formatTag.symbolName = entry.hasImage ? "photo" : "doc.text"
            formatTag.tone = entry.hasImage ? .amber : .slate
            let days = max(0, Int(ceil(entry.copiedAt.addingTimeInterval(Double(history.settings.retentionDays) * 86400).timeIntervalSinceNow / 86400)))
            expiry.stringValue = entry.pinned ? "置顶 · 长期保留" : "约 \(days) 天后清理"
            expiry.textColor = entry.pinned ? ScreenClipTone.amber.foreground : .screenClipSecondaryLabel
        } else {
            previewTitle.stringValue = ""; previewSource.stringValue = ""; expiry.stringValue = ""
            formatTag.text = ""; formatTag.isHidden = true
        }
        guard previewID != entry?.id else { return }
        previewID = entry?.id; previewToken = UUID(); let token = previewToken
        image.image = nil; image.isHidden = true; textScroll.isHidden = false; preview.string = entry?.text ?? ""
        guard let entry else { return }
        if let cached = previewCache.object(forKey: entry.id as NSUUID) { showPreview(cached.value); return }
        if entry.hasImage, let thumbnail = thumbnailCache.object(forKey: entry.id as NSUUID) {
            image.image = thumbnail; image.isHidden = false; textScroll.isHidden = true
        }
        let epoch = previewCacheEpoch
        loadPreview(entry.id, 1200) { [weak self] value in
            guard let self, self.previewCacheEpoch == epoch else { return }
            if let value {
                let cost = (value.image.map { $0.bytesPerRow * $0.height } ?? 0) + value.text.utf8.count
                self.previewCache.setObject(CachedClipboardPreview(value), forKey: entry.id as NSUUID, cost: cost)
                if value.image != nil { self.imagePreviewIDs.insert(entry.id) }
            }
            guard self.previewToken == token else { return }
            if let value { self.showPreview(value) }
            else {
                self.previewID = nil; self.image.image = nil; self.image.isHidden = true; self.textScroll.isHidden = false
                self.preview.string = "这条历史无法预览，请重新复制或删除。"
            }
        }
    }
    private func showPreview(_ value: ClipboardHistoryPreview) {
        autoreleasepool {
            if let cg = value.image { image.image = NSImage(cgImage: cg, size: .zero); image.isHidden = false; textScroll.isHidden = true }
            else { preview.string = value.text.isEmpty ? "此格式可直接粘贴使用。" : value.text; image.isHidden = true; textScroll.isHidden = false }
        }
    }
    @objc private func changeFilter() { selectingLatestOnOpen = false; pendingAction = nil; previewID = nil; refresh() }
    @objc private func toggleRecording() { history.setRecording(!history.settings.isRecording) }
    @objc private func defaultAction() { use(history.settings.primaryAction, plainText: history.settings.pasteAsPlainText) }
    @objc private func copyOnly() { use(.copy, plainText: false) }
    @objc private func pastePlain() { use(.paste, plainText: true) }
    private func resumePendingAction() {
        guard searchUpdate == nil, !selectingLatestOnOpen, let action = pendingAction else { return }
        pendingAction = nil; use(action.0, plainText: action.1)
    }
    private func use(_ action: ClipboardPrimaryAction, plainText: Bool) {
        if searchUpdate != nil || selectingLatestOnOpen { pendingAction = (action, plainText); return }
        guard !busy, let entry = selectedEntry else { return }
        busy = true; updatePreview(); let token = sessionToken
        history.copy(entry.id, plainText: plainText) { [weak self] success in
            guard let self, self.sessionToken == token else { return }
            self.busy = false
            if success {
                self.hidingForAction = true; self.orderOut(nil); self.hidingForAction = false
                self.onAction?(action)
            } else { self.updatePreview() }
        }
    }
    @objc private func pinSelected() { if let entry = selectedEntry { history.setPinned(entry.id, !entry.pinned) } }
    @objc func pinSelectedToScreen() {
        guard !busy, let entry = selectedEntry, entry.hasImage else { return }
        busy = true; updatePreview(); let token = sessionToken
        history.loadImageData(entry.id) { [weak self] data in
            guard let self, self.sessionToken == token else { return }
            self.busy = false
            if let data {
                self.hidingForAction = true; self.orderOut(nil); self.hidingForAction = false
                self.onPinImageData?(data)
            } else {
                self.status.stringValue = "无法读取原图，请重试。"; self.status.textColor = .systemRed
                self.updatePreview()
            }
        }
    }
    @objc private func deleteSelected() {
        guard let entry = selectedEntry else { return }
        if !entry.pinned { previewCache.removeObject(forKey: entry.id as NSUUID); imagePreviewIDs.remove(entry.id); history.remove(entry.id); return }
        let alert = NSAlert(); alert.messageText = "删除这条置顶内容？"; alert.informativeText = "删除后无法恢复。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: self) { [weak self] response in if response == .alertFirstButtonReturn { self?.history.remove(entry.id) } }
    }
    @objc private func clearOrdinary() { confirmClear(includingPinned: false) }
    @objc private func clearAll() { confirmClear(includingPinned: true) }
    private func confirmClear(includingPinned: Bool) {
        let alert = NSAlert(); alert.messageText = includingPinned ? "删除全部历史，包括置顶？" : "清空普通历史？"
        alert.informativeText = includingPinned ? "所有历史和置顶内容都会删除，无法恢复。系统剪贴板中的当前内容保持不变。" : "置顶内容会保留。系统剪贴板中的当前内容保持不变。"
        alert.addButton(withTitle: includingPinned ? "全部删除" : "清空普通历史"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: self) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.previewCacheEpoch = UUID(); self?.imagePreviewIDs.removeAll()
                self?.previewCache.removeAllObjects(); self?.thumbnailCache.removeAllObjects(); self?.history.clear(includingPinned: includingPinned)
            }
        }
    }
    @objc private func openActions() {
        let menu = NSMenu(); menu.font = .systemFont(ofSize: 13)
        func add(_ title: String, _ selector: Selector, key: String = "", flags: NSEvent.ModifierFlags = .command, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; item.keyEquivalentModifierMask = flags
            item.isEnabled = enabled; menu.addItem(item)
        }
        menu.autoenablesItems = false
        add("粘贴到原应用", #selector(defaultPaste), enabled: selectedEntry != nil)
        add("仅复制", #selector(copyOnly), key: "\r", enabled: selectedEntry != nil)
        add("粘贴为纯文本", #selector(pastePlain), key: "\r", flags: [.command, .shift], enabled: selectedEntry?.text.isEmpty == false)
        add("贴到屏幕", #selector(pinSelectedToScreen), key: "p", flags: [.command, .option], enabled: selectedEntry?.hasImage == true)
        menu.addItem(.separator())
        add(selectedEntry?.pinned == true ? "取消置顶" : "置顶 · 长期保留", #selector(pinSelected), key: "p", flags: [.command, .shift], enabled: selectedEntry != nil)
        add("删除这条", #selector(deleteSelected), key: "\u{8}", enabled: selectedEntry != nil)
        menu.addItem(.separator()); add("清空普通历史…", #selector(clearOrdinary)); add("删除全部（含置顶）…", #selector(clearAll))
        menu.popUp(positioning: nil, at: NSPoint(x: actions.bounds.minX, y: actions.bounds.maxY + 5), in: actions)
    }
    @objc private func defaultPaste() { use(.paste, plainText: history.settings.pasteAsPlainText) }
    @objc private func openSettings() {
        let window = ClipboardHistorySettingsWindow(settings: history.settings)
        window.onSave = { [weak self] in self?.history.updateSettings($0) }
        settingsWindow = window; beginSheet(window)
    }
}
