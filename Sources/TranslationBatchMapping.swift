import Foundation

enum TranslationBatchMapping {
    enum Problem: LocalizedError {
        case mismatch
        var errorDescription: String? { "翻译结果与文字区域不匹配，请重试。" }
    }
    static func ordered(_ responses: [(String?, String)], count: Int) throws -> [String] {
        guard responses.count == count else { throw Problem.mismatch }
        var values = Array(repeating: "", count: count)
        var seen = Set<Int>()
        for (id, text) in responses {
            guard let id, let index = Int(id), (0..<count).contains(index), seen.insert(index).inserted,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem.mismatch }
            values[index] = text
        }
        return values
    }
}
