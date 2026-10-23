import CoreGraphics
import Foundation

@main struct CaptureFrameBufferTests {
    static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL") \(message)")
            if !value { failures += 1 }
        }
        func frame(_ color: UInt8) -> CGImage {
            let data = Data([color, 0, 0, 255, color, 0, 0, 255])
            return CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: data as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
        }
        let desktop = frame(12), window = frame(180), scrolled = frame(230)
        let buffer = CaptureFrameBuffer()
        check(try buffer.snapshot() == nil, "no image is returned before capture produces a frame")
        buffer.accept(desktop, displayTime: 90)
        buffer.beginRefresh(after: 100)
        check(try buffer.snapshot() == nil, "refresh discards the initial desktop frame before exposing the selected window")
        buffer.accept(desktop, displayTime: 99)
        check(try buffer.snapshot() == nil, "a queued frame from before the filter refresh cannot become the screenshot")
        buffer.accept(window, displayTime: 110)
        check(try buffer.snapshot() === window, "the selected window becomes available after the refreshed filter produces it")
        buffer.accept(scrolled, displayTime: 120)
        check(try buffer.snapshot() === scrolled, "later scroll frames replace the initial selected-window image")
        buffer.accept(desktop, displayTime: 95)
        check(try buffer.snapshot() === scrolled, "an out-of-order callback cannot replace a valid scrolling frame with desktop pixels")
        buffer.accept(window, displayTime: 115)
        check(try buffer.snapshot() === scrolled, "an older post-refresh frame cannot replace the newest frame")
        buffer.fail(NSError(domain: "fixture", code: 42))
        do { _ = try buffer.snapshot(); check(false, "capture errors must stop image delivery") }
        catch { check((error as NSError).code == 42, "a stopped native stream reports its failure instead of copying a stale image") }
        buffer.stop(); buffer.accept(window, displayTime: 200)
        do { _ = try buffer.snapshot(); check(false, "late frames must remain unavailable after cancellation") }
        catch { check(error is CaptureStreamError, "cancelling capture releases the frame and rejects late callback images") }
        if failures > 0 { print("\(failures) capture frame checks failed"); exit(1) }
        print("All capture frame checks passed")
    }
}
