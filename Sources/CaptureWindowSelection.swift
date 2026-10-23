import CoreGraphics
import Foundation

struct CaptureWindowCandidate {
    let id: UInt32
    let processID: Int32
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
}

enum CaptureWindowSelection {
    private static func isApplicationWindow(_ window: CaptureWindowCandidate) -> Bool {
        // Floating document/panel windows are real capture targets too. Desktop,
        // menus and higher system overlays remain outside the application range.
        let normal = Int(CGWindowLevelForKey(.normalWindow))
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        return window.isOnScreen && (normal...floating).contains(window.layer)
    }

    static func targetProcessID(for selection: CGRect, preferredProcessID: Int32?, ownProcessID: Int32,
                                windows: [CaptureWindowCandidate], frontToBack: [UInt32]) -> Int32? {
        let center = CGPoint(x: selection.midX, y: selection.midY)
        let order = Dictionary(frontToBack.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: min)
        return windows.filter {
            $0.processID != ownProcessID && isApplicationWindow($0) && $0.frame.contains(center)
        }.sorted {
            let left = order[$0.id] ?? Int.max, right = order[$1.id] ?? Int.max
            if left != right { return left < right }
            let leftPreferred = $0.processID == preferredProcessID, rightPreferred = $1.processID == preferredProcessID
            if leftPreferred != rightPreferred { return leftPreferred }
            return $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }.first?.processID
    }

    static func windowID(for selection: CGRect, processID: Int32,
                         windows: [CaptureWindowCandidate], frontToBack: [UInt32]) -> UInt32? {
        let order = Dictionary(frontToBack.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: min)
        return windows.filter {
            $0.processID == processID && isApplicationWindow($0) && $0.frame.contains(selection)
        }.sorted {
            let left = order[$0.id] ?? Int.max, right = order[$1.id] ?? Int.max
            if left != right { return left < right }
            return $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }.first?.id
    }
}
