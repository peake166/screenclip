import AppKit
import Foundation
import OSLog

@MainActor
final class ScrollCaptureDiagnostics {
    private struct Sample {
        let index: Int
        let image: Raster
        let gray: GrayFrame
        let decision: String
    }
    private let directory: URL
    private var samples: [Sample] = []
    private var lastGray: GrayFrame?
    private var sampleCount = 0
    private var maximumSamples = 8
    private var writing: Task<URL, Error>?
    private let logger = Logger(subsystem: "com.local.screenclip", category: "ScrollDiagnostics")
    private static let usedTokenKey = "scrollDiagnostics.usedConsentToken"

    private init(directory: URL) { self.directory = directory }

    static func beginIfRequested(bundleIdentifier: String?) -> ScrollCaptureDiagnostics? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "ScreenClipNeteaseDiagnosticsToken") as? String,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return claim(token: token, bundleIdentifier: bundleIdentifier, defaults: .standard,
            directory: caches.appendingPathComponent("com.local.screenclip/Diagnostics/" + token))
    }

    static func claim(token: String, bundleIdentifier: String?, defaults: UserDefaults,
                      directory: URL) -> ScrollCaptureDiagnostics? {
        guard UUID(uuidString: token) != nil,
              bundleIdentifier == "com.netease.163music",
              defaults.string(forKey: usedTokenKey) != token else { return nil }
        defaults.set(token, forKey: usedTokenKey)
        return ScrollCaptureDiagnostics(directory: directory)
    }

    func observe(_ image: Raster, gray: GrayFrame, decision: StitchDecision) {
        guard writing == nil, image.width * image.height <= 6_000_000 else { return }
        maximumSamples = min(8, max(2, 12_000_000 / (image.width * image.height)))
        if let lastGray, lastGray.width == gray.width, lastGray.height == gray.height {
            let changed = zip(lastGray.pixels, gray.pixels).reduce(0) {
                $0 + (abs(Int($1.0) - Int($1.1)) > 7 ? 1 : 0)
            }
            guard changed * 100 >= gray.pixels.count else { return }
        }
        lastGray = gray
        sampleCount += 1
        // Retain the beginning plus recent movement, rather than eight idle startup frames.
        if samples.count == maximumSamples { samples.remove(at: min(2, samples.count - 1)) }
        samples.append(Sample(index: sampleCount, image: image, gray: gray,
                              decision: String(describing: decision)))
    }

    @discardableResult
    func finish() -> Task<URL, Error> {
        if let writing { return writing }
        let captured = samples, destination = directory, logger = logger
        samples.removeAll(); lastGray = nil
        let task = Task.detached(priority: .utility) {
            do {
                try Self.write(captured, to: destination)
                logger.notice("Authorized Netease diagnostics saved; frames: \(captured.count); directory: \(destination.path, privacy: .public)")
                return destination
            } catch {
                let problem = error as NSError
                logger.error("Diagnostics write failed; domain: \(problem.domain, privacy: .public); code: \(problem.code)")
                throw error
            }
        }
        writing = task
        return task
    }

    nonisolated private static func write(_ samples: [Sample], to directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var manifest: [[String: Any]] = []
        for sample in samples {
            let name = String(format: "%03d", sample.index)
            let png = directory.appendingPathComponent(name + ".png")
            let gray = directory.appendingPathComponent(name + ".gray")
            try sample.image.png().write(to: png, options: .atomic)
            try Data(sample.gray.pixels).write(to: gray, options: .atomic)
            for path in [png, gray] { try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
            manifest.append(["index": sample.index, "image": png.lastPathComponent,
                "gray": gray.lastPathComponent, "width": sample.image.width, "height": sample.image.height,
                "grayWidth": sample.gray.width, "decision": sample.decision])
        }
        let report = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["bundleIdentifier": "com.netease.163music", "samples": manifest],
            options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
    }
}
