import AppKit
import Carbon

@main
struct NativeHotKeyTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() { print("PASS \(message)") } else { failures += 1; print("FAIL \(message)") }
        }
        let owner = HotKeys(), blocker = HotKeys(), probe = HotKeys()
        let modifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        check(owner.register(id: 900, key: UInt32(kVK_F18), modifiers: modifiers, action: {}), "registers a native global hotkey")
        check(blocker.register(id: 901, key: UInt32(kVK_F19), modifiers: modifiers, action: {}), "reserves a different native hotkey")
        check(!owner.register(id: 900, key: UInt32(kVK_F19), modifiers: modifiers, action: {}), "the OS rejects an occupied replacement")
        check(!probe.register(id: 902, key: UInt32(kVK_F18), modifiers: modifiers, action: {}), "a failed replacement keeps the previous native hotkey registered")
        check(owner.register(id: 900, key: UInt32(kVK_F20), modifiers: modifiers, action: {}), "an available replacement succeeds with the same action ID")
        check(probe.register(id: 902, key: UInt32(kVK_F18), modifiers: modifiers, action: {}), "successful replacement releases the previous key")
        owner.unregister(900); blocker.unregister(901); probe.unregister(902)
        let capture = HotKeys()
        let translationID = ShortcutAction.translate.hotKeyID
        check(capture.register(id: translationID, key: UInt32(kVK_F18), modifiers: modifiers, action: {}),
              "the translation shortcut is registered before entering its result view")
        for cycle in 1...2 {
            check(capture.register(id: CaptureHotKeyID.translationCancel, key: UInt32(kVK_F19), modifiers: modifiers, action: {}),
                  "translation cycle \(cycle) registers a temporary cancel shortcut")
            capture.unregister(CaptureHotKeyID.translationCancel)
            let translationWasReleased = probe.register(id: 903, key: UInt32(kVK_F18), modifiers: modifiers, action: {})
            check(!translationWasReleased, "closing translation cycle \(cycle) preserves the original global shortcut")
            probe.unregister(903)
        }
        capture.unregister(translationID)
        check(probe.register(id: 903, key: UInt32(kVK_F18), modifiers: modifiers, action: {}),
              "only unregistering the translation action releases its global shortcut")
        probe.unregister(903)
        let reserved = ShortcutAction.allCases.map(\.hotKeyID) + [CaptureHotKeyID.scrollCancel, CaptureHotKeyID.translationCancel, CaptureHotKeyID.selectionCancel]
        check(Set(reserved).count == reserved.count, "permanent actions and temporary cancel shortcuts have distinct identities")
        if failures > 0 { exit(1) }
        print("All native hotkey checks passed")
    }
}
