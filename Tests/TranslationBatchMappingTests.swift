import Foundation

@main struct TranslationBatchMappingTests {
    static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)"); if !value { failures += 1 }
        }
        let reversed = try TranslationBatchMapping.ordered([("1", "第二段"), ("0", "第一段")], count: 2)
        check(reversed == ["第一段", "第二段"], "out-of-order native responses return to their own text rectangles")
        for (name, responses) in [
            ("missing", [("0", "first")]),
            ("duplicate", [("0", "first"), ("0", "second")]),
            ("unknown", [("0", "first"), ("8", "second")]),
            ("empty", [("0", "first"), ("1", " ")])
        ] {
            do { _ = try TranslationBatchMapping.ordered(responses, count: 2); check(false, "\(name) responses are rejected before rendering") }
            catch { check(true, "\(name) responses are rejected before rendering") }
        }
        if failures > 0 { exit(1) }
    }
}
