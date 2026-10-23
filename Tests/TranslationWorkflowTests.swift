import Foundation

@main struct WorkflowTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            if value { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        func settled(_ job: TranslationWorkflow) async {
            for _ in 0..<100 where job.phase.isBusy { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        let raster = Raster(width: 1, height: 1, bytes: [0, 0, 0, 255])
        var recognitionCount = 0, calls: [String] = [], failSecond = true
        let source = String(repeating: "A", count: 2000) + "Final paragraph."
        let job = TranslationWorkflow(recognize: { _ in recognitionCount += 1; return source }, translate: { text, _ in
            calls.append(text)
            if text == "Final paragraph." && failSecond { throw TranslationFailure.network }
            return text == "Final paragraph." ? "末段。" : "第一段。"
        })
        job.begin(raster, settings: TranslationSettings()); await settled(job)
        check(job.original == source && job.translated == "第一段。", "a failed later chunk retains original text and completed translation")
        check(!job.phase.isBusy && calls.count == 2, "a provider failure stops without automatic retry")
        failSecond = false; job.retry(); await settled(job)
        check(job.phase == .finished && job.translated == "第一段。\n\n末段。", "manual retry completes the remaining translation")
        check(recognitionCount == 1 && calls.count == 3 && calls.last == "Final paragraph.", "retry does not repeat OCR or already-paid chunks")
        var releaseOld: CheckedContinuation<String, Error>?
        let delayed = TranslationWorkflow(recognize: { _ in "hello" }, translate: { _, config in
            if config.target == .chinese { return try await withCheckedThrowingContinuation { releaseOld = $0 } }
            return "new result"
        })
        delayed.begin(raster, settings: TranslationSettings())
        for _ in 0..<100 where releaseOld == nil { await Task.yield() }
        delayed.cancel()
        var next = TranslationSettings(); next.target = .english
        delayed.begin(raster, settings: next); await settled(delayed)
        releaseOld?.resume(returning: "old result"); await Task.yield()
        check(delayed.translated == "new result" && delayed.phase == .finished, "late results from a cancelled job never overwrite a newer translation")
        var emptyCalls = 0
        let empty = TranslationWorkflow(recognize: { _ in "\n " }, translate: { _, _ in emptyCalls += 1; return "invalid" })
        empty.begin(raster, settings: TranslationSettings()); await settled(empty)
        check(emptyCalls == 0 && empty.phase != .finished, "an empty screenshot never reaches a cloud translation service")
        var stalled: CheckedContinuation<String, Error>?
        var timedRecognitions = 0, timedCalls = 0
        let timed = TranslationWorkflow(recognize: { _ in timedRecognitions += 1; return "Recognized text" }, translate: { _, _ in
            timedCalls += 1
            if timedCalls > 1 { return "Recovered" }
            return try await withCheckedThrowingContinuation { stalled = $0 }
        })
        timed.begin(raster, settings: TranslationSettings())
        for _ in 0..<100 where stalled == nil { await Task.yield() }
        timed.expireCurrentStage()
        check(!timed.phase.isBusy && timed.original == "Recognized text", "a stalled translation exits busy state and preserves the recognized text")
        stalled?.resume(returning: "late after timeout")
        await Task.yield()
        check(timed.translated.isEmpty && timed.phase != .finished, "a result arriving after timeout cannot become a success")
        timed.retry(); await settled(timed)
        check(timed.phase == .finished && timed.translated == "Recovered" && timedRecognitions == 1,
              "manual retry after a timeout reuses the recognized text")
        var stalledOCR: CheckedContinuation<String, Error>?
        let timedOCR = TranslationWorkflow(recognize: { _ in
            try await withCheckedThrowingContinuation { stalledOCR = $0 }
        }, translate: { _, _ in "unused" })
        timedOCR.begin(raster, settings: TranslationSettings())
        for _ in 0..<100 where stalledOCR == nil { await Task.yield() }
        timedOCR.expireCurrentStage()
        check(!timedOCR.phase.isBusy && timedOCR.original.isEmpty, "a stalled recognizer also exits busy state")
        stalledOCR?.resume(returning: "late OCR")
        await Task.yield()
        var automaticStall: CheckedContinuation<String, Error>?
        let automaticTimeout = TranslationWorkflow(translationTimeout: 0.025, recognize: { _ in "hello" }, translate: { _, _ in
            try await withCheckedThrowingContinuation { automaticStall = $0 }
        })
        automaticTimeout.begin(raster, settings: TranslationSettings()); await settled(automaticTimeout)
        check(!automaticTimeout.phase.isBusy && automaticTimeout.original == "hello" && automaticTimeout.phase != .finished,
              "the real deadline fires even when the provider ignores cancellation")
        automaticStall?.resume(returning: "late"); await Task.yield()
        var preparingStall: CheckedContinuation<String, Error>?
        let preparing = TranslationWorkflow(translationTimeout: 0.025, recognize: { _ in "hello" }, translate: { _, _ in
            try await withCheckedThrowingContinuation { preparingStall = $0 }
        })
        preparing.begin(raster, settings: TranslationSettings())
        for _ in 0..<100 where preparingStall == nil { await Task.yield() }
        preparing.preparingLanguage(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(preparing.phase == .preparingLanguage && preparing.original == "hello",
              "language download preparation gets its own deadline and retains original text")
        preparing.clear(); preparingStall?.resume(returning: "late"); await Task.yield()
        check(preparing.phase == .idle && preparing.original.isEmpty,
              "closing during language preparation cancels the pending result")
        // Cloud requests deliberately complete in a different order than their OCR blocks.
        func until(_ condition: () -> Bool) async {
            for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        func makeDocument(_ texts: [String], ids: [Int]? = nil) -> OCRDocument {
            OCRDocument(imageSize: CGSize(width: 800, height: 800), blocks: texts.enumerated().map {
                OCRBlock(id: ids?[$0.offset] ?? $0.offset, text: $0.element,
                         lines: [CGRect(x: 10, y: 10 + $0.offset * 80, width: 600, height: 30)])
            })
        }
        var cloud = TranslationSettings(); cloud.provider = .glm
        let orderGate = WorkflowRequestGate()
        let ordered = TranslationWorkflow(recognizeLayout: { _ in makeDocument(["first", "second", "third"], ids: [80, 3, 44]) },
            translate: { try await orderGate.request($0, settings: $1) })
        ordered.begin(raster, settings: cloud)
        await until { orderGate.started.count >= 2 }
        check(orderGate.started.count == 2 && orderGate.maximumActive == 2,
              "cloud translation starts two requests and never fills a third occupied slot")
        if orderGate.started.count == 2 {
            orderGate.succeed("zh-Hans:second", "第二")
            await until { orderGate.started.count == 3 }
            check(ordered.translatedBlocks == [3: "第二"], "an out-of-order cloud result is shown at its original block immediately")
            orderGate.succeed("zh-Hans:third", "第三")
            await until { ordered.translatedBlocks[44] != nil }
            orderGate.succeed("zh-Hans:first", "第一")
            await settled(ordered)
            check(ordered.phase == .finished && ordered.translated == "第一\n\n第二\n\n第三"
                  && ordered.translatedBlocks == [80: "第一", 3: "第二", 44: "第三"] && orderGate.maximumActive == 2,
                  "cloud results retain OCR order and nonsequential block identities despite reverse completion")
        } else { ordered.cancel(); orderGate.releaseAll() }

        var partialOCR = 0
        let partialGate = WorkflowRequestGate()
        let partial = TranslationWorkflow(recognizeLayout: { _ in partialOCR += 1; return makeDocument(["one", "two", "three", "four"]) },
            translate: { try await partialGate.request($0, settings: $1) })
        partial.begin(raster, settings: cloud); await until { partialGate.started.count >= 2 }
        if partialGate.started.count == 2 {
            partialGate.fail("zh-Hans:one"); await Task.yield()
            partialGate.succeed("zh-Hans:two", "二"); await settled(partial)
            check(partial.translatedBlocks == [1: "二"] && partialGate.started.count == 2 && !partial.phase.isBusy,
                  "a failed cloud piece stops new requests while another in-flight success is retained")
            partial.retry(); await until { partialGate.started.count >= 4 }
            check(partialGate.started.filter { $0 == "zh-Hans:two" }.count == 1 && partialOCR == 1,
                  "retry skips successful out-of-order requests and does not repeat recognition")
            partialGate.succeed("zh-Hans:three", "三"); await until { partialGate.started.count >= 5 }
            partialGate.succeed("zh-Hans:four", "四"); partialGate.succeed("zh-Hans:one", "一")
            await settled(partial)
            check(partial.phase == .finished && partial.translated == "一\n\n二\n\n三\n\n四"
                  && partialGate.started.count == 5 && partialGate.maximumActive == 2,
                  "manual cloud retry requests only failed and unstarted pieces and restores complete source order")
        } else { check(false, "cloud partial-failure test can reach both in-flight pieces"); partial.cancel(); partialGate.releaseAll() }

        let limitedGate = WorkflowRequestGate()
        let limited = TranslationWorkflow(recognizeLayout: { _ in makeDocument(["rate-one", "rate-two", "rate-three"]) },
            translate: { try await limitedGate.request($0, settings: $1) })
        limited.begin(raster, settings: cloud); await until { limitedGate.started.count == 2 }
        limitedGate.fail("zh-Hans:rate-one", error: TranslationFailure.rejected(429))
        await Task.yield(); limitedGate.succeed("zh-Hans:rate-two", "二"); await settled(limited)
        check(!limited.phase.isBusy && limitedGate.started.count == 2 && limited.translatedBlocks == [1: "二"],
              "rate limiting preserves in-flight successes and never retries automatically")
        limited.retry(); await until { limitedGate.started.count >= 3 }
        for _ in 0..<10 { await Task.yield() }
        check(limitedGate.started.count == 3 && limitedGate.started.last == "zh-Hans:rate-one",
              "manual retry after a 429 reduces cloud concurrency to one")
        limitedGate.succeed("zh-Hans:rate-one", "一"); await until { limitedGate.started.count == 4 }
        limitedGate.succeed("zh-Hans:rate-three", "三"); await settled(limited)
        check(limited.phase == .finished && limited.translated == "一\n\n二\n\n三" && limitedGate.started.count == 4,
              "a serial rate-limit retry finishes missing pieces without repeating the successful piece")

        let longHead = String(repeating: "L", count: 2_000), longTail = "long block tail"
        let longGate = WorkflowRequestGate()
        let longJob = TranslationWorkflow(recognizeLayout: { _ in makeDocument([longHead + longTail, "short block"], ids: [91, 7]) },
            translate: { try await longGate.request($0, settings: $1) })
        longJob.begin(raster, settings: cloud); await until { longGate.started.count >= 2 }
        if longGate.started.count == 2 {
            longGate.succeed("zh-Hans:" + longTail, "长段尾"); await until { longGate.started.count == 3 }
            check(longJob.translatedBlocks[91] == nil, "a multi-piece OCR block is not displayed until all its pieces succeed")
            longGate.succeed("zh-Hans:short block", "短段"); await until { longJob.translatedBlocks[7] != nil }
            longGate.succeed("zh-Hans:" + longHead, "长段首"); await settled(longJob)
            check(longJob.translatedBlocks == [91: "长段首\n长段尾", 7: "短段"] && longJob.phase == .finished,
                  "long OCR blocks reassemble their chunks in source order without borrowing another block's result")
        } else { check(false, "long-block cloud test can start two chunks"); longJob.cancel(); longGate.releaseAll() }

        // Cancellation-ignoring providers must still occupy their original slots until they actually return.
        for retranslate in [false, true] {
            let cancelGate = WorkflowRequestGate()
            let cancelled = TranslationWorkflow(recognizeLayout: { _ in makeDocument(["old-one", "old-two", "old-three"]) },
                translate: { try await cancelGate.request($0, settings: $1) })
            cancelled.begin(raster, settings: cloud); await until { cancelGate.started.count >= 2 }
            if cancelGate.started.count == 2 {
                var replacement = cloud; replacement.target = .english
                if retranslate { cancelled.retranslate(settings: replacement) }
                else { cancelled.cancel(); cancelled.begin(raster, settings: replacement) }
                for _ in 0..<10 { await Task.yield() }
                check(cancelGate.started.count == 2, "\(retranslate ? "retranslate" : "cancel and begin") waits for occupied cancelled request slots")
                cancelGate.succeed("zh-Hans:old-one", "stale first")
                await until { cancelGate.started.contains("en:old-one") }
                cancelGate.succeed("zh-Hans:old-two", "stale second")
                await until { cancelGate.started.contains("en:old-two") }
                check(cancelled.translated.isEmpty && cancelled.translatedBlocks.isEmpty && cancelGate.maximumActive == 2,
                      "late cancelled results cannot populate a new generation or exceed two global cloud requests")
                cancelGate.succeed("en:old-two", "new second")
                await until { cancelGate.started.contains("en:old-three") }
                cancelGate.succeed("en:old-three", "new third"); cancelGate.succeed("en:old-one", "new first")
                await settled(cancelled)
                check(cancelled.phase == .finished && cancelled.translated == "new first\n\nnew second\n\nnew third"
                      && !cancelGate.started.contains("zh-Hans:old-three") && cancelGate.maximumActive == 2,
                      "\(retranslate ? "retranslation" : "new translation") completes without old-generation queued work")
            } else { check(false, "cancellation test starts two cloud requests"); cancelled.cancel(); cancelGate.releaseAll() }
        }

        // The system provider remains serial, with batches capped at eight pieces.
        var batchInputs: [[String]] = [], activeBatches = 0, maximumBatches = 0, singleSystemCalls = 0
        let systemGate = WorkflowBatchGate()
        let systemDoc = makeDocument((0..<18).map { "system-\($0)" })
        let serialSystem = TranslationWorkflow(recognizeLayout: { _ in systemDoc },
            translate: { _, _ in singleSystemCalls += 1; return "unexpected" },
            translateBatch: { values, _ in
                batchInputs.append(values); activeBatches += 1; maximumBatches = max(maximumBatches, activeBatches)
                await systemGate.wait(); activeBatches -= 1
                return values.map { "译" + $0 }
            })
        serialSystem.begin(raster, settings: TranslationSettings()); await until { batchInputs.count == 1 }
        check(batchInputs.map(\.count) == [8] && maximumBatches == 1, "system translation begins one batch of eight")
        systemGate.release(); await until { batchInputs.count == 2 }
        check(batchInputs.map(\.count) == [8, 8] && maximumBatches == 1, "system translation starts its second batch only after the first finishes")
        systemGate.release(); await until { batchInputs.count == 3 }
        systemGate.release(); await settled(serialSystem)
        check(serialSystem.phase == .finished && batchInputs.map(\.count) == [8, 8, 2]
              && maximumBatches == 1 && singleSystemCalls == 0 && serialSystem.translatedBlocks.count == 18,
              "system batch size, serial execution, and original block mapping are preserved")
        if failures > 0 { print("\(failures) workflow checks failed"); exit(1) }
        print("All translation workflow checks passed")
    }
}


@MainActor private final class WorkflowRequestGate {
    private(set) var started: [String] = []
    private(set) var maximumActive = 0
    private var active = 0
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    func request(_ text: String, settings: TranslationSettings) async throws -> String {
        let key = settings.target.rawValue + ":" + text
        started.append(key); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { pending[key] = $0 }
    }
    func succeed(_ key: String, _ result: String) { pending.removeValue(forKey: key)?.resume(returning: result) }
    func fail(_ key: String, error: Error = TranslationFailure.network) { pending.removeValue(forKey: key)?.resume(throwing: error) }
    func releaseAll() {
        let values = Array(pending.values); pending.removeAll()
        for continuation in values { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor private final class WorkflowBatchGate {
    private var pending: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { pending = $0 } }
    func release() { let continuation = pending; pending = nil; continuation?.resume() }
}
