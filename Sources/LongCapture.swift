import AppKit
import ScreenCaptureKit
import OSLog

@MainActor
final class LongCapture {
    private let region: CaptureRegion
    private let targetApplicationPID: Int32?
    private var source: CaptureSource?
    private let panel: ScrollPanel
    private let border: RegionBorder
    private let stitcher = OpenSourceScrollStitcher()
    private var sessionState = ScrollSessionState()
    private var processing: Task<Void, Never>?
    private var pending: (CGImage, Int)?
    private var latest: (CGImage, Int)?
    private var receivedSequence = 0
    private var processedSequence = 0
    private var stopped = false
    private var finishing = false
    private var atLimit = false
    private var width = 0, height = 0, frameCount = 0
    private let logger = Logger(subsystem: "com.local.screenclip", category: "ScrollCapture")
    var onEnd: ((String?) -> Void)?
    var onTranslate: ((Raster) -> Void)?

    init(region: CaptureRegion, finishShortcut: String? = "⌃⌥⌘5", targetApplicationPID: Int32? = nil) {
        self.region = region; self.targetApplicationPID = targetApplicationPID
        border = RegionBorder(region: region)
        panel = ScrollPanel(region: region, finishShortcut: finishShortcut)
        panel.finishButton.isEnabled = false; panel.translateButton.isEnabled = false
        panel.onFinish = { [weak self] in Task { await self?.finish() } }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onTranslate = { [weak self] in Task { await self?.finish(translate: true) } }
        border.orderFrontRegardless(); panel.orderFrontRegardless()
    }

