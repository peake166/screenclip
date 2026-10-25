import AppKit

@MainActor private final class RecognitionGate {
    var calls = 0
    private var completion: CheckedContinuation<String, Error>?
    func run(_ image: Raster) async throws -> String {
        calls += 1
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func finish(_ value: String) { completion?.resume(returning: value); completion = nil }
}

@main struct CaptureResultTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--real") { try await realRecognition(); return }
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func pause() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        func settle(_ controller: CaptureResultController) async {
            for _ in 0..<1000 where controller.phase == .recognizing { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        func click(_ controller: CaptureResultController) {
            NSApp.sendAction(controller.copyButton.action!, to: controller.copyButton.target, from: controller.copyButton)
        }
        guard let screen = NSScreen.main else { fatalError("A logged-in desktop is required") }
        let region = CaptureRegion(screen: screen, rect: screen.visibleFrame.insetBy(dx: 120, dy: 120))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let image = Raster(width: 40, height: 30, bytes: [UInt8](repeating: 255, count: 40 * 30 * 4))
        var requests = 0
        let controller = CaptureResultController(pasteboard: board, recognize: { _ in requests += 1; return "First paragraph.\n\n第二段。" })
        defer { controller.close() }
        try ImageClipboard.copy(image, to: board)
        let png = board.data(forType: .png), initialCount = board.changeCount
        controller.show(image, region: region, message: "已复制图片", present: false)
        await pause()
        check(requests == 0 && board.changeCount == initialCount && board.data(forType: .png) == png,
              "showing ordinary screenshot actions preserves the copied image and never starts OCR")
        check(controller.panel!.frame.width <= 368 && controller.panel!.frame.height == 52,
              "screenshot actions occupy a compact strip without an image preview or backdrop")
        check(controller.panel!.styleMask.contains(.nonactivatingPanel) && controller.panel!.becomesKeyOnlyIfNeeded,
              "the copy-text action strip can be clicked without taking the original input field's focus")
        click(controller); await settle(controller)
        check(board.string(forType: .string) == "First paragraph.\n\n第二段。" && controller.phase == .copied,
              "the copy-text button writes recognized paragraphs to the private pasteboard")
        click(controller); await settle(controller)
        check(requests == 1, "copying the same text again reuses OCR instead of recognizing the screenshot twice")
        controller.close()

        let gate = RecognitionGate()
        let delayed = CaptureResultController(pasteboard: board, recognize: gate.run)
        delayed.show(image, region: region, message: "已复制长图", present: false)
        click(delayed); await pause(); click(delayed)
        check(gate.calls == 1 && !delayed.copyButton.isEnabled, "duplicate clicks never start concurrent OCR jobs")
        delayed.panel?.cancelOperation(nil); gate.finish("Must never be copied"); await pause()
        check(delayed.phase == .closed && delayed.panel == nil && board.string(forType: .string) == "First paragraph.\n\n第二段。",
              "Escape closes the strip and a cancelled recognizer cannot overwrite the clipboard later")

        let changedGate = RecognitionGate()
        let changed = CaptureResultController(pasteboard: board, recognize: changedGate.run)
        changed.show(image, region: region, message: "已复制图片", present: false)
        click(changed); await pause()
        board.clearContents(); board.setString("A newer user copy", forType: .string)
        changedGate.finish("Recognized screenshot"); await pause()
        check(board.string(forType: .string) == "A newer user copy" && changed.copyButton.isEnabled,
              "finishing OCR never silently overwrites a newer clipboard item")
        click(changed); await settle(changed)
        check(board.string(forType: .string) == "Recognized screenshot" && changedGate.calls == 1,
              "a fresh copy-text click can use the completed OCR result without repeating recognition")
        changed.close()

        var attempts = 0
        let retry = CaptureResultController(pasteboard: board, recognize: { _ in
            attempts += 1; if attempts == 1 { throw TranslationFailure.noText }; return "Retry succeeds"
        })
        retry.show(image, region: region, message: "已复制长图", present: false)
        click(retry); await settle(retry)
        check(board.string(forType: .string) == "Recognized screenshot" && retry.copyButton.isEnabled && retry.status.stringValue.contains("文字"),
              "no-text errors preserve existing clipboard data and offer a reachable retry")
        click(retry); await settle(retry)
        check(board.string(forType: .string) == "Retry succeeds" && attempts == 2, "retry recovers recognition on the same screenshot")
        retry.close()

        let replacedGate = RecognitionGate()
        let replacement = CaptureResultController(pasteboard: board, recognize: { raster in
            if raster.width == 40 { return try await replacedGate.run(raster) }
            return "Second screenshot"
        })
        replacement.show(image, region: region, message: "已复制图片", present: false)
        click(replacement); await pause()
        let second = Raster(width: 41, height: 30, bytes: [UInt8](repeating: 255, count: 41 * 30 * 4))
        replacement.show(second, region: region, message: "已复制长图", present: false)
        click(replacement); await settle(replacement); replacedGate.finish("Old screenshot"); await pause()
        check(board.string(forType: .string) == "Second screenshot", "a new capture replaces the old session and discards its late OCR result")
        replacement.close()

        let largeText = String(repeating: "Full long-image text.\n", count: 1500)
        let unlimited = CaptureResultController(pasteboard: board, recognize: { _ in largeText })
        unlimited.show(image, region: region, message: "已复制长图", present: false)
        click(unlimited); await settle(unlimited)
        check(board.string(forType: .string) == largeText.trimmingCharacters(in: .whitespacesAndNewlines),
              "text copying preserves an entire long result beyond the translation character limit")
        unlimited.close()

        let timeoutGate = RecognitionGate()
        let timeout = CaptureResultController(pasteboard: board, recognitionTimeout: 0.05, recognize: timeoutGate.run)
        timeout.show(image, region: region, message: "已复制图片", present: false)
        click(timeout); await pause(); timeoutGate.finish("Too late"); await pause()
        check(timeout.status.stringValue.contains("超时") && timeout.copyButton.isEnabled && board.string(forType: .string) == largeText.trimmingCharacters(in: .whitespacesAndNewlines),
              "recognition has a bounded timeout and late completion cannot replace clipboard contents")
        timeout.close()

        let idle = CaptureResultController(pasteboard: board, dismissAfter: 0.05, recognize: { _ in "Unused" })
        idle.show(image, region: region, message: "已复制图片", present: false); await pause()
        check(idle.panel == nil && idle.phase == .closed, "an unused action strip automatically closes")
        for visible in [CGRect(x: 0, y: 25, width: 900, height: 700), CGRect(x: -1440, y: -800, width: 1440, height: 875)] {
            for rect in [visible, CGRect(x: visible.minX, y: visible.minY, width: 30, height: 20)] {
                check(visible.contains(CaptureResultController.toolbarFrame(near: rect, visible: visible)),
                      "the toolbar stays within visible bounds even on a display with negative coordinates")
            }
        }
        if failures > 0 { exit(1) }
        print("Capture result checks passed using synthetic screenshots and a private pasteboard")
    }

    @MainActor static func realRecognition() async throws {
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func fixture(height: Int, lines: [(String, Int)]) throws -> Raster {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 900, height: height).fill()
            for (text, top) in lines {
                (text as NSString).draw(at: CGPoint(x: 32, y: height - top - 50), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black
                ])
            }
            NSGraphicsContext.restoreGraphicsState(); return try Raster(rep.cgImage!)
        }
        guard let screen = NSScreen.main else { fatalError("A logged-in desktop is required") }
        let region = CaptureRegion(screen: screen, rect: screen.visibleFrame.insetBy(dx: 120, dy: 120))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let small = try fixture(height: 320, lines: [("Copy text from screenshots", 30), ("截图取字，无需翻译", 160)])
        let long = try fixture(height: 2600, lines: [("Start of long screenshot", 30), ("Middle of long screenshot", 1780), ("End of long screenshot", 2480)])
        let controller = CaptureResultController(pasteboard: board); defer { controller.close() }
        for (image, markers) in [(small, ["Copy text", "截图取字"]), (long, ["Start of long", "Middle of long", "End of long"])] {
            try ImageClipboard.copy(image, to: board)
            controller.show(image, region: region, message: "已复制图片", present: false)
            NSApp.sendAction(controller.copyButton.action!, to: controller.copyButton.target, from: controller.copyButton)
            // A cold Vision launch under compiler load can exceed 30 seconds.
            // Follow the production 120-second deadline instead of failing an in-flight request early.
            let started = Date(), deadline = Date().addingTimeInterval(125)
            while controller.phase == .recognizing, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            print("Native \(image.width)x\(image.height) recognition elapsed: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            let text = board.string(forType: .string) ?? ""
            if controller.phase != .copied || !markers.allSatisfy({ text.contains($0) }) {
                print("Generated fixture recognition: \(text); phase: \(controller.phase)")
            }
            check(controller.phase == .copied && markers.allSatisfy { text.contains($0) },
                  "the real Vision path copies \(image.height > 1800 ? "all tiles of a long screenshot" : "Chinese and English screenshot text")")
            if image.height > 1800 {
                let positions = markers.compactMap { text.range(of: $0)?.lowerBound }
                check(positions.count == 3 && positions == positions.sorted(), "long-image markers retain their top-to-bottom reading order")
            }
            controller.close()
        }
        do {
            _ = try TextRecognizer.recognizeDocumentImage(small.cgImage(), maximumCharacters: 4)
            check(false, "translation OCR retains its configurable text limit")
        } catch TranslationFailure.tooLong { check(true, "translation OCR retains its configurable text limit") }
        let folder = URL(fileURLWithPath: ".build/previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            controller.show(small, region: region, message: "已复制图片", present: false)
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let view = controller.panel!.contentView!; controller.panel!.appearance = appearance; view.appearance = appearance
            view.layoutSubtreeIfNeeded()
            let rect = controller.copyButton.convert(controller.copyButton.bounds, to: view)
            check(view.bounds.contains(rect) && rect.width >= controller.copyButton.intrinsicContentSize.width,
                  "the \(dark ? "dark" : "light") copy-text button remains visible and unclipped")
            let hit = view.hitTest(NSPoint(x: rect.midX, y: rect.midY))
            check(hit === controller.copyButton || hit?.isDescendant(of: controller.copyButton) == true,
                  "the glass surface delivers actual hit tests to the copy-text button")
            let close = view.subviews.flatMap { $0.subviews }.first { $0.toolTip == "关闭（Esc）" }
            check(close.map { $0.convert($0.bounds, to: view).maxX >= view.bounds.maxX - 16 } == true,
                  "the close control stays at the trailing edge without unused toolbar space")
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("capture-result-\(dark ? "dark" : "light").png"))
            controller.close()
        }
        if failures > 0 { exit(1) }
        print("Real text-copy flow passed with local Vision, generated image pixels and a private pasteboard; no API requests")
    }
}
