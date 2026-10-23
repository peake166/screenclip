// Adapted from Snapzy's ScrollingCaptureFrameSource.swift:
// https://github.com/andynvt/snapzy/blob/master/Snapzy/Services/Capture/ScrollingCapture/ScrollingCaptureFrameSource.swift
// BSD 3-Clause License
// Copyright (c) 2026, Trong Duong Duc
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// One continuous, region-scoped stream, independent of screenshot polling.
@MainActor
final class ScopedScrollFrameSource {
    private var stream: SCStream?
    private var receiver: ScrollFrameReceiver?
    private var onFrame: ((CGImage) -> Void)?
    private var onFailure: ((String) -> Void)?

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration,
               frameHandler: @escaping (CGImage) -> Void,
               failureHandler: @escaping (String) -> Void) async throws {
        stop()
        try Task.checkCancellation()

        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let receiver = ScrollFrameReceiver(
            frameHandler: { [weak self] image, source in
                guard let self, self.stream === source else { return }
                self.onFrame?(image)
            },
            failureHandler: { [weak self] message, source in
                guard let self, self.stream === source else { return }
                let callback = self.onFailure
                self.stop()
                callback?(message)
            })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.sampleQueue)
        self.receiver = receiver
        self.stream = stream
        onFrame = frameHandler
        onFailure = failureHandler

        do {
            try await withTaskCancellationHandler {
                try await stream.startCapture()
            } onCancel: { [weak self] in
                Task { @MainActor in
                    // Cancellation of an old start must not stop its replacement.
                    guard let self, self.stream === stream else { return }
                    self.stop()
                }
            }
            guard self.stream === stream, !Task.isCancelled else {
                // stop() may have run while startCapture was still suspended.
                // Its first stop attempt can precede capture actually starting.
                try? await stream.stopCapture()
                throw CancellationError()
            }
        } catch {
            if self.stream === stream { stop() }
            // Also cover stop/restart while the original start was awaiting.
            try? await stream.stopCapture()
            throw error
        }
    }

    func stop() {
        let activeStream = stream
        let activeReceiver = receiver
        stream = nil
        receiver = nil
        onFrame = nil
        onFailure = nil
        guard let activeStream else { return }

        if let activeReceiver {
            try? activeStream.removeStreamOutput(activeReceiver, type: .screen)
        }
        activeStream.stopCapture { _ in }
    }

    deinit {
        if let stream {
            if let receiver { try? stream.removeStreamOutput(receiver, type: .screen) }
            stream.stopCapture { _ in }
        }
    }
}

/// All decode state belongs to one stream and is touched only on sampleQueue.
/// A fresh receiver on restart prevents old queued samples sharing rate state.
private final class ScrollFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.local.screenclip.scrolling-frames", qos: .userInteractive)
    private let minimumPublishInterval: TimeInterval = 1.0 / 15.0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastPublishedAt: TimeInterval = 0
    private let frameHandler: @MainActor (CGImage, SCStream) -> Void
    private let failureHandler: @MainActor (String, SCStream) -> Void

    init(frameHandler: @escaping @MainActor (CGImage, SCStream) -> Void,
         failureHandler: @escaping @MainActor (String, SCStream) -> Void) {
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        autoreleasepool {
            guard type == .screen, sample.isValid, let pixelBuffer = sample.imageBuffer else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]]
            // Attachments are optional; a known non-complete frame is not usable.
            if let status = attachments?.first?[.status] as? Int,
               status != SCFrameStatus.complete.rawValue { return }

            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPublishedAt >= minimumPublishInterval else { return }
            let imageRect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer),
                                   height: CVPixelBufferGetHeight(pixelBuffer))
            guard let image = ciContext.createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: imageRect)
            else { return }
            lastPublishedAt = now
            DispatchQueue.main.async { [frameHandler] in frameHandler(image, stream) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { [failureHandler] in failureHandler(message, stream) }
    }
}
