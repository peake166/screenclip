import AppKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardHistorySettingsWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate {
    private var draft: ClipboardHistorySettings
    private let retention = NSPopUpButton(), count = NSPopUpButton(), capacity = NSPopUpButton(), primary = NSPopUpButton()
    private let plain = PillToggleSwitch(title: "优先以纯文本粘贴")
    private let table = NSTableView()
    private let days = [1, 7, 30, 90], counts = [50, 100, 200, 500, 1000, 5000, 10000]
    private let capacities = [256 * 1024 * 1024, 1024 * 1024 * 1024, 2 * 1024 * 1024 * 1024]
    private var applications: [(id: String, name: String)] { draft.excludedApplications.map { ($0.key, $0.value) }.sorted { $0.name < $1.name } }
    var onSave: ((ClipboardHistorySettings) -> Void)?

    init(settings: ClipboardHistorySettings) {
        draft = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 472, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        title = "剪贴板偏好"; titlebarAppearsTransparent = true; isReleasedWhenClosed = false
        let surface = FrostedSurface(radius: 16); contentView = surface
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: surface.topAnchor, constant: 18)])
        primary.addItems(withTitles: ["粘贴到原输入框", "仅复制"]); primary.selectItem(at: settings.primaryAction == .paste ? 0 : 1)
        primary.setAccessibilityLabel("剪贴板默认操作")
        retention.addItems(withTitles: days.map { "\($0) 天" }); retention.selectItem(at: days.firstIndex(of: settings.retentionDays) ?? 2)
        retention.setAccessibilityLabel("历史保留时间")
        capacity.addItems(withTitles: ["256 MB", "1 GB", "2 GB"]); capacity.selectItem(at: capacities.firstIndex(of: settings.maximumBytes) ?? 1)
        capacity.setAccessibilityLabel("历史空间上限")
        count.addItems(withTitles: counts.map { "\($0) 条" }); count.selectItem(at: counts.firstIndex(of: settings.maximumCount) ?? 5)
        count.setAccessibilityLabel("历史保留条数")

        let prefsCard = InsetCardView(radius: 12)
        prefsCard.translatesAutoresizingMaskIntoConstraints = false
        let prefsStack = NSStackView(); prefsStack.orientation = .vertical; prefsStack.alignment = .leading; prefsStack.spacing = 8
        prefsStack.translatesAutoresizingMaskIntoConstraints = false; prefsCard.addSubview(prefsStack)
        NSLayoutConstraint.activate([
            prefsStack.leadingAnchor.constraint(equalTo: prefsCard.leadingAnchor, constant: 14),
            prefsStack.trailingAnchor.constraint(equalTo: prefsCard.trailingAnchor, constant: -14),
            prefsStack.topAnchor.constraint(equalTo: prefsCard.topAnchor, constant: 12),
            prefsStack.bottomAnchor.constraint(equalTo: prefsCard.bottomAnchor, constant: -12)
        ])
        for (idx, (title, picker)) in [("回车操作", primary), ("普通记录保留", retention), ("空间上限", capacity), ("最多记录", count)].enumerated() {
            if idx > 0 {
                let sep = HairlineDivider(vertical: false)
                prefsStack.addArrangedSubview(sep); sep.widthAnchor.constraint(equalTo: prefsStack.widthAnchor).isActive = true
            }
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12.5, weight: .medium)
            let row = NSStackView(views: [label, NSView(), picker]); row.alignment = .centerY; row.heightAnchor.constraint(equalToConstant: 26).isActive = true
            prefsStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: prefsStack.widthAnchor).isActive = true
        }
        let plainSep = HairlineDivider(vertical: false)
        prefsStack.addArrangedSubview(plainSep); plainSep.widthAnchor.constraint(equalTo: prefsStack.widthAnchor).isActive = true
        plain.state = settings.pasteAsPlainText ? .on : .off
        prefsStack.addArrangedSubview(plain)
        root.addArrangedSubview(prefsCard); prefsCard.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let hint = NSTextField(wrappingLabelWithString: "置顶长期保留；取消置顶后重新计时。容量不足时清理最早的普通记录。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .screenClipSecondaryLabel
        root.addArrangedSubview(hint); hint.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let excludedCard = InsetCardView(radius: 12)
        excludedCard.translatesAutoresizingMaskIntoConstraints = false
        let excludedHeader = NSTextField(labelWithString: "不记录这些应用")
        excludedHeader.font = .systemFont(ofSize: 12, weight: .semibold); excludedHeader.textColor = .screenClipSecondaryLabel
        table.addTableColumn(NSTableColumn(identifier: .init("app"))); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 25; table.style = .plain; table.backgroundColor = .clear
        table.setAccessibilityLabel("排除的应用")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.drawsBackground = false; scroll.documentView = table
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let add = PillActionButton(title: "添加应用…", symbolName: "plus", style: .subtle, target: self, action: #selector(addApplication))
        add.fixedHeight = 24; add.horizontalPadding = 10
        let remove = PillActionButton(title: "移除", style: .subtle, target: self, action: #selector(removeApplication))
        remove.fixedHeight = 24; remove.horizontalPadding = 10
        let actions = NSStackView(views: [excludedHeader, NSView(), add, remove]); actions.alignment = .centerY; actions.spacing = 6
        let excludedSep = HairlineDivider(vertical: false)
        let excludedStack = NSStackView(views: [actions, excludedSep, scroll])
        excludedStack.orientation = .vertical; excludedStack.alignment = .leading; excludedStack.spacing = 8
        excludedStack.translatesAutoresizingMaskIntoConstraints = false; excludedCard.addSubview(excludedStack)
        NSLayoutConstraint.activate([
            excludedStack.leadingAnchor.constraint(equalTo: excludedCard.leadingAnchor, constant: 14),
            excludedStack.trailingAnchor.constraint(equalTo: excludedCard.trailingAnchor, constant: -14),
            excludedStack.topAnchor.constraint(equalTo: excludedCard.topAnchor, constant: 10),
            excludedStack.bottomAnchor.constraint(equalTo: excludedCard.bottomAnchor, constant: -10),
            actions.widthAnchor.constraint(equalTo: excludedStack.widthAnchor),
            excludedSep.widthAnchor.constraint(equalTo: excludedStack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: excludedStack.widthAnchor)
        ])
        root.addArrangedSubview(excludedCard); excludedCard.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let privacy = NSTextField(wrappingLabelWithString: "历史仅在本机加密保存。普通文本中的密码、API 密钥仍可能被记录。")
        privacy.font = .systemFont(ofSize: 11); privacy.textColor = .screenClipSecondaryLabel
        root.addArrangedSubview(privacy); privacy.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let cancel = PillActionButton(title: "取消", style: .subtle, target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"; cancel.fixedHeight = 30; cancel.horizontalPadding = 14
        let save = PillActionButton(title: "保存", style: .primary(.blue), target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"; save.fixedHeight = 30; save.horizontalPadding = 16
        let footer = NSStackView(views: [NSView(), cancel, save]); footer.spacing = 8; root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        surface.layoutSubtreeIfNeeded(); setContentSize(NSSize(width: 472, height: root.fittingSize.height + 38))
    }
    func numberOfRows(in tableView: NSTableView) -> Int { applications.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: applications[row].name); label.font = .systemFont(ofSize: 12); return label
    }
    @objc private func addApplication() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications"); picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true; picker.prompt = "添加"
        picker.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in picker.urls {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                self.draft.excludedApplications[id] = url.deletingPathExtension().lastPathComponent
            }
            self.table.reloadData()
        }
    }
    @objc private func removeApplication() {
        guard applications.indices.contains(table.selectedRow) else { return }
        draft.excludedApplications.removeValue(forKey: applications[table.selectedRow].id); table.reloadData()
    }
    @objc private func cancelPressed() { sheetParent?.endSheet(self); orderOut(nil) }
    @objc private func savePressed() {
        draft.retentionDays = days[max(0, retention.indexOfSelectedItem)]
        draft.maximumCount = counts[max(0, count.indexOfSelectedItem)]
        draft.maximumBytes = capacities[max(0, capacity.indexOfSelectedItem)]
        draft.primaryAction = primary.indexOfSelectedItem == 0 ? .paste : .copy
        draft.pasteAsPlainText = plain.state == .on
        onSave?(draft); sheetParent?.endSheet(self); orderOut(nil)
    }
}
