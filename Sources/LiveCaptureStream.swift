import CoreImage
import CoreMedia
import Darwin
import Foundation
import OSLog
import ScreenCaptureKit

final class CaptureSampleDecoder {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func decode(_ sample: CMSampleBuffer) -> (image: CGImage, displayTime: UInt64)? {
        guard sample.isValid, let buffer = sample.imageBuffer else { return nil }
        let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]])?.first
        // Stream metadata is optional. A ready image buffer must not be discarded
        // solely because its provider omits attachments or the status field.
        if let status = info?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return nil }
        var timestamp = (info?[.displayTime] as? NSNumber)?.uint64Value ?? 0
        if timestamp == 0 {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            guard presentation.isValid, presentation.isNumeric, presentation.value > 0 else { return nil }
            timestamp = CMClockConvertHostTimeToSystemUnits(presentation)
        }
        guard timestamp > 0 else { return nil }
        let content = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(content, from: content.extent) else { return nil }
        return (image, timestamp)
    }
}

private final class CaptureStreamReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let frames = CaptureFrameBuffer()
    private let decoder = CaptureSampleDecoder()
    private let counterLock = NSLock()
    private var samples = 0, imageBuffers = 0, decoded = 0
    private var lastDisplayTime: UInt64 = 0
    private var statuses: [Int: Int] = [:]

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]])?.first
        let frame = decoder.decode(sample)
        counterLock.lock()
        samples += 1; imageBuffers += sample.imageBuffer == nil ? 0 : 1
        statuses[info?[.status] as? Int ?? -1, default: 0] += 1
        if let frame { decoded += 1; lastDisplayTime = frame.displayTime }
        counterLock.unlock()
        guard let frame else { return }
        frames.accept(frame.image, displayTime: frame.displayTime)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { frames.fail(error) }

    func diagnostics() -> String {
        counterLock.lock(); defer { counterLock.unlock() }
        let states = statuses.keys.sorted().map { "\($0):\(statuses[$0]!)" }.joined(separator: ",")
        return "samples=\(samples); imageBuffers=\(imageBuffers); decoded=\(decoded); lastDisplayTime=\(lastDisplayTime); statuses=\(states)"
    }
}

// One capture session survives across all samples. Refreshing its filter avoids
// the initial missing-window frame seen with WeChat 4.x and one-shot captures.
@MainActor
final class LiveCaptureStream {
    private let receiver = CaptureStreamReceiver()
    private var stream: SCStream?
    private let logger = Logger(subsystem: "com.local.screenclip", category: "WindowFrames")

    init(initialFilter: SCContentFilter, finalFilter: SCContentFilter,
         configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: initialFilter, configuration: configuration, delegate: receiver)
        self.stream = stream
        do {
            try stream.addStreamOutput(receiver, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.local.screenclip.window-frames", qos: .userInitiated))
            try await stream.startCapture()
            try await Task.sleep(nanoseconds: 250_000_000)
            receiver.frames.beginRefresh(after: mach_absolute_time())
            try await stream.updateContentFilter(finalFilter)
        } catch {
            stop()
            throw error
        }
    }

    func grab() async throws -> CGImage {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while true {
            try Task.checkCancellation()
            if let image = try receiver.frames.snapshot() { return image }
            guard clock.now < deadline else {
                logger.error("No usable window frame; \(self.receiver.diagnostics(), privacy: .public)")
                throw CaptureStreamError.noFrame
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func stop() {
        receiver.frames.stop()
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    deinit {
        receiver.frames.stop()
        stream?.stopCapture { _ in }
    }
}
