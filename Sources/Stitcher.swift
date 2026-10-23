import CoreGraphics
import Foundation

struct GrayFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

enum StitchDecision: Equatable {
    case started
    case appended(Int)
    case unchanged
    case reversed
    case noOverlap
    case sizeChanged
    case limitReached
}
