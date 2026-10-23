import Foundation
import NaturalLanguage

enum SystemLanguagePlan: Equatable {
    case unchanged, translate(String), automatic
}

enum SystemTranslationLanguage {
    static func plans(_ texts: [String], target: TranslationTarget) -> [SystemLanguagePlan] {
        let individual = texts.map { plan($0, target: target) }
        let context = plan(texts.joined(separator: "\n\n"), target: target)
        let source: String?
        if case .translate(let language) = context { source = language }
        else {
            var weights: [String: Int] = [:]
            for (index, value) in individual.enumerated() {
                if case .translate(let language) = value { weights[language, default: 0] += texts[index].count }
            }
            source = weights.max(by: { $0.value < $1.value })?.key
        }
        return individual.map {
            if $0 == .automatic, let source { return .translate(source) }
            return $0
        }
    }
    static func plan(_ text: String, target: TranslationTarget) -> SystemLanguagePlan {
        guard text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return .unchanged }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.45 else { return .automatic }
        let source = language.rawValue
        let targetCode = target.rawValue
        let same = source == targetCode || (source.split(separator: "-").first == targetCode.split(separator: "-").first && !source.hasPrefix("zh"))
        if same {
            let hasLatin = text.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
            let hasCJK = text.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) || (0x3400...0x9fff).contains($0.value) || (0xac00...0xd7af).contains($0.value) }
            // Mixed scripts need translation even when the dominant language matches the target.
            if hasLatin && hasCJK { return .automatic }
            return .unchanged
        }
        return .translate(source)
    }
}
