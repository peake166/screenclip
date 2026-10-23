import Foundation

@main struct LanguageTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
        }
        check(SystemTranslationLanguage.plan("Please copy this text and open the settings.", target: .chinese) == .translate("en"),
              "ordinary English supplies an explicit source language for Chinese translation")
        check(SystemTranslationLanguage.plan("Please copy this text and open the settings.", target: .english) == .unchanged,
              "already-English text does not request an unsupported identical language pair")
        check(SystemTranslationLanguage.plan("这是一段中文，请复制文字。", target: .chinese) == .unchanged,
              "already-Chinese text can be returned without invoking the translator")
        check(SystemTranslationLanguage.plan("1234 — 5678", target: .chinese) == .unchanged,
              "numbers and punctuation never require source-language detection")
        check(SystemTranslationLanguage.plan("你好，please copy this text.", target: .chinese) != .unchanged,
              "mixed Chinese and English is not silently treated as finished Chinese")
        check(SystemTranslationLanguage.plan("こんにちは、世界。", target: .chinese) == .translate("ja"),
              "Japanese is not forced into the English source language")
        let plans = SystemTranslationLanguage.plans(["Open settings", "Translation remains in the selected area.", "123", "这是一段中文，请复制文字。"], target: .chinese)
        check(plans == [.translate("en"), .translate("en"), .unchanged, .unchanged],
              "ambiguous short headings use the screenshot language while numbers and Chinese remain unchanged")
        if failures > 0 { exit(1) }
    }
}
