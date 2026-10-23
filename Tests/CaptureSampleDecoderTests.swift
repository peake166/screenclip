import AppKit
import CoreMedia
import CoreVideo
import Darwin
import ScreenCaptureKit

@main struct CaptureSampleDecoderTests {
    static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL") \(message)")
            if !value { failures += 1 }
        }
        func sample(status: SCFrameStatus? = nil, time: UInt64? = nil,
                    presentation: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> CMSampleBuffer {
            var pixel: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_32BGRA,
                                            nil, &pixel) == kCVReturnSuccess)
            CVPixelBufferLockBaseAddress(pixel!, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel!)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<2 {
                for x in 0..<4 {
                    let i = y * CVPixelBufferGetBytesPerRow(pixel!) + x * 4
                    bytes[i] = 0; bytes[i + 1] = x < 2 ? 0 : 255
                    bytes[i + 2] = x < 2 ? 255 : 0; bytes[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel!, [])
            var description: CMVideoFormatDescription?, result: CMSampleBuffer?
            precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel!, formatDescriptionOut: &description) == noErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 6),
                presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
            precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel!, formatDescription: description!, sampleTiming: &timing,
                sampleBufferOut: &result) == noErr)
            if status != nil || time != nil {
                let attachments = CMSampleBufferGetSampleAttachmentsArray(result!, createIfNecessary: true)!
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                func set(_ key: SCStreamFrameInfo, _ value: NSNumber) {
                    let name = key.rawValue as NSString
                    CFDictionarySetValue(dictionary, Unmanaged.passUnretained(name).toOpaque(),
                                         Unmanaged.passUnretained(value).toOpaque())
                }
                if let status { set(.status, NSNumber(value: status.rawValue)) }
                if let time { set(.displayTime, NSNumber(value: time)) }
            }
            return result!
        }
        let decoder = CaptureSampleDecoder()
        let missingMetadata = decoder.decode(sample())
        check(missingMetadata != nil, "a valid generated video frame remains usable when optional stream metadata is absent")
        if let frame = missingMetadata {
            let raster = try Raster(frame.image)
            check(raster.width == 4 && raster.height == 2 &&
                stride(from: 0, to: raster.bytes.count, by: 4).allSatisfy { i in
                    let left = (i / 4) % 4 < 2
                    return raster.bytes[i] == (left ? 255 : 0) && raster.bytes[i + 1] == (left ? 0 : 255)
                        && raster.bytes[i + 2] == 0 && raster.bytes[i + 3] == 255
                }, "the real CoreMedia to CoreImage decode preserves generated red and green pixels")
        } else { check(false, "the real CoreMedia to CoreImage decode preserves generated red and green pixels") }
        check(decoder.decode(sample(status: .complete, time: 1234))?.displayTime == 1234,
              "an explicit WindowServer display timestamp is preserved")
        let oldTime = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 1, timescale: 1))
        let buffer = CaptureFrameBuffer(); buffer.beginRefresh(after: mach_absolute_time())
        let old = decoder.decode(sample(status: .complete, presentation: oldTime))
        check(old?.displayTime == CMClockConvertHostTimeToSystemUnits(oldTime),
              "missing display metadata uses the frame presentation time rather than the callback time")
        if let old { buffer.accept(old.image, displayTime: old.displayTime) }
        check(try buffer.snapshot() == nil, "a queued old frame without display metadata cannot pass the filter refresh fence")
        check(decoder.decode(sample(status: .complete, presentation: .invalid)) == nil,
              "an untimed frame cannot masquerade as fresh content after a filter change")
        for status in [SCFrameStatus.idle, .blank, .suspended, .stopped] {
            check(decoder.decode(sample(status: status, time: 1234)) == nil,
                  "non-complete stream state \(status.rawValue) never becomes a screenshot")
        }
        let invalid = sample(status: .complete); CMSampleBufferInvalidate(invalid)
        check(decoder.decode(invalid) == nil, "an invalid native sample is never delivered")
        if failures > 0 { print("\(failures) decoder checks failed"); exit(1) }
        print("All native sample decoder checks passed with generated pixels only")
    }
}
