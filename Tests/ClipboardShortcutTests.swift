import AppKit
import Carbon

@main struct ClipboardShortcutTests {
    static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        let suite = "com.local.screenclip.clipboard-shortcut." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        struct Legacy: Codable { let copy: Shortcut?; let scroll: Shortcut?; let translate: Shortcut?; let version: Int }
        let custom = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "A")
        let original = Legacy(copy: custom, scroll: nil, translate: Shortcut.defaults[.translate], version: 2)
        defaults.set(try JSONEncoder().encode(original), forKey: "captureShortcuts.v1")
        let action = ShortcutAction(rawValue: "clipboard")
        check(action != nil, "clipboard history has its own configurable global shortcut")
        check(Shortcut.defaults[.clipboard] == Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey | cmdKey), keyLabel: "V"),
              "clipboard opens with Shift Command V by default")
        if let action {
            let settings = ShortcutPreferences(defaults: defaults) { _ in true }
            check(settings.bindings[.copy] == custom && settings.bindings[.scroll] == nil
                  && settings.bindings[.translate] == original.translate, "adding clipboard preserves all existing custom and disabled capture shortcuts")
            check(settings.bindings[action] == Shortcut.defaults[action], "old settings gain the clipboard default when it is free")
            check(settings.change(action, to: custom) != nil, "clipboard cannot steal another action's shortcut")
            check(settings.change(action, to: nil) == nil, "the clipboard shortcut can be disabled")
            check(ShortcutPreferences(defaults: defaults) { _ in true }.bindings[action] == nil, "a disabled clipboard shortcut stays disabled after restart")
            defaults.set(try JSONEncoder().encode(Legacy(copy: Shortcut.defaults[action], scroll: nil, translate: nil, version: 2)),
                         forKey: "captureShortcuts.v1")
            let conflict = ShortcutPreferences(defaults: defaults) { _ in true }
            check(conflict.bindings[.copy] == Shortcut.defaults[action] && conflict.bindings[action] == nil,
                  "migration keeps an existing use of the new default and leaves clipboard unbound")
            let ids = ShortcutAction.allCases.map(\.hotKeyID) + [CaptureHotKeyID.scrollCancel, CaptureHotKeyID.translationCancel, CaptureHotKeyID.selectionCancel]
            check(Set(ids).count == ids.count, "clipboard has no collision with permanent or temporary capture actions")
        }
        if failures > 0 { exit(1) }
        print("All clipboard shortcut migration checks passed")
    }
}
