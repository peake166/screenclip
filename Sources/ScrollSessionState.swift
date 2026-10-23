struct ScrollSessionState {
    private var hasAlignmentGap = false
    private(set) var isCaptureInterrupted = false
    var hasUnmatchedContent: Bool { hasAlignmentGap || isCaptureInterrupted }

    mutating func observe(_ decision: StitchDecision) {
        switch decision {
        case .started, .appended:
            hasAlignmentGap = false
        case .noOverlap, .sizeChanged:
            hasAlignmentGap = true
        case .unchanged, .reversed, .limitReached:
            break
        }
    }

    mutating func captureInterrupted() {
        isCaptureInterrupted = true
    }

    mutating func captureResumed() {
        isCaptureInterrupted = false
    }
}
