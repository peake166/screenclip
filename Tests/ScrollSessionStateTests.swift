import Foundation

@main enum ScrollSessionStateTests {
    static func main() {
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL") \(name)")
            if !passed { failures += 1 }
        }

        var state = ScrollSessionState()
        check(!state.hasUnmatchedContent, "a new session has no unmatched content")
        state.captureResumed()
        check(!state.isCaptureInterrupted && !state.hasUnmatchedContent,
              "starting capture without an earlier interruption leaves the session aligned")
        state.captureInterrupted()
        state.captureResumed()
        check(!state.isCaptureInterrupted && !state.hasUnmatchedContent,
              "explicitly restarting an interrupted aligned session clears its interruption warning")
        state.observe(.started)
        state.observe(.noOverlap)
        check(state.hasUnmatchedContent, "an unaligned viewport requires a finish warning")
        state.observe(.unchanged)
        check(state.hasUnmatchedContent, "a stationary final viewport cannot hide previously unmatched content")
        state.observe(.unchanged)
        check(state.hasUnmatchedContent, "repeated stationary frames keep the finish warning")
        state.observe(.reversed)
        check(state.hasUnmatchedContent, "scrolling backward alone does not prove the missing section was joined")
        state.observe(.limitReached)
        check(state.hasUnmatchedContent, "reaching the image limit preserves the finish warning")
        state.observe(.appended(37))
        check(!state.hasUnmatchedContent, "joining to the last accepted viewport resolves unmatched content")
        state.observe(.unchanged)
        state.observe(.reversed)
        state.observe(.limitReached)
        check(!state.hasUnmatchedContent, "stationary frames, backtracking and the image limit preserve an aligned session")

        state.observe(.sizeChanged)
        check(state.hasUnmatchedContent, "a changed viewport size requires a finish warning")
        state.observe(.unchanged)
        check(state.hasUnmatchedContent, "a stationary frame does not resolve a changed viewport size")
        state.observe(.started)
        check(!state.hasUnmatchedContent, "starting a new capture clears a prior finish warning")

        state.captureInterrupted()
        check(state.hasUnmatchedContent && state.isCaptureInterrupted, "a capture interruption requires a finish warning")
        state.observe(.unchanged)
        state.observe(.reversed)
        state.observe(.limitReached)
        check(state.hasUnmatchedContent, "unconfirmed frames cannot hide a capture interruption")
        state.observe(.appended(1))
        check(state.hasUnmatchedContent && state.isCaptureInterrupted,
              "an in-flight append cannot hide that the capture source has stopped")
        state.observe(.started)
        check(state.hasUnmatchedContent && state.isCaptureInterrupted,
              "an in-flight first frame cannot hide that the capture source has stopped")
        state.captureResumed()
        check(!state.hasUnmatchedContent && !state.isCaptureInterrupted,
              "explicitly restarting capture resolves an interruption when no alignment gap remains")

        state.observe(.noOverlap)
        state.captureInterrupted()
        state.captureResumed()
        check(state.hasUnmatchedContent && !state.isCaptureInterrupted,
              "restarting the capture source preserves a previous alignment gap")
        state.observe(.appended(37))
        check(!state.hasUnmatchedContent && !state.isCaptureInterrupted,
              "joining after capture resumes resolves the previous alignment gap")

        state.observe(.sizeChanged)
        state.captureInterrupted()
        state.observe(.appended(37))
        check(state.hasUnmatchedContent && state.isCaptureInterrupted,
              "a successful in-flight join clears only the alignment gap while capture remains interrupted")
        state.captureResumed()
        check(!state.hasUnmatchedContent && !state.isCaptureInterrupted,
              "resuming after a confirmed join clears the remaining interruption warning")

        if failures > 0 { print("\(failures) scroll session state checks failed"); exit(1) }
        print("All scroll session state checks passed")
    }
}
