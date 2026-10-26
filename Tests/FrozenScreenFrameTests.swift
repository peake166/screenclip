import AppKit

@main struct FrozenScreenFrameTests {
    static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        var bytes = [UInt8](repeating: 255, count: 400 * 200 * 4)
        let colors: [[UInt8]] = [[240, 20, 20], [20, 220, 20], [20, 20, 240], [220, 220, 20]]
        for y in 0..<200 { for x in 0..<400 {
            let color = colors[(y < 100 ? 0 : 2) + (x < 200 ? 0 : 1)], start = (y * 400 + x) * 4
            for c in 0..<3 { bytes[start + c] = color[c] }
        } }
        let image = CGImage(width: 400, height: 200, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1600,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let frame = FrozenScreenFrame(displayID: 1, screenFrame: CGRect(x: -200, y: 300, width: 200, height: 100), image: image)
        for (index, rect) in [CGRect(x: -200, y: 350, width: 100, height: 50), CGRect(x: -100, y: 350, width: 100, height: 50),
                              CGRect(x: -200, y: 300, width: 100, height: 50), CGRect(x: -100, y: 300, width: 100, height: 50)].enumerated() {
            do {
                let crop = try frame.crop(rect), pixel = (crop.height / 2 * crop.width + crop.width / 2) * 4
                check(crop.width == 200 && crop.height == 100 && (0..<3).allSatisfy { abs(Int(crop.bytes[pixel + $0]) - Int(colors[index][$0])) <= 2 },
                      "quadrant \(index) maps Retina pixels, top-left image origin and a negative display origin correctly")
            } catch { check(false, "quadrant \(index) produces a crop from its frozen screen") }
        }
        do { _ = try frame.crop(CGRect(x: 400, y: 400, width: 20, height: 20)); check(false, "an off-display selection fails") }
        catch { check(true, "an off-display selection fails") }
        do {
            let one = FrozenScreenFrame(displayID: 2, screenFrame: CGRect(x: 0, y: -200, width: 400, height: 200), image: image)
            let crop = try one.crop(CGRect(x: 0, y: -100, width: 200, height: 100))
            check(crop.width == 200 && crop.height == 100 && crop.bytes[0] == 240, "a second display can use a different backing scale")
        } catch { check(false, "a second display supports its own backing scale") }
        if failures > 0 { exit(1) }
    }
}
