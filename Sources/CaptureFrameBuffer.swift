import CoreGraphics
import Foundation

enum CaptureStreamError: LocalizedError {
    case stopped, noFrame
    var errorDescription: String? {
        switch self {
        case .stopped: return "截图已结束，请重新框选。"
        case .noFrame: return "目标应用未返回画面，请检查窗口是否可见，或是否限制了截图。"
        }
    }
}

// The capture callback runs on a serial sample queue; readers run on the main actor.
final class CaptureFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var failure: Error?
    private var stopped = false
    private var minimumDisplayTime: UInt64 = 0
    private var latestDisplayTime: UInt64 = 0

    func beginRefresh(after displayTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        minimumDisplayTime = displayTime
        latestDisplayTime = displayTime
        image = nil
    }

    func accept(_ frame: CGImage, displayTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, failure == nil, displayTime >= minimumDisplayTime,
              displayTime >= latestDisplayTime else { return }
        latestDisplayTime = displayTime
        image = frame
    }

    func snapshot() throws -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw CaptureStreamError.stopped }
        if let failure { throw failure }
        return image
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        failure = error; image = nil
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; image = nil
    }
}
