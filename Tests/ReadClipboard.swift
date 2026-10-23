import AppKit
import CryptoKit
import Foundation
import Vision

let board = NSPasteboard.general
guard let data = board.data(forType: .png), let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else {
    print("No PNG image on the clipboard"); exit(2)
}
let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
print("\(image.width)x\(image.height) PNG SHA256 \(hash)")
if let output = CommandLine.arguments.dropFirst().first(where: { $0 != "--ocr" }) {
    try data.write(to: URL(fileURLWithPath: output))
}
if CommandLine.arguments.contains("--ocr") {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image).perform([request])
    let lines = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        .compactMap { $0.topCandidates(1).first?.string }.filter { $0.contains("ROW") }
    print(lines.joined(separator: "\n"))
}
