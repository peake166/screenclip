import AppKit

@main struct ClipboardPasteTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ name: String) { print("\(condition ? "PASS" : "FAIL") \(name)"); if !condition { failures += 1 } }
        func decision(trusted: Bool = true, running: Bool = true, frontmost: Bool = true, previous: Bool = false,
                      window: Bool = true, modifiers: Bool = true, secure: Bool = false, elapsed: Double = 0.1) -> ClipboardPasteDecision {
            ClipboardPastePolicy.decide(trusted: trusted, targetRunning: running, targetFrontmost: frontmost,
                previouslyFrontmost: previous, windowMatches: window, modifiersReleased: modifiers, secureInput: secure, elapsed: elapsed)
        }
        check(decision() == .send, "paste is allowed only when the original target is ready")
        check(decision(trusted: false) == .permission, "missing accessibility permission never posts input")
        check(decision(running: false) == .targetGone, "a closed target never receives input")
        check(decision(frontmost: false) == .wait, "activation must complete before pasting")
        check(decision(modifiers: false) == .wait, "shortcut modifiers must be released before pasting")
        check(decision(window: false) == .targetChanged, "a changed original window cannot receive an unexpected paste")
        check(decision(frontmost: false, previous: true) == .targetChanged, "switching apps during preparation cancels automatic paste")
        check(decision(secure: true) == .secureInput, "secure input falls back to copying without posting events")
        check(decision(frontmost: false, elapsed: 1.3) == .timedOut, "unavailable focus has a bounded wait instead of a late paste")
        if let events = ClipboardPasteKeys.events() {
            check(events.0.type == .keyDown && events.1.type == .keyUp, "native event factory creates exactly one complete keystroke")
            check(events.0.flags.contains(.maskCommand) && events.1.flags.contains(.maskCommand), "native paste events carry Command on both down and up")
            check(events.0.getIntegerValueField(.keyboardEventKeycode) == events.1.getIntegerValueField(.keyboardEventKeycode), "both events use the same keyboard-layout-aware key")
        } else { check(false, "native paste event creation") }
        if failures > 0 { exit(1) }
        print("Paste policy and native event construction passed; no events were posted")
    }
}
