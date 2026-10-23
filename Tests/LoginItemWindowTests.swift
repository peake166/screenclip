import AppKit

@main
struct LoginItemWindowTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            if value() { print("PASS \(name)") }
            else { failures += 1; print("FAIL \(name)") }
        }
        let window = MainWindow(icon: nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(window.contentView!).compactMap { $0 as? NSButton }
        guard let checkbox = buttons.first(where: { $0.accessibilityLabel() == "登录时启动" }),
              let approval = buttons.first(where: { $0.accessibilityLabel() == "在系统设置中允许登录时启动" }) else {
            print("FAIL login setting has accessible controls"); exit(1)
        }
        window.updateLoginItem(.notRegistered)
        check(checkbox.state == .off && approval.isHidden, "a disabled system item renders an unchecked setting")
        var requested: [Bool] = []
        window.onLoginItemChange = { enabled in
            requested.append(enabled)
            // Simulate a rejected registration: the actual system state remains off.
            window.updateLoginItem(.notRegistered)
        }
        checkbox.performClick(nil)
        check(requested == [true] && checkbox.state == .off, "a failed enable returns the visible switch to the actual system state")
        window.updateLoginItem(.enabled)
        check(checkbox.state == .on && approval.isHidden && checkbox.title == "登录时启动",
              "an enabled system item shows its real state without an approval action")
        checkbox.performClick(nil)
        check(requested.last == false, "the enabled switch can request disabling")
        window.updateLoginItem(.requiresApproval)
        check(checkbox.state == .on && !approval.isHidden && checkbox.title.contains("待允许"),
              "pending system consent is visibly distinct from an enabled login item")
        var opened = 0
        window.onLoginItemSettings = { opened += 1 }
        approval.performClick(nil)
        check(opened == 1, "the pending approval action dispatches to system settings")
        window.updateLoginItem(.notFound)
        check(checkbox.state == .off && approval.isHidden, "an unavailable app never displays a false enabled state")
        if failures > 0 { print("\(failures) login item window checks failed"); exit(1) }
        print("All login item window checks passed")
    }
}
