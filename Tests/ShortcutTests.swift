import AppKit
import Carbon
import Foundation

@main
struct ShortcutTests {
    @MainActor static func main() {
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        let suite = "com.local.screenclip.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "S")
        let plain = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, keyLabel: "S")
        let shiftOnly = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(shiftKey), keyLabel: "S")
        check(custom.isValid && !plain.isValid && !shiftOnly.isValid, "ordinary typing cannot become a global shortcut")
        check(custom.display == "⇧⌘S", "modifier symbols display in macOS order")
        var applications = 0
        let settings = ShortcutPreferences(defaults: defaults) { _ in applications += 1; return true }
        check(settings.change(.copy, to: custom) == nil && settings.bindings[.copy] == custom,
              "the selected shortcut replaces the previous one")
        let reloaded = ShortcutPreferences(defaults: defaults) { _ in true }
        check(reloaded.bindings[.copy] == custom, "the shortcut survives app restart")
        let appliedBeforeDuplicate = applications
        check(settings.change(.copy, to: settings.bindings[.scroll]) != nil && settings.bindings[.copy] == custom,
              "the two capture actions cannot share the same shortcut")
        check(applications == appliedBeforeDuplicate, "a duplicate never changes the active registrations")
        check(settings.change(.copy, to: plain) != nil && settings.bindings[.copy] == custom,
              "an invalid shortcut preserves the saved selection")
        let rejected = ShortcutPreferences(defaults: defaults) { _ in false }
        let replacement = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey), keyLabel: "D")
        check(rejected.change(.copy, to: replacement) != nil && rejected.bindings[.copy] == custom,
              "a system registration conflict preserves the previous preference")
        let afterReject = ShortcutPreferences(defaults: defaults) { _ in true }
        check(afterReject.bindings[.copy] == custom, "a rejected change is not persisted")
        check(settings.change(.copy, to: nil) == nil && settings.bindings[.copy] == nil,
              "a shortcut can be disabled while menu actions remain available")
        let afterClear = ShortcutPreferences(defaults: defaults) { _ in true }
        check(afterClear.bindings[.copy] == nil, "a disabled shortcut stays disabled after restart")
        check(settings.reset() == nil && settings.bindings == Shortcut.defaults,
              "restore defaults applies both actions together")
        let resetReloaded = ShortcutPreferences(defaults: defaults) { _ in true }
        check(resetReloaded.bindings == Shortcut.defaults, "restored defaults are persisted")
        check(settings.change(.translate, to: custom) == nil, "the translation shortcut can be customized independently")
        check(ShortcutPreferences(defaults: defaults) { _ in true }.bindings[.translate] == custom,
              "the translation shortcut survives restart")
        check(settings.change(.copy, to: custom) != nil, "translation and screenshot shortcuts cannot collide")
        _ = settings.change(.translate, to: nil)
        check(ShortcutPreferences(defaults: defaults) { _ in true }.bindings[.translate] == nil,
              "a cleared translation shortcut stays disabled")
        let legacy = try! JSONEncoder().encode(["copy": custom])
        defaults.set(legacy, forKey: "captureShortcuts.v1")
        let migrated = ShortcutPreferences(defaults: defaults) { _ in true }
        check(migrated.bindings[.copy] == custom && migrated.bindings[.scroll] == nil && migrated.bindings[.translate] == Shortcut.defaults[.translate],
              "upgrading preserves existing custom and disabled shortcuts while adding translation")
        let legacyConflict = try! JSONEncoder().encode(["copy": Shortcut.defaults[.translate]!])
        defaults.set(legacyConflict, forKey: "captureShortcuts.v1")
        let conflictMigration = ShortcutPreferences(defaults: defaults) { _ in true }
        check(conflictMigration.bindings[.copy] == Shortcut.defaults[.translate] && conflictMigration.bindings[.translate] == nil,
              "upgrading never takes an existing shortcut away for translation")
        let modifierKey = Shortcut(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey), keyLabel: "⌘")
        check(!modifierKey.isValid, "a modifier by itself cannot be recorded")
        _ = NSApplication.shared
        let recorder = ShortcutRecorder()
        check(recorder.isAccessibilityElement(), "the shortcut recorder is exposed as an accessible control")
        recorder.shortcut = settings.bindings[.copy]
        var ended = 0
        var lastError: String?
        recorder.onBegin = { true }
        recorder.onEnd = { ended += 1 }
        recorder.onApply = { settings.change(.copy, to: $0) }
        recorder.onError = { lastError = $0 }
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ text: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!
        }
        recorder.beginRecording()
        recorder.keyDown(with: event(UInt16(kVK_ANSI_S), [], "s"))
        check(recorder.isRecording && lastError != nil, "invalid input keeps the recorder open with a reason")
        let acceptedEvent = event(UInt16(kVK_ANSI_S), [.command, .option], "s")
        check(recorder.performKeyEquivalent(with: acceptedEvent), "Command combinations are captured instead of invoking menus")
        check(!recorder.isRecording && ended == 1 && settings.bindings[.copy]?.display == "⌥⌘S",
              "recording commits the selected shortcut and restores normal key handling")
        let savedBeforeCancel = settings.bindings
        recorder.beginRecording()
        recorder.keyDown(with: event(UInt16(kVK_Escape), [], ""))
        check(!recorder.isRecording && settings.bindings == savedBeforeCancel,
              "Escape cancels recording without changing saved shortcuts")
        recorder.beginRecording()
        recorder.keyDown(with: event(UInt16(kVK_Delete), [], ""))
        check(!recorder.isRecording && settings.bindings[.copy] == nil,
              "Delete clears the shortcut from the recorder and persistence")
        recorder.beginRecording()
        _ = recorder.resignFirstResponder()
        check(!recorder.isRecording, "leaving the recorder releases editing mode")
        let window = MainWindow(icon: nil)
        let userBindings: [ShortcutAction: Shortcut] = [
            .copy: Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "A"),
            .scroll: Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "W"),
            .translate: custom,
            .clipboard: Shortcut.defaults[.clipboard]!
        ]
        window.update(bindings: userBindings, permissionGranted: true)
        window.contentView!.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var dispatched: [ShortcutAction] = []
        window.onCapture = { dispatched.append($0) }
        for action in ShortcutAction.allCases {
            guard let button = descendants(window.contentView!).compactMap({ $0 as? NSButton })
                .first(where: { $0.accessibilityLabel() == action.title + "，快捷键 " + userBindings[action]!.display }) else {
                check(false, "capture action exposes its current custom shortcut"); continue
            }
            for x in [CGFloat(30), CGFloat(100), button.bounds.width - 30] {
                let point = button.convert(CGPoint(x: x, y: button.bounds.midY), to: button.superview)
                check(button.hitTest(point) === button, "clicking the icon, title or shortcut reaches \(action.title)")
            }
            button.performClick(nil)
            check(dispatched.last == action, "the displayed action dispatches \(action.title)")
        }
        window.close()
        if failures > 0 { print("\(failures) shortcut behavior checks failed"); exit(1) }
        print("All shortcut behavior checks passed")
    }
}
