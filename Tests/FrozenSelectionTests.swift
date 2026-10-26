import AppKit

@MainActor private final class SnapshotGate {
    var calls = 0
    private var continuation: CheckedContinuation<[FrozenScreenFrame], Error>?
    func capture(_ screens: [NSScreen]) async throws -> [FrozenScreenFrame] {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ frames: [FrozenScreenFrame]) { continuation?.resume(returning: frames); continuation = nil }
}

private final class WeakFrozenImage {
    weak var image: CGImage?
    init(_ image: CGImage) { self.image = image }
}

@main struct FrozenSelectionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func pause() async { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let screen = NSScreen.main, let id = FrozenScreenCapture.displayID(screen) else { fatalError("A logged-in desktop is required") }
        let image = try Raster(width: 64, height: 48, bytes: [UInt8](repeating: 220, count: 64 * 48 * 4)).cgImage()
        let frame = FrozenScreenFrame(displayID: id, screenFrame: screen.frame, image: image)
        let gate = SnapshotGate(), pending = SelectionController(screens: { [screen] }, presentWindows: false, captureSnapshots: gate.capture)
        var cancelled = 0
        pending.begin(scrolling: false) { result in if case .success(nil) = result { cancelled += 1 } }
        await pause()
        check(gate.calls == 1 && pending.windows.isEmpty, "freezing starts before any selection window is created or receives focus")
        pending.cancel(); gate.finish([frame]); await pause()
        check(cancelled == 1 && pending.windows.isEmpty, "cancelling during preparation ignores the late frozen frame and never opens an overlay")

        var requests = 0
        let selection = SelectionController(screens: { [screen] }, presentWindows: false, captureSnapshots: { _ in requests += 1; return [frame] })
        var result: CaptureSelection?
        selection.begin(scrolling: false) { value in if case .success(let chosen) = value { result = chosen } }
        await pause()
        if let view = selection.windows.first?.contentView as? SelectionView {
            view.onComplete?(CGRect(x: screen.frame.width / 4, y: screen.frame.height / 4, width: screen.frame.width / 2, height: screen.frame.height / 2))
        }
        check(requests == 1 && result?.image?.width == 32 && result?.image?.height == 24,
              "a static selection returns pixels cropped from its one pre-selection snapshot")
        check(result?.image?.bytes.count == 32 * 24 * 4 && selection.windows.isEmpty,
              "only selected pixels leave the picker; the fullscreen snapshot is not passed to OCR or the clipboard")
        selection.cancel()
        let before = requests
        selection.begin(scrolling: true) { _ in }
        check(requests == before && selection.windows.count == 1, "scrolling selection remains live and does not freeze the desktop")
        selection.cancel()

        let timeoutGate = SnapshotGate()
        let timeout = SelectionController(screens: { [screen] }, presentWindows: false, preparationTimeout: 0.03, captureSnapshots: timeoutGate.capture)
        var timeouts = 0
        timeout.begin(scrolling: false) { result in
            if case .failure(let error) = result, error.localizedDescription.contains("超时") { timeouts += 1 }
        }
        await pause(); timeoutGate.finish([frame]); await pause()
        check(timeouts == 1 && timeout.windows.isEmpty, "a stalled snapshot times out once and its late result cannot display an overlay")

        var attempts = 0, errors = 0
        let recover = SelectionController(screens: { [screen] }, presentWindows: false, captureSnapshots: { _ in
            attempts += 1; if attempts == 1 { throw CaptureError.invalidImage }; return [frame]
        })
        recover.begin(scrolling: false) { if case .failure = $0 { errors += 1 } }
        await pause()
        check(errors == 1 && recover.windows.isEmpty, "a snapshot failure reports its error without displaying selection windows")
        recover.begin(scrolling: false) { _ in }; await pause()
        check(attempts == 2 && recover.windows.count == 1, "a failed snapshot leaves the next shortcut free to start normally")
        recover.cancel()

        let oldGate = SnapshotGate(); var starts = 0, oldCancelled = 0
        let replacementImage = try Raster(width: 64, height: 48, bytes: [UInt8](repeating: 255, count: 64 * 48 * 4)).cgImage()
        let replacementFrame = FrozenScreenFrame(displayID: id, screenFrame: screen.frame, image: replacementImage)
        let replacement = SelectionController(screens: { [screen] }, presentWindows: false, captureSnapshots: { screens in
            starts += 1
            if starts == 1 { return try await oldGate.capture(screens) }
            return [replacementFrame]
        })
        replacement.begin(scrolling: false) { if case .success(nil) = $0 { oldCancelled += 1 } }; await pause()
        replacement.begin(scrolling: false) { _ in }; await pause(); oldGate.finish([frame]); await pause()
        check(oldCancelled == 1 && starts == 2 && (replacement.windows.first?.contentView as? SelectionView)?.frozenImage === replacementImage,
              "restarting selection discards the old pending capture without replacing the new frozen screen")
        replacement.cancel()

        let changedDisplay = SelectionController(screens: { [screen] }, presentWindows: false, captureSnapshots: { _ in
            [FrozenScreenFrame(displayID: id, screenFrame: screen.frame.offsetBy(dx: 1, dy: 0), image: image)]
        })
        var geometryFailed = false
        changedDisplay.begin(scrolling: false) { if case .failure = $0 { geometryFailed = true } }; await pause()
        check(geometryFailed && changedDisplay.windows.isEmpty, "a display geometry change rejects stale coordinates before any overlay appears")

        for finishWithSelection in [false, true] {
            var probe: WeakFrozenImage?
            let memory = SelectionController(screens: { [screen] }, presentWindows: false, captureSnapshots: { _ in
                try autoreleasepool {
                    let pixels = try Raster(width: 64, height: 48, bytes: [UInt8](repeating: 255, count: 64 * 48 * 4)).cgImage()
                    probe = WeakFrozenImage(pixels)
                    return [FrozenScreenFrame(displayID: id, screenFrame: screen.frame, image: pixels)]
                }
            })
            memory.begin(scrolling: false) { _ in }; await pause()
            check(probe?.image != nil, "the active picker retains the frozen frame it is displaying")
            autoreleasepool {
                if finishWithSelection {
                    (memory.windows.first?.contentView as? SelectionView)?.onComplete?(CGRect(x: 20, y: 20, width: 60, height: 60))
                } else { memory.cancel() }
            }
            await pause()
            check(probe?.image == nil, "\(finishWithSelection ? "completion" : "cancellation") releases full-screen image objects")
        }

        let canvas = SelectionView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        let host = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = canvas; host.isOpaque = false; host.backgroundColor = .clear
        canvas.frozenImage = replacementImage
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 40, y: 60)))
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 200, y: 260)))
        let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        func color(_ x: CGFloat) -> NSColor {
            bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / 480), y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
        }
        check(color(120).alphaComponent > 0.99 && color(120).redComponent > 0.95,
              "the selected region redraws frozen pixels rather than cutting through to the live desktop")
        check(color(300).alphaComponent > 0.99 && color(300).redComponent < 0.85,
              "outside the selection, the same frozen screen remains visible under dimming")
        let folder = URL(fileURLWithPath: ".build/previews"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("frozen-selection.png"))
        canvas.frozenImage = nil; host.close()
        if failures > 0 { exit(1) }
        print("Frozen selection checks passed using synthetic images; no real screen capture or system clipboard access")
    }
}
