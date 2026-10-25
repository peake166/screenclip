import AppKit
import OSLog

private final class ClipboardRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.screenClipAccent.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 9, yRadius: 9).fill()
    }
}

private final class ClipboardCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    let pinned = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "已置顶")!)
    var entryID: UUID?
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingTail
        meta.font = .systemFont(ofSize: 11); meta.textColor = .screenClipSecondaryLabel; meta.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .screenClipSecondaryLabel
        pinned.contentTintColor = .screenClipSecondaryLabel
        let labels = NSStackView(views: [name, meta]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        for view in [icon, labels, pinned] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 34),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11), labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: pinned.leadingAnchor, constant: -8),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor), meta.widthAnchor.constraint(equalTo: labels.widthAnchor),
            pinned.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), pinned.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinned.widthAnchor.constraint(equalToConstant: 11), pinned.heightAnchor.constraint(equalToConstant: 13)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
    private let record = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewSource = NSTextField(labelWithString: "")
    private let expiry = NSTextField(labelWithString: "")
    private let format = NSTextField(labelWithString: "")
    private let textScroll = NSScrollView()
    private let image = NSImageView()
    private let primary = NSButton(title: "粘贴", target: nil, action: nil)
    private let actions = NSButton(title: "操作  ⌘K", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "⌘↵ 仅复制")
    private let filters = NSSegmentedControl(labels: ["全部", "文字", "图片", "置顶"], trackingMode: .selectOne, target: nil, action: nil)
    private let pinPreview = NSButton()
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
        let brand = NSTextField(labelWithString: "截图助手  /  剪贴板")
        brand.font = .systemFont(ofSize: 12, weight: .medium); brand.textColor = .screenClipSecondaryLabel
        record.target = self; record.action = #selector(toggleRecording); record.isBordered = false; record.font = .systemFont(ofSize: 11)
        record.setAccessibilityLabel("暂停或开启剪贴板记录"); record.contentTintColor = .screenClipSecondaryLabel
        let settings = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "剪贴板设置")!, target: self, action: #selector(openSettings))
        settings.isBordered = false; settings.contentTintColor = .screenClipSecondaryLabel; settings.setAccessibilityLabel("剪贴板设置")
        let titlebar = NSStackView(views: [brand, NSView(), record, settings]); titlebar.spacing = 10; titlebar.alignment = .centerY
        search.placeholderString = "搜索复制过的内容…"; search.delegate = self
        search.setAccessibilityLabel("搜索剪贴板历史"); search.sendsSearchStringImmediately = true
        search.font = .systemFont(ofSize: 17); search.controlSize = .large
        filters.selectedSegment = 0; filters.selectedSegmentBezelColor = .screenClipAccent; filters.segmentStyle = .rounded; filters.controlSize = .small
        filters.target = self; filters.action = #selector(changeFilter); filters.setAccessibilityLabel("剪贴板内容类型")

        let list = NSScrollView(); list.hasVerticalScroller = true; list.autohidesScrollers = true; list.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain; table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(defaultAction)
        table.onActivate = { [weak self] in self?.defaultAction() }
        table.onCopy = { [weak self] in self?.copyOnly() }
        table.onCancel = { [weak self] in self?.cancelOperation(nil) }
        table.setAccessibilityLabel("剪贴板历史列表"); list.documentView = table
        let detail = ReadableSurface()
        previewTitle.font = .systemFont(ofSize: 16, weight: .medium); previewTitle.lineBreakMode = .byTruncatingTail
        previewSource.font = .systemFont(ofSize: 11); previewSource.textColor = .screenClipSecondaryLabel; previewSource.lineBreakMode = .byTruncatingTail
        pinPreview.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "置顶")
        pinPreview.isBordered = false; pinPreview.target = self; pinPreview.action = #selector(pinSelected)
        pinPreview.setAccessibilityLabel("置顶或取消置顶")
        pinPreview.toolTip = "置顶或取消置顶  ⇧⌘P"
        let detailHeader = NSStackView(views: [previewSource, NSView(), pinPreview]); detailHeader.alignment = .centerY
        preview.isEditable = false; preview.isSelectable = true; preview.drawsBackground = false
        preview.font = .systemFont(ofSize: 13); preview.textColor = .labelColor
        preview.textContainerInset = NSSize(width: 0, height: 8)
        preview.isVerticallyResizable = true; preview.isHorizontallyResizable = false
        preview.autoresizingMask = .width; preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("剪贴板内容预览")
        textScroll.hasVerticalScroller = true; textScroll.drawsBackground = false; textScroll.documentView = preview
        image.imageScaling = .scaleProportionallyUpOrDown; image.setAccessibilityLabel("剪贴板图片预览")
        image.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        image.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let previewBody = NSView()
        for view in [textScroll, image] { pin(view, in: previewBody) }
        for label in [format, expiry] { label.font = .systemFont(ofSize: 11); label.textColor = .screenClipSecondaryLabel }
        expiry.setContentCompressionResistancePriority(.required, for: .horizontal)
        let detailFooter = NSStackView(views: [format, NSView(), expiry]); detailFooter.alignment = .centerY
        for view in [detailHeader, previewTitle, previewBody, detailFooter] {
            view.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(view)
            view.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 18).isActive = true
            view.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -18).isActive = true
        }
        NSLayoutConstraint.activate([
            detailHeader.topAnchor.constraint(equalTo: detail.topAnchor, constant: 14), detailHeader.heightAnchor.constraint(equalToConstant: 22),
            previewTitle.topAnchor.constraint(equalTo: detailHeader.bottomAnchor, constant: 12), previewTitle.heightAnchor.constraint(equalToConstant: 24),
            previewBody.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 8), previewBody.bottomAnchor.constraint(equalTo: detailFooter.topAnchor, constant: -12),
            detailFooter.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -16), detailFooter.heightAnchor.constraint(equalToConstant: 18)
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
        actions.target = self; actions.action = #selector(openActions); actions.isBordered = false; actions.font = .systemFont(ofSize: 11)
        actions.setContentHuggingPriority(.required, for: .horizontal); actions.contentTintColor = .screenClipSecondaryLabel
        hint.font = .systemFont(ofSize: 11); hint.textColor = .screenClipSecondaryLabel
        primary.target = self; primary.action = #selector(defaultAction); primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"; primary.keyEquivalentModifierMask = []; primary.bezelColor = .screenClipAccent
        primary.setAccessibilityLabel("使用选中的剪贴板内容")
        primary.setContentHuggingPriority(.required, for: .horizontal)
        let footer = NSStackView(views: [actions, status, NSView(), hint, primary]); footer.spacing = 10; footer.alignment = .centerY
        for view in [titlebar, search, filters, split, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16).isActive = true
            if view != filters { view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16).isActive = true }
        }
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 13), titlebar.heightAnchor.constraint(equalToConstant: 24),
            search.topAnchor.constraint(equalTo: titlebar.bottomAnchor, constant: 10), search.heightAnchor.constraint(equalToConstant: 34),
            filters.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10), filters.heightAnchor.constraint(equalToConstant: 24),
            split.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 12), split.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12), footer.heightAnchor.constraint(equalToConstant: 30),
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
        record.title = history.settings.isRecording ? "正在记录  Ⅱ" : "已暂停  ▶"
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
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = .screenClipSecondaryLabel
            let view = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return view
        case .entry(let entry):
            let id = NSUserInterfaceItemIdentifier("clipboard-entry")
            let cell = (table.makeView(withIdentifier: id, owner: self) as? ClipboardCell) ?? ClipboardCell(frame: .zero)
            cell.identifier = id; cell.entryID = entry.id; cell.name.stringValue = entry.title; cell.pinned.isHidden = !entry.pinned
            let relative = RelativeDateTimeFormatter(); relative.unitsStyle = .short
            let now = Date()
            let age = abs(now.timeIntervalSince(entry.copiedAt)) < 60 ? "刚刚" : relative.localizedString(for: entry.copiedAt, relativeTo: now)
            cell.meta.stringValue = entry.applicationName + " · " + age
            cell.icon.image = NSImage(systemSymbolName: entry.hasImage ? "photo" : "doc.text", accessibilityDescription: nil)
            if entry.hasImage {
                if let image = thumbnailCache.object(forKey: entry.id as NSUUID) { cell.icon.image = image }
                else { loadPreview(entry.id, 80) { [weak self, weak cell] preview in
                    guard let cg = preview?.image else { return }; let image = NSImage(cgImage: cg, size: .zero)
                    self?.thumbnailCache.setObject(image, forKey: entry.id as NSUUID, cost: cg.bytesPerRow * cg.height)
                    if cell?.entryID == entry.id { cell?.icon.image = image }
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
        primary.title = busy ? "准备中…" : history.settings.primaryAction == .copy ? "复制  ↵" : "粘贴到\(targetName ?? "原应用")  ↵"
        pinPreview.image = NSImage(systemSymbolName: entry?.pinned == true ? "pin.fill" : "pin", accessibilityDescription: entry?.pinned == true ? "取消置顶" : "置顶")
        if let entry {
            previewTitle.stringValue = String(entry.title.prefix(80)); previewSource.stringValue = entry.applicationName
            format.stringValue = entry.hasImage ? "图片" : ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
            let days = max(0, Int(ceil(entry.copiedAt.addingTimeInterval(Double(history.settings.retentionDays) * 86400).timeIntervalSinceNow / 86400)))
            expiry.stringValue = entry.pinned ? "置顶 · 长期保留" : "约 \(days) 天后清理"
        } else { previewTitle.stringValue = ""; previewSource.stringValue = ""; format.stringValue = ""; expiry.stringValue = "" }
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
