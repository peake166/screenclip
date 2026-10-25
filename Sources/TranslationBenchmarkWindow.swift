import AppKit

private final class BenchmarkRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.screenClipAccent.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

@MainActor
final class TranslationBenchmarkWindow: NSWindow, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let benchmark: TranslationBenchmark
    var onUse: ((TranslationBenchmarkCandidate) throws -> Void)? { didSet { reload() } }
    var onClosed: (() -> Void)?
    private let table = NSTableView()
    private let progress = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl(labels: ["测试原文", "译文"], trackingMode: .selectOne, target: nil, action: nil)
    private let detail = NSTextView()
    private let start = NSButton(title: "开始测速", target: nil, action: nil)
    private let use = NSButton(title: "使用此模型", target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let root = NSStackView()
    private var rows: [TranslationBenchmarkEntry] = []
    private var selected: TranslationBenchmarkCandidate?
    private var userSelected = false, applyingRows = false, closing = false

    init(benchmark: TranslationBenchmark) {
        self.benchmark = benchmark
        super.init(contentRect: NSRect(x: 0, y: 0, width: 650, height: 540),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "模型测速"; delegate = self; isReleasedWhenClosed = false
        let surface = FrostedSurface(); contentView = surface
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: surface.topAnchor, constant: 18)
        ])
        let language = NSTextField(labelWithString: (benchmark.settings.target == .english ? "中文" : "英文") + " → " + benchmark.settings.target.title)
        language.font = .systemFont(ofSize: 13, weight: .medium)
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); progress.textColor = .screenClipSecondaryLabel
        progress.setAccessibilityLabel("测速进度")
        let heading = NSStackView(views: [language, NSView(), progress]); heading.alignment = .centerY
        root.addArrangedSubview(heading)

        for (id, title, width) in [("model", "模型", 250.0), ("time", "耗时", 80.0), ("speed", "原文/秒", 85.0), ("state", "结果", 170.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = width; column.maxWidth = id == "model" ? 400 : width
            column.resizingMask = id == "model" ? .autoresizingMask : []
            if id == "speed" { column.headerToolTip = "相同测试短文的原文字符数 ÷ 完整翻译耗时" }
            table.addTableColumn(column)
        }
        table.style = .plain; table.rowHeight = 43; table.intercellSpacing = .zero
        table.headerView = nil; table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear; table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("模型翻译测速结果")
        let columns = NSStackView(); columns.alignment = .centerY; columns.spacing = 0
        for column in table.tableColumns {
            let label = NSTextField(labelWithString: column.title)
            label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = .screenClipSecondaryLabel
            label.toolTip = column.headerToolTip
            let holder = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: column.identifier.rawValue == "model" ? 8 : 0),
                label.centerYAnchor.constraint(equalTo: holder.centerYAnchor)])
            if column.identifier.rawValue != "model" { holder.widthAnchor.constraint(equalToConstant: column.width).isActive = true }
            columns.addArrangedSubview(holder)
        }
        columns.heightAnchor.constraint(equalToConstant: 18).isActive = true; root.addArrangedSubview(columns)
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        list.autohidesScrollers = true; list.drawsBackground = false; list.borderType = .noBorder
        list.heightAnchor.constraint(equalToConstant: CGFloat(min(6, max(1, benchmark.entries.count))) * 43).isActive = true
        root.addArrangedSubview(list)
        if benchmark.entries.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "先在翻译设置中填写硅基流动或智谱的 API 密钥。")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .screenClipSecondaryLabel
            root.addArrangedSubview(empty)
        }
        mode.selectedSegment = 0; mode.controlSize = .small; mode.segmentStyle = .rounded
        mode.target = self; mode.action = #selector(changePreview)
        mode.setAccessibilityLabel("测试原文或译文预览")
        root.addArrangedSubview(mode)
        detail.isEditable = false; detail.isSelectable = true; detail.drawsBackground = false
        detail.font = .systemFont(ofSize: 12); detail.textColor = .labelColor
        detail.textContainerInset = NSSize(width: 10, height: 8)
        detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false
        detail.autoresizingMask = .width; detail.textContainer?.widthTracksTextView = true
        detail.setAccessibilityLabel("测速内容预览")
        let preview = NSScrollView(); preview.documentView = detail; preview.hasVerticalScroller = true
        preview.autohidesScrollers = true; preview.drawsBackground = false
        let plate = ReadableSurface(); preview.translatesAutoresizingMaskIntoConstraints = false; plate.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 2),
            preview.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -2),
            preview.topAnchor.constraint(equalTo: plate.topAnchor, constant: 2),
            preview.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -2),
            plate.heightAnchor.constraint(equalToConstant: 84)
        ])
        root.addArrangedSubview(plate)
        let note = NSTextField(wrappingLabelWithString: "每模型 1 次请求，最多 12 秒，按服务商计费。耗时含网络等待，不含截图和识别，仅代表本次。")
        note.font = .systemFont(ofSize: 11); note.textColor = .screenClipSecondaryLabel
        root.addArrangedSubview(note)
        feedback.font = .systemFont(ofSize: 12); feedback.textColor = .systemRed; feedback.isHidden = true
        feedback.setAccessibilityLabel("测速操作状态"); root.addArrangedSubview(feedback)
        let close = NSButton(title: "关闭", target: self, action: #selector(closePressed)); close.keyEquivalent = "\u{1b}"
        start.target = self; start.action = #selector(startOrStop); start.contentTintColor = .screenClipAccent
        start.setAccessibilityLabel("开始或停止模型测速")
        use.target = self; use.action = #selector(useModel); use.contentTintColor = .screenClipAccent
        use.setAccessibilityLabel("使用选中的测速模型")
        for button in [close, start, use] { button.bezelStyle = .rounded }
        let footer = NSStackView(views: [start, NSView(), close, use]); footer.spacing = 8; footer.alignment = .centerY
        root.addArrangedSubview(footer)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        benchmark.onChange = { [weak self] in self?.reload() }
        reload(); resizeToFit()
    }

    private func reload() {
        guard !closing else { return }
        rows = benchmark.isRunning || benchmark.isStopping ? benchmark.entries : benchmark.rankedEntries
        if !benchmark.isRunning, !benchmark.isStopping, !userSelected, let fastest = benchmark.fastest {
            selected = fastest; mode.selectedSegment = 1
        }
        applyingRows = true
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.candidate == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); selected = rows[0].candidate
        }
        applyingRows = false
        progress.stringValue = benchmark.isStopping ? "停止中…"
            : benchmark.isRunning ? "\(benchmark.completedCount) / \(rows.count)"
            : benchmark.entries.contains(where: { $0.state == .stopped }) ? "已停止 · \(benchmark.completedCount) / \(rows.count)"
            : benchmark.completedCount > 0 ? "完成 \(benchmark.completedCount) / \(rows.count)" : "\(rows.count) 个模型"
        start.title = benchmark.isStopping ? "停止中…" : benchmark.isRunning ? "停止" : benchmark.completedCount > 0 ? "重新测速" : "开始测速"
        start.isEnabled = !rows.isEmpty && !benchmark.isStopping
        let successful = selectedEntry.map { if case .success = $0.state { return true }; return false } ?? false
        use.isEnabled = successful && !benchmark.isRunning && !benchmark.isStopping && onUse != nil
        start.keyEquivalent = !benchmark.isRunning && !benchmark.isStopping && !successful ? "\r" : ""
        use.keyEquivalent = use.isEnabled ? "\r" : ""
        renderPreview()
    }
    private var selectedEntry: TranslationBenchmarkEntry? { rows.first { $0.candidate == selected } }
    private func renderPreview() {
        if mode.selectedSegment == 0 { detail.string = benchmark.sample; return }
        switch selectedEntry?.state {
        case .success(let result): detail.string = result.translation
        case .failed(let reason): detail.string = reason
        case .running: detail.string = "正在翻译…"
        case .stopped: detail.string = "测速已停止。"
        default: detail.string = "完成测速后可查看译文。"
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { BenchmarkRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let entry = rows[row]
        if id == "model" {
            let name = NSTextField(labelWithString: entry.candidate.model)
            name.font = .systemFont(ofSize: 12, weight: .medium); name.lineBreakMode = .byTruncatingTail
            name.toolTip = entry.candidate.model
            let provider = NSTextField(labelWithString: entry.candidate.provider.title)
            provider.font = .systemFont(ofSize: 10); provider.textColor = .screenClipSecondaryLabel
            let labels = NSStackView(views: [name, provider]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
            let cell = NSView(); labels.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(labels)
            NSLayoutConstraint.activate([labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let text = NSTextField(labelWithString: "—"); text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        switch (id, entry.state) {
        case ("time", .success(let value)): text.stringValue = String(format: "%.2f 秒", value.seconds)
        case ("speed", .success(let value)): text.stringValue = String(format: "%.0f 字", value.charactersPerSecond)
        case ("state", .ready): text.stringValue = "等待"
        case ("state", .running): text.stringValue = "测速中…"; text.textColor = .screenClipAccent
        case ("state", .stopped): text.stringValue = "已停止"
        case ("state", .success):
            text.stringValue = benchmark.isRunning ? "成功" : entry.candidate == benchmark.fastest ? "最快" : "第 \(row + 1) 名"
            text.textColor = .screenClipAccent
        case ("state", .failed(let reason)): text.stringValue = reason; text.textColor = .systemRed; text.toolTip = reason
        default: break
        }
        text.lineBreakMode = .byTruncatingTail
        let cell = NSView(); text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingRows, rows.indices.contains(table.selectedRow) else { return }
        selected = rows[table.selectedRow].candidate; userSelected = true; mode.selectedSegment = 1
        reload()
    }
    @objc private func changePreview() { renderPreview() }
    @objc private func startOrStop() {
        if benchmark.isRunning { benchmark.stop() }
        else {
            userSelected = false; selected = nil; mode.selectedSegment = 0; feedback.isHidden = true
            _ = benchmark.start()
        }
    }
    @objc private func useModel() {
        guard use.isEnabled, let selected else { return }
        do { try onUse?(selected); close() }
        catch {
            feedback.stringValue = error is TranslationFailure ? error.localizedDescription : TranslationFailure.credentials.localizedDescription
            feedback.isHidden = false; resizeToFit()
        }
    }
    private func resizeToFit() {
        contentView?.layoutSubtreeIfNeeded()
        let top = frame.maxY
        setContentSize(NSSize(width: 650, height: root.fittingSize.height + 38))
        setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height))
    }
    @objc private func closePressed() { close() }
    override func cancelOperation(_ sender: Any?) { close() }
    override func close() {
        guard !closing else { return }; closing = true
        benchmark.stop(); benchmark.onChange = nil
        sheetParent?.endSheet(self); super.close(); onClosed?()
    }
}
