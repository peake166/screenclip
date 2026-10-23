import Foundation
import Vision

private final class ProbeRequest: VNRecognizeTextRequest {
    var cancellations = 0
    override func cancel() { cancellations += 1; super.cancel() }
}

@main struct CancellationTests {
    static func main() throws {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
        }
        let active = OCRCancellation(), request = ProbeRequest()
        try active.install(request); active.cancel(); active.cancel()
        check(request.cancellations == 1, "cancelling recognition reaches the active native request exactly once")
        let queued = OCRCancellation(); queued.cancel()
        do { try queued.install(ProbeRequest()); check(false, "a cancelled queued recognition cannot start native work") }
        catch is CancellationError { check(true, "a cancelled queued recognition cannot start native work") }
        let done = OCRCancellation(), completed = ProbeRequest()
        try done.install(completed); done.clear(); done.cancel()
        check(completed.cancellations == 0, "a completed native request is released before later cancellation")
        if failures > 0 { exit(1) }
    }
}
