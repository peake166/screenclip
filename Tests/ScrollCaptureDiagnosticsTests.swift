import AppKit
import Foundation

@main struct ScrollCaptureDiagnosticsTests {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL") \(message)")
            if !value { failures += 1 }
        }
        let suite = "com.local.screenclip.diagnostics-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let token = UUID().uuidString
        check(ScrollCaptureDiagnostics.claim(token: token, bundleIdentifier: "com.tencent.xinWeChat",
              defaults: defaults, directory: directory) == nil,
              "Netease-only consent can never enable recording for a WeChat capture")
        check(ScrollCaptureDiagnostics.claim(token: token, bundleIdentifier: nil,
              defaults: defaults, directory: directory) == nil,
              "an unresolved capture target cannot consume the diagnostic consent")
        check(ScrollCaptureDiagnostics.claim(token: "", bundleIdentifier: "com.netease.163music",
              defaults: defaults, directory: directory) == nil,
              "ordinary app launches without a consent token never save screenshots")
        let recorder = ScrollCaptureDiagnostics.claim(token: token, bundleIdentifier: "com.netease.163music",
              defaults: defaults, directory: directory)!
        let reopenedDefaults = UserDefaults(suiteName: suite)!
        check(ScrollCaptureDiagnostics.claim(token: token, bundleIdentifier: "com.netease.163music",
              defaults: reopenedDefaults, directory: directory) == nil,
              "one authorization covers exactly one Netease session, including after an app restart")
        func image(_ number: Int) -> Raster {
            let pixels = (0..<(40 * 80)).flatMap { index -> [UInt8] in
                [UInt8((index * 7 + number * 31) % 256), UInt8((index + number * 59) % 256), 80, 255]
            }
            return Raster(width: 40, height: 80, bytes: pixels)
        }
        for index in 0..<18 {
            let sample = image(index)
            recorder.observe(sample, gray: sample.gray(), decision: index == 0 ? .started : .noOverlap)
            recorder.observe(sample, gray: sample.gray(), decision: .unchanged)
        }
        let result = try await recorder.finish().value
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.appendingPathComponent("manifest.json"))) as! [String: Any]
        let samples = json["samples"] as! [[String: Any]]
        check(samples.count == 8, "the authorized diagnostic saves no more than eight distinct generated frames")
        check((samples.first?["index"] as? Int) == 1 && (samples.last?["index"] as? Int) == 18,
              "idle duplicates are skipped while the beginning and latest actual changes are retained")
        let last = samples.last!
        let png = try Data(contentsOf: result.appendingPathComponent(last["image"] as! String))
        let decoded = try Raster(NSBitmapImageRep(data: png)!.cgImage!)
        check(decoded.bytes == image(17).bytes, "the saved diagnostic image preserves the exact generated capture pixels")
        check(try Data(contentsOf: result.appendingPathComponent(last["gray"] as! String)) == Data(image(17).gray().pixels),
              "the diagnostic also preserves the exact grayscale input used by the matcher")
        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              "diagnostic images are stored in a private local directory")
        let again = try await recorder.finish().value
        check(again == result, "closing the session again does not create additional saved samples")
        if failures > 0 { print("\(failures) diagnostic checks failed"); exit(1) }
        print("All one-time diagnostic checks passed using generated pixels only")
    }
}