    func start() async {
        do {
            let captureSource = try await CaptureSource(region: region,
                targetApplicationPID: targetApplicationPID, scrolling: true)
            guard !stopped else { captureSource.stop(); return }
            source = captureSource
            try await startFrames(captureSource)
            let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while frameCount == 0, !stopped {
                guard clock.now < deadline else { throw CaptureStreamError.noFrame }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            guard !stopped else { return }
            logger.error("Scroll capture failed to start: \(error.localizedDescription, privacy: .public)")
            close(); onEnd?(error.localizedDescription)
        }
    }

    private func startFrames(_ source: CaptureSource) async throws {
        sessionState.captureResumed()
        try await source.startFrames(frameHandler: { [weak self] image in
            self?.receive(image)
        }, failureHandler: { [weak self] message in
            self?.interrupted(message)
        })
    }

    private func receive(_ image: CGImage) {
        guard !stopped, !sessionState.isCaptureInterrupted else { return }
        receivedSequence += 1; latest = (image, receivedSequence)
        guard !finishing, !atLimit else { return }
        // Only the latest pending frame waits. The actor runs the upstream
        // Vision and pixel matcher away from the main thread.
        pending = latest
        guard processing == nil else { return }
        processing = Task { [weak self] in
            guard let self else { return }
            while !self.stopped, !self.atLimit, let frame = self.pending {
                self.pending = nil
                do {
                    let update = try await self.stitcher.accept(frame.0)
                    guard !Task.isCancelled, !self.stopped else { break }
                    self.processedSequence = frame.1
                    self.apply(update)
                } catch {
                    guard !self.stopped else { break }
                    self.interrupted(error.localizedDescription)
                    break
                }
            }
            self.processing = nil
        }
    }

    private func apply(_ update: OpenSourceScrollStitcher.Update) {
        guard !stopped else { return }
        width = update.width; height = update.height; frameCount = update.frameCount
        sessionState.observe(update.decision)
        switch update.decision {
        case .started:
            panel.finishButton.isEnabled = true; panel.translateButton.isEnabled = true
            panel.message.stringValue = "向下滚动，完成后复制长图"
            logger.notice("Scroll capture started; engine: Snapzy; size: \(self.width)x\(self.height)")
        case .appended(let rows):
            panel.message.stringValue = "正在拼接 · 继续向下滚动"
            logger.notice("Scroll capture appended: \(rows) rows; height: \(self.height); segments: \(self.frameCount)")
        case .unchanged:
            if !sessionState.hasUnmatchedContent, !atLimit {
                panel.message.stringValue = "可继续滚动或复制长图"
            }
        case .reversed:
            panel.message.stringValue = "请回到已截位置，再向下滚动"
        case .noOverlap:
            panel.message.stringValue = "这一段未接上，请向上滚回后慢慢向下"
            logger.notice("Scroll capture alignment failed; height: \(self.height); segments: \(self.frameCount); \(update.debug ?? "", privacy: .public)")
        case .sizeChanged:
            panel.message.stringValue = "截图区域发生变化，请结束后重新截图"
        case .limitReached:
            guard frameCount > 0 else {
                close(); onEnd?("截图区域过大，请缩小框选范围。"); return
            }
            atLimit = true; source?.stop()
            panel.message.stringValue = "已达到长图上限，请复制本段后继续截图"
        }
        if sessionState.isCaptureInterrupted {
            panel.message.stringValue = "截图中断，可复制已截部分或取消"
        }
        panel.progress.stringValue = "\(width) × \(height) 像素 · \(frameCount) 段"
    }

    private func interrupted(_ message: String) {
        guard !stopped else { return }
        logger.error("Scroll capture interrupted: \(message, privacy: .public)")
        source?.stop(); pending = nil
        if frameCount == 0 { close(); onEnd?(message); return }
        sessionState.captureInterrupted()
        panel.message.stringValue = "截图中断，可复制已截部分或取消"
    }

    func finish(translate: Bool = false) async {
        guard !stopped, !finishing, frameCount > 0 else { return }
        finishing = true; panel.finishButton.isEnabled = false; panel.translateButton.isEnabled = false
        logger.notice("Scroll capture finish requested; segments: \(self.frameCount)")
        await processing?.value
        guard !stopped else { return }
        // Receive the settled tail while the current match drains, then commit
        // one final unseen frame before exporting the full image once.
        if !atLimit {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !stopped else { return }
            if let frame = latest, frame.1 > processedSequence {
                do {
                    let update = try await stitcher.accept(frame.0)
                    guard !stopped else { return }
                    processedSequence = frame.1; apply(update)
                } catch { sessionState.captureInterrupted() }
            }
        }
        guard !stopped else { return }
        source?.stop()
        if sessionState.hasUnmatchedContent {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "有一段内容尚未接上"
            alert.informativeText = "向上滚回已截位置后可继续，或只复制目前已接好的部分。"
            alert.addButton(withTitle: "继续截图"); alert.addButton(withTitle: "复制已截部分")
            if alert.runModal() == .alertFirstButtonReturn {
                finishing = false; panel.finishButton.isEnabled = true; panel.translateButton.isEnabled = true
                if let source {
                    do { try await startFrames(source) }
                    catch { interrupted(error.localizedDescription) }
                }
                return
            }
        }
        do {
            let image = try await stitcher.image()
            guard !stopped else { return }
            try ImageClipboard.copy(image)
            logger.notice("Scroll capture copied; size: \(image.width)x\(image.height); segments: \(self.frameCount)")
            let message = "已复制\(frameCount > 1 ? "长图" : "图片") · \(image.width) × \(image.height)"
            close(); onEnd?(translate ? nil : message)
            if translate { onTranslate?(image) }
        } catch {
            guard !stopped else { return }
            finishing = false; panel.finishButton.isEnabled = true; panel.translateButton.isEnabled = true
            panel.message.stringValue = "复制失败，可以重试"
        }
    }

    func cancel() {
        guard !stopped else { return }
        logger.notice("Scroll capture cancelled; segments: \(self.frameCount)")
        close(); onEnd?(nil)
    }

    private func close() {
        stopped = true; processing?.cancel(); processing = nil
        source?.stop(); source = nil; pending = nil; latest = nil
        panel.orderOut(nil); border.orderOut(nil); panel.close(); border.close()
    }
}
