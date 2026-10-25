import AppKit
import Carbon

@main struct SelectionCancelTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL") \(label)")
            if !value { failures += 1 }
        }
        // Dispatch only inside this test process. No system keyboard events are posted.
        func dispatch(_ id: UInt32) {
            var event: EventRef?
            let result = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                     GetCurrentEventTime(), 0, &event)
            guard result == noErr, let event else { fatalError("Unable to create test hotkey event") }
            defer { ReleaseEvent(event) }
            var key = EventHotKeyID(signature: 0x53434C50, id: id)
            let parameter = SetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &key)
            guard parameter == noErr else { fatalError("Unable to configure test hotkey event") }
            _ = SendEventToEventTarget(event, GetApplicationEventTarget())
        }

        let shortcuts = HotKeys()
        var normalActions = 0
        check(shortcuts.register(id: 900, key: UInt32(kVK_F18),
              modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), action: { normalActions += 1 }),
              "the fixture registers a separate permanent action")
        defer { shortcuts.unregister(900) }

        // No display windows or screen contents are needed to exercise focus-independent cancellation.
        let selection = SelectionController(screens: { [] })
        for scrolling in [false, true, false] {
            var completions = 0
            var returnedRegion = false
            selection.begin(scrolling: scrolling) { region in
                completions += 1
                returnedRegion = region != nil
            }
            let before = normalActions
            dispatch(900)
            check(normalActions == before + 1, "selection does not swallow another owner's shortcut")
            check(NSApp.keyWindow == nil, "the cancellation fixture has no key window or mouse selection")
            dispatch(CaptureHotKeyID.selectionCancel)
            check(completions == 1 && !returnedRegion,
                  "Escape cancels \(scrolling ? "scrolling" : "ordinary") selection before a window receives focus")
            dispatch(CaptureHotKeyID.selectionCancel)
            check(completions == 1, "a repeated Escape completes cancellation only once")
            check(shortcuts.register(id: 901, key: UInt32(kVK_Escape), modifiers: 0, action: {}),
                  "cancelling selection releases the temporary Escape shortcut")
            shortcuts.unregister(901)
        }
        dispatch(900)
        check(normalActions == 4, "permanent shortcuts continue working after repeated cancellation")
        if failures > 0 { print("\(failures) selection cancellation checks failed"); exit(1) }
        print("Selection cancellation checks passed without displaying an overlay or capturing screen contents")
    }
}
