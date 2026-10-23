import AppKit

private final class SettingsCredentials: TranslationCredentials {
    var values: [TranslationProvider: String] = [:]
    func read(_ provider: TranslationProvider) throws -> String? { values[provider] }
    func write(_ value: String?, for provider: TranslationProvider) throws { values[provider] = value }
}

@main struct SettingsTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let suite = "com.local.screenclip.settings-ui-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = SettingsCredentials()
        let store = TranslationSettingsStore(defaults: defaults, credentials: credentials)
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            if value { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        func control<T: NSView>(_ window: NSWindow, label: String, as type: T.Type) -> T {
            allViews(window.contentView!).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label }!
        }
        func press(_ window: NSWindow, _ title: String) {
            allViews(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!.performClick(nil)
        }
        func select(_ window: NSWindow, _ value: TranslationProvider) {
            let picker = control(window, label: "翻译服务", as: NSPopUpButton.self)
            picker.selectItem(at: TranslationProvider.allCases.firstIndex(of: value)!)
            picker.sendAction(picker.action, to: picker.target)
        }
        let window = TranslationSettingsWindow(store: store)
        var saved = 0; window.onSaved = { saved += 1 }
        select(window, .siliconFlow)
        control(window, label: "翻译模型", as: NSComboBox.self).stringValue = "Qwen/custom-model"
        control(window, label: "API 密钥", as: NSSecureTextField.self).stringValue = "fixture-siliconflow"
        select(window, .glm)
        control(window, label: "翻译模型", as: NSComboBox.self).stringValue = "glm-4.7-flash"
        control(window, label: "API 密钥", as: NSSecureTextField.self).stringValue = "fixture-glm"
        let target = control(window, label: "目标语言", as: NSPopUpButton.self)
        target.selectItem(at: TranslationTarget.allCases.firstIndex(of: .japanese)!)
        press(window, "保存")
        check(saved == 1 && store.settings.provider == .glm && store.settings.target == .japanese,
              "the settings controls save the selected provider and language")
        check(store.settings.siliconFlowModel == "Qwen/custom-model" && credentials.values[.siliconFlow] == "fixture-siliconflow"
              && credentials.values[.glm] == "fixture-glm", "switching providers preserves both model and key drafts")
        let cancel = TranslationSettingsWindow(store: store)
        press(cancel, "删除密钥"); press(cancel, "取消")
        check(credentials.values[.glm] == "fixture-glm", "cancelling key removal preserves the stored credential")
        let remove = TranslationSettingsWindow(store: store)
        press(remove, "删除密钥"); press(remove, "保存")
        check(credentials.values[.glm] == nil && credentials.values[.siliconFlow] == "fixture-siliconflow", "saving key removal affects only the selected service")
        let invalid = TranslationSettingsWindow(store: store)
        var invalidSaves = 0; invalid.onSaved = { invalidSaves += 1 }
        control(invalid, label: "翻译模型", as: NSComboBox.self).stringValue = "bad model"
        press(invalid, "保存")
        check(invalidSaves == 0 && store.settings.glmModel == "glm-4.7-flash", "invalid settings retain the input and do not overwrite saved configuration")
        invalid.close()
        if failures > 0 { print("\(failures) settings interaction checks failed"); exit(1) }
        print("All settings interaction checks passed using isolated in-memory credentials")
    }
}
