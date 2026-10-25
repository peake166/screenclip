import AppKit

@MainActor
final class TranslationSettingsWindow: NSWindow, NSWindowDelegate, NSComboBoxDelegate {
    var onSaved: (() -> Void)?
    private let store: TranslationSettingsStore
    private let provider = NSPopUpButton()
    private let target = NSPopUpButton()
    private let model = NSComboBox()
    private let key = NSSecureTextField()
    private let removeKey = NSButton(title: "删除密钥", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let test = NSButton(title: "测试翻译", target: nil, action: nil)
    private let cloudFields = NSStackView()
    private let root = NSStackView()
    private let system = SystemTranslation()
    private let cloud = CloudTranslation()
    private var draft: TranslationSettings
    private var currentProvider: TranslationProvider
    private var keyEdits: [TranslationProvider: String] = [:]
    private var testTask: Task<Void, Never>?
    private var testID = UUID()
    private var benchmarkWindow: TranslationBenchmarkWindow?
    private let benchmarkTranslator: TranslationBenchmark.Translator?

    init(store: TranslationSettingsStore, benchmarkTranslator: TranslationBenchmark.Translator? = nil) {
        self.store = store; self.benchmarkTranslator = benchmarkTranslator
        draft = store.settings; currentProvider = store.settings.provider
        super.init(contentRect: CGRect(x: 0, y: 0, width: 460, height: 360),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "翻译设置"; isReleasedWhenClosed = false; delegate = self; level = .floating
        let effect = FrostedSurface()
        contentView = effect
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: effect.topAnchor, constant: 22)
        ])
        provider.addItems(withTitles: TranslationProvider.allCases.map(\.title))
        provider.selectItem(at: TranslationProvider.allCases.firstIndex(of: draft.provider)!)
        provider.target = self; provider.action = #selector(changeProvider)
        provider.setAccessibilityLabel("翻译服务")
        target.addItems(withTitles: TranslationTarget.allCases.map(\.title))
        target.selectItem(at: TranslationTarget.allCases.firstIndex(of: draft.target)!)
        target.setAccessibilityLabel("目标语言")
        root.addArrangedSubview(row("翻译服务", provider))
        root.addArrangedSubview(row("目标语言", target))
        cloudFields.orientation = .vertical; cloudFields.alignment = .leading; cloudFields.spacing = 12
        model.font = .systemFont(ofSize: 13); model.completes = true
        model.delegate = self
        model.setAccessibilityLabel("翻译模型")
        key.font = .systemFont(ofSize: 13); key.setAccessibilityLabel("API 密钥")
        cloudFields.addArrangedSubview(row("模型", model))
        cloudFields.addArrangedSubview(row("API 密钥", key))
        let keyNote = NSTextField(labelWithString: "密钥仅保存在 macOS 钥匙串")
        keyNote.font = .systemFont(ofSize: 11); keyNote.textColor = .screenClipSecondaryLabel
        removeKey.target = self; removeKey.action = #selector(deleteKey)
        removeKey.isBordered = false; removeKey.font = .systemFont(ofSize: 11); removeKey.contentTintColor = .screenClipSecondaryLabel
        let keyFooter = NSStackView(views: [keyNote, NSView(), removeKey]); keyFooter.alignment = .centerY
        cloudFields.addArrangedSubview(keyFooter)
        for view in cloudFields.arrangedSubviews { view.widthAnchor.constraint(equalTo: cloudFields.widthAnchor).isActive = true }
        root.addArrangedSubview(cloudFields)
        note.font = .systemFont(ofSize: 11); note.textColor = .screenClipSecondaryLabel
        root.addArrangedSubview(note)
        feedback.font = .systemFont(ofSize: 12); feedback.isHidden = true
        feedback.setAccessibilityLabel("设置状态")
        root.addArrangedSubview(feedback)
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings)); save.bezelStyle = .rounded
        save.keyEquivalent = "\r"; save.contentTintColor = .screenClipAccent
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSettings)); cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        test.target = self; test.action = #selector(testTranslation); test.bezelStyle = .rounded
        let speed = NSButton(title: "模型测速…", target: self, action: #selector(openBenchmark)); speed.bezelStyle = .rounded
        let footer = NSStackView(views: [test, speed, NSView(), cancel, save]); footer.alignment = .centerY; footer.spacing = 8
        root.addArrangedSubview(footer)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        system.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1); effect.addSubview(system.view)
        populateProvider(); resizeToFit(); center()
    }

    private func row(_ title: String, _ field: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12); label.textColor = .screenClipSecondaryLabel
        label.widthAnchor.constraint(equalToConstant: 68).isActive = true
        let row = NSStackView(views: [label, field]); row.spacing = 12; row.alignment = .centerY
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }
    private func syncDraft() {
        makeFirstResponder(nil)
        draft.provider = currentProvider
        draft.target = TranslationTarget.allCases[max(0, target.indexOfSelectedItem)]
        if currentProvider != .system {
            draft.setModel(model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), for: currentProvider)
            if !key.stringValue.isEmpty { keyEdits[currentProvider] = key.stringValue }
            else if let edited = keyEdits[currentProvider], !edited.isEmpty { keyEdits.removeValue(forKey: currentProvider) }
        }
    }
    private func populateProvider() {
        cloudFields.isHidden = currentProvider == .system
        model.removeAllItems(); model.addItems(withObjectValues: currentProvider.suggestedModels)
        model.stringValue = draft.model(for: currentProvider)
        key.stringValue = keyEdits[currentProvider] ?? ""
        var saved = false
        if currentProvider != .system {
            do { saved = try store.key(for: currentProvider) != nil }
            catch { showFeedback(error.localizedDescription, isError: true) }
        }
        key.placeholderString = keyEdits[currentProvider] == "" ? "保存后移除" : saved ? "已保存，留空保留" : "粘贴 API 密钥"
        removeKey.isEnabled = saved || !(keyEdits[currentProvider] ?? "").isEmpty
        updateModelNote()
    }
    private func updateModelNote() {
        note.stringValue = currentProvider.modelUsageNote(for: model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let value = model.objectValueOfSelectedItem as? String {
            note.stringValue = currentProvider.modelUsageNote(for: value)
        }
    }
    func controlTextDidChange(_ notification: Notification) { updateModelNote() }
    @objc private func changeProvider() {
        stopTest(); syncDraft()
        currentProvider = TranslationProvider.allCases[max(0, provider.indexOfSelectedItem)]
        draft.provider = currentProvider; feedback.isHidden = true
        populateProvider(); resizeToFit()
    }
    @objc private func deleteKey() {
        key.stringValue = ""; keyEdits[currentProvider] = ""
        key.placeholderString = "保存后移除"; removeKey.isEnabled = false
    }
    @objc private func saveSettings() {
        syncDraft()
        do {
            try store.save(draft, keys: keyEdits)
            stopTest(); onSaved?(); close()
        } catch { showFeedback(error.localizedDescription, isError: true) }
    }
    @objc private func cancelSettings() { close() }
    @objc private func openBenchmark() {
        guard benchmarkWindow == nil else { return }
        stopTest(); syncDraft()
        do {
            var keys: [TranslationProvider: String] = [:]
            for service in TranslationProvider.allCases where service != .system {
                let value = try keyEdits[service] ?? store.key(for: service) ?? ""
                keys[service] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let settings = draft, pendingKeys = keyEdits
            let benchmark = TranslationBenchmark(settings: settings, keys: keys, translator: benchmarkTranslator)
            let window = TranslationBenchmarkWindow(benchmark: benchmark)
            window.onUse = { [weak self] candidate in
                guard let self else { return }
                var chosen = settings; chosen.provider = candidate.provider
                chosen.setModel(candidate.model, for: candidate.provider)
                try self.store.save(chosen, keys: pendingKeys)
                self.draft = chosen; self.onSaved?(); self.close()
            }
            window.onClosed = { [weak self] in self?.benchmarkWindow = nil }
            benchmarkWindow = window
            beginSheet(window)
        } catch { showFeedback(TranslationFailure.credentials.localizedDescription, isError: true) }
    }
    @objc private func testTranslation() {
        guard testTask == nil else { return }
        syncDraft(); feedback.isHidden = true
        let config = draft
        let id = UUID(); testID = id
        test.title = "测试中…"; test.isEnabled = false
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let translated: String
                let sample = config.target == .english ? "更改已保存，你可以关闭这个窗口。" : "Your changes have been saved. You can close this window."
                if config.provider == .system {
                    translated = try await self.system.translate(sample, to: config.target)
                } else {
                    let key: String
                    if let edited = self.keyEdits[config.provider] { key = edited }
                    else { key = try self.store.key(for: config.provider) ?? "" }
                    guard !key.isEmpty else { throw TranslationFailure.missingKey }
                    translated = try await self.cloud.translate(sample, settings: config, key: key)
                }
                guard self.testID == id, !Task.isCancelled else { return }
                guard translated.trimmingCharacters(in: .whitespacesAndNewlines) != sample else {
                    self.showFeedback("模型返回了原文，请更换模型后重试。", isError: true)
                    self.testTask = nil; self.test.title = "测试翻译"; self.test.isEnabled = true
                    return
                }
                self.showFeedback("测试译文：" + String(translated.prefix(120)), isError: false)
            } catch {
                guard self.testID == id, !Task.isCancelled else { return }
                self.showFeedback(error.localizedDescription, isError: true)
            }
            self.testTask = nil; self.test.title = "测试翻译"; self.test.isEnabled = true
        }
    }
    private func stopTest() {
        testID = UUID(); testTask?.cancel(); testTask = nil; system.cancel()
        test.title = "测试翻译"; test.isEnabled = true
    }
    private func showFeedback(_ text: String, isError: Bool) {
        feedback.stringValue = text; feedback.textColor = isError ? .systemRed : .screenClipAccent
        feedback.isHidden = false; resizeToFit()
    }
    private func resizeToFit() {
        contentView?.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height + 44
        let top = frame.maxY
        setContentSize(NSSize(width: 460, height: max(200, height)))
        setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height))
    }
    func windowWillClose(_ notification: Notification) {
        benchmarkWindow?.close(); benchmarkWindow = nil
        stopTest(); key.stringValue = ""; keyEdits.removeAll()
    }
}
