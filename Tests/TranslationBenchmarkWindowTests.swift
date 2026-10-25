import AppKit

private final class BenchmarkWindowCredentials: TranslationCredentials {
    var values: [TranslationProvider: String] = [.siliconFlow: "fixture-silicon", .glm: "fixture-glm"]
    var refuseWrite = false
    func read(_ provider: TranslationProvider) throws -> String? { values[provider] }
    func write(_ value: String?, for provider: TranslationProvider) throws {
        if refuseWrite { throw TranslationFailure.credentials }
        values[provider] = value
    }
}

private actor BenchmarkWindowFixture {
    var calls = 0, cancellations = 0
    let slow: Bool
    init(slow: Bool = false) { self.slow = slow }
    func translate(_ text: String, _ settings: TranslationSettings, _ key: String) async throws -> String {
        calls += 1
        if slow {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { cancellations += 1; throw error }
        }
        if settings.model(for: settings.provider) == "THUDM/GLM-4-9B-0414" { throw TranslationFailure.rejected(404) }
        return "界面验证示例：会议将于周五上午十点开始。请查看更新后的计划，并在明天之前提出反馈。\n\n新版本会保留原有设置。"
    }
}

@main struct TranslationBenchmarkWindowTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let suite = "com.local.screenclip.benchmark-ui." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previews = URL(fileURLWithPath: ".build/benchmark-ui-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let credentials = BenchmarkWindowCredentials()
        let store = TranslationSettingsStore(defaults: defaults, credentials: credentials)
        var original = TranslationSettings(); original.siliconFlowModel = "fixture-custom"; original.target = .japanese
        try store.save(original)
        defaults.set(Data("fixture-original-shortcuts".utf8), forKey: "captureShortcuts.v1")
        let before = credentials.values
        let fixture = BenchmarkWindowFixture()
        let window = TranslationSettingsWindow(store: store, benchmarkTranslator: { try await fixture.translate($0, $1, $2) })
        defer { window.close() }
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func press(_ window: NSWindow, _ title: String) {
            all(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!.performClick(nil)
        }
        func control<T: NSView>(_ window: NSWindow, _ label: String, _ type: T.Type) -> T {
            all(window.contentView!).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label }!
        }
        func select(_ window: TranslationBenchmarkWindow, model: String) {
            let table = control(window, "模型翻译测速结果", NSTableView.self)
            let row = (0..<table.numberOfRows).first { index in
                guard let cell = window.tableView(table, viewFor: table.tableColumns[0], row: index) else { return false }
                return all(cell).compactMap { $0 as? NSTextField }.contains { $0.stringValue == model }
            }!
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let button = all(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "模型测速…" }
        guard button != nil else { print("FAIL translation settings provides a reachable model benchmark action"); exit(1) }
        print("PASS translation settings provides a reachable model benchmark action")
        guard credentials.values == before else { print("FAIL opening settings changes no saved API keys"); exit(1) }
        print("PASS opening settings changes no saved API keys")
        press(window, "模型测速…")
        guard let sheet = window.attachedSheet as? TranslationBenchmarkWindow else { fatalError("Benchmark sheet is unreachable") }
        let initialCalls = await fixture.calls
        check(sheet.benchmark.entries.count == 7 && initialCalls == 0,
              "opening the reachable sheet lists all configured models without sending a request")
        let use = control(sheet, "使用选中的测速模型", NSButton.self)
        check(!use.isEnabled, "an untested model cannot be selected as a measured result")
        var saves = 0; window.onSaved = { saves += 1 }
        press(sheet, "开始测速"); await sheet.benchmark.waitUntilFinished()
        let calls = await fixture.calls
        check(calls == 7 && sheet.benchmark.completedCount == 7, "the start control reaches the full benchmark and publishes each result")
        select(sheet, model: "THUDM/GLM-4-9B-0414")
        check(!use.isEnabled && control(sheet, "测速内容预览", NSTextView.self).string.contains("模型不可用"),
              "a failed row shows its recovery reason and cannot be applied")
        select(sheet, model: "glm-4.7-flash")
        check(use.isEnabled && control(sheet, "测速内容预览", NSTextView.self).string.contains("界面验证示例"),
              "a successful row exposes its full sample translation and can be selected")
        for dark in [false, true] {
            sheet.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            sheet.contentView!.layoutSubtreeIfNeeded()
            let controls = all(sheet.contentView!).filter { ($0 is NSButton || $0 is NSSegmentedControl || $0 is NSScrollView) && !$0.isHiddenOrHasHiddenAncestor }
            check(controls.allSatisfy { sheet.contentView!.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: sheet.contentView!)) },
                  "benchmark controls fit inside the compact \(dark ? "dark" : "light") window")
            let bitmap = sheet.contentView!.bitmapImageRepForCachingDisplay(in: sheet.contentView!.bounds)!
            sheet.contentView!.cacheDisplay(in: sheet.contentView!.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: previews.appendingPathComponent("benchmark-\(dark ? "dark" : "light").png"))
        }
        press(sheet, "使用此模型")
        check(saves == 1 && store.settings.provider == .glm && store.settings.glmModel == "glm-4.7-flash"
              && store.settings.target == .japanese && store.settings.siliconFlowModel == "fixture-custom",
              "using a successful model saves it immediately while preserving the target and other model")
        check(credentials.values == before && defaults.data(forKey: "captureShortcuts.v1") == Data("fixture-original-shortcuts".utf8),
              "applying a measured model preserves both API keys and all shortcuts")

        let slow = BenchmarkWindowFixture(slow: true)
        let stopping = TranslationSettingsWindow(store: store, benchmarkTranslator: { try await slow.translate($0, $1, $2) })
        press(stopping, "模型测速…")
        let active = stopping.attachedSheet as! TranslationBenchmarkWindow
        press(active, "开始测速")
        for _ in 0..<100 { if await slow.calls > 0 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        active.close(); await active.benchmark.waitUntilFinished()
        let stoppedCalls = await slow.calls, cancellations = await slow.cancellations
        check(stoppedCalls == 1 && cancellations == 1 && !active.benchmark.isRunning && stopping.attachedSheet == nil,
              "closing the sheet cancels its real task and prevents remaining model requests")
        stopping.close()

        let emptyCredentials = BenchmarkWindowCredentials(); emptyCredentials.values = [:]
        let emptyStore = TranslationSettingsStore(defaults: defaults, credentials: emptyCredentials)
        let empty = TranslationSettingsWindow(store: emptyStore)
        press(empty, "模型测速…")
        let emptySheet = empty.attachedSheet as! TranslationBenchmarkWindow
        check(emptySheet.benchmark.entries.isEmpty && !control(emptySheet, "开始或停止模型测速", NSButton.self).isEnabled,
              "missing API keys produce a clear empty state with no runnable requests")
        empty.close()

        let saveFailure = TranslationSettingsWindow(store: store, benchmarkTranslator: { try await fixture.translate($0, $1, $2) })
        control(saveFailure, "API 密钥", NSSecureTextField.self).stringValue = "fixture-edited-key"
        press(saveFailure, "模型测速…")
        let failureSheet = saveFailure.attachedSheet as! TranslationBenchmarkWindow
        press(failureSheet, "开始测速"); await failureSheet.benchmark.waitUntilFinished()
        select(failureSheet, model: "glm-4.7-flash")
        credentials.refuseWrite = true
        let savedBeforeFailure = store.settings
        press(failureSheet, "使用此模型")
        let message = control(failureSheet, "测速操作状态", NSTextField.self)
        check(store.settings == savedBeforeFailure && credentials.values == before && saveFailure.attachedSheet === failureSheet
              && !message.isHidden && message.stringValue.contains("钥匙串"),
              "a failed credential save preserves configuration and keeps a recoverable result window open")
        failureSheet.contentView!.layoutSubtreeIfNeeded()
        check(failureSheet.contentView!.bounds.contains(message.convert(message.bounds, to: failureSheet.contentView!)),
              "a save error expands the result window without clipping its recovery message")
        credentials.refuseWrite = false; saveFailure.close()
        if failures > 0 { print("\(failures) benchmark UI checks failed"); exit(1) }
        print("Benchmark UI checks passed with synthetic responses and isolated credentials; no desktop preview opened")
    }
}
