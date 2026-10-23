import Foundation

@main struct InPlaceWorkflowTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)"); if !value { failures += 1 }
        }
        func settled(_ job: TranslationWorkflow) async {
            for _ in 0..<200 where job.phase.isBusy { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        let image = Raster(width: 1, height: 1, bytes: [255, 255, 255, 255])
        let doc = OCRDocument(imageSize: CGSize(width: 800, height: 400), blocks: [
            OCRBlock(id: 8, text: "First paragraph", lines: [CGRect(x: 20, y: 30, width: 300, height: 20)]),
            OCRBlock(id: 3, text: "Second paragraph", lines: [CGRect(x: 20, y: 120, width: 300, height: 20)])
        ])
        var ocrCalls = 0, calls: [String] = [], fail = true
        let job = TranslationWorkflow(recognizeLayout: { _ in ocrCalls += 1; return doc }, translate: { text, _ in
            calls.append(text)
            if text == "Second paragraph", fail { throw TranslationFailure.network }
            return text == "First paragraph" ? "第一段" : "第二段"
        })
        var cloud = TranslationSettings(); cloud.provider = .glm
        job.begin(image, settings: cloud); await settled(job)
        check(job.document == doc, "OCR positions survive through the translation workflow")
        check(job.translatedBlocks == [8: "第一段"], "completed translations stay attached to their original block when another block fails")
        fail = false; job.retry(); await settled(job)
        check(job.translatedBlocks == [8: "第一段", 3: "第二段"] && job.phase == .finished,
              "retry fills the failed block without moving or replacing successful translations")
        check(ocrCalls == 1 && calls == ["First paragraph", "Second paragraph", "Second paragraph"],
              "retry never repeats OCR or successful paid requests")
        var batches = 0, singles = 0
        let native = TranslationWorkflow(recognizeLayout: { _ in doc }, translate: { _, _ in singles += 1; return "wrong" },
            translateBatch: { texts, _ in batches += 1; return texts.map { $0 == "First paragraph" ? "首段" : "次段" } })
        native.begin(image, settings: TranslationSettings()); await settled(native)
        check(batches == 1 && singles == 0 && native.translatedBlocks == [8: "首段", 3: "次段"],
              "system translation batches multiple blocks while retaining their identities")
        native.clear()
        check(native.document == nil && native.translatedBlocks.isEmpty, "closing clears screenshot geometry and translated text")
        if failures > 0 { exit(1) }
    }
}
