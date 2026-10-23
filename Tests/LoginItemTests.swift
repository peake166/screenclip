import AppKit
import Carbon
import Foundation

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var state: LoginItemState = .notRegistered
    var registeredState: LoginItemState = .enabled
    var registerCalls = 0
    var unregisterCalls = 0
    var settingsCalls = 0
    var rejectRegister = false
    var rejectUnregister = false
    enum Failure: Error { case rejected }
    func register() throws {
        registerCalls += 1
        if rejectRegister { throw Failure.rejected }
        state = registeredState
    }
    func unregister() throws {
        unregisterCalls += 1
        if rejectUnregister { throw Failure.rejected }
        state = .notRegistered
    }
    func openSettings() { settingsCalls += 1 }
}

@main
struct LoginItemTests {
    @MainActor static func main() {
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            if value() { print("PASS \(name)") }
            else { failures += 1; print("FAIL \(name)") }
        }
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)
        check(controller.state == .notRegistered && service.registerCalls == 0, "launching does not register a login item")
        var result = controller.setEnabled(true)
        check(service.registerCalls == 1 && result.state == .enabled && result.errorMessage == nil,
              "enabling registers the item and reports the real system state")
        _ = controller.setEnabled(true)
        check(service.registerCalls == 1, "enabling an enabled item does not register it twice")
        result = controller.setEnabled(false)
        check(service.unregisterCalls == 1 && result.state == .notRegistered && result.errorMessage == nil,
              "disabling unregisters the item")
        _ = controller.setEnabled(false)
        check(service.unregisterCalls == 1 && service.registerCalls == 1,
              "a disabled item stays disabled without redundant registration")
        service.rejectRegister = true
        result = controller.setEnabled(true)
        check(result.state == .notRegistered && result.errorMessage != nil,
              "registration failure keeps the switch off and explains recovery")
        service.rejectRegister = false
        service.registeredState = .requiresApproval
        result = controller.setEnabled(true)
        check(result.state == .requiresApproval && result.state.isRequested && result.errorMessage == nil,
              "pending approval is distinct from enabled and retains the user's requested registration")
        let beforePending = service.registerCalls
        _ = controller.setEnabled(true)
        check(service.registerCalls == beforePending, "pending approval does not re-register or bypass the system decision")
        controller.openSettings()
        check(service.settingsCalls == 1, "the approval action opens login item settings")
        result = controller.setEnabled(false)
        check(result.state == .notRegistered, "pending approval can also be cancelled")
        service.state = .enabled
        check(controller.state == .enabled, "external system changes are reflected without stale saved preferences")
        service.rejectUnregister = true
        result = controller.setEnabled(false)
        check(result.state == .enabled && result.errorMessage != nil,
              "unregistration failure preserves the actual enabled state")
        service.state = .notFound
        service.registeredState = .enabled
        result = controller.setEnabled(true)
        check(result.state == .enabled && result.errorMessage == nil,
              "a first registration can create an item whose initial system status is not found")
        service.state = .notFound
        service.rejectRegister = true
        result = controller.setEnabled(true)
        check(result.state == .notFound && result.errorMessage != nil,
              "a genuinely failed registration cannot be reported as enabled")
        service.rejectRegister = false
        service.registeredState = .notFound
        result = controller.setEnabled(true)
        check(result.state == .notFound && result.errorMessage != nil,
              "a registration that returns without an enabled or pending system status reports failure")

        func event(_ eventID: AEEventID = AEEventID(kAEOpenApplication), launchReason: OSType? = nil) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: eventID,
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            if let launchReason {
                event.setParam(NSAppleEventDescriptor(enumCode: launchReason), forKeyword: AEKeyword(keyAEPropData))
            }
            return event
        }
        check(!LoginItemLaunch.shouldShowWindow(for: event(launchReason: OSType(keyAELaunchedAsLogInItem))),
              "a system login launch stays in the menu bar without opening the main window")
        check(LoginItemLaunch.shouldShowWindow(for: event()), "an ordinary manual launch opens the main window")
        check(LoginItemLaunch.shouldShowWindow(for: nil), "an absent launch event preserves normal opening behavior")
        check(LoginItemLaunch.shouldShowWindow(for: event(AEEventID(kAEReopenApplication), launchReason: OSType(keyAELaunchedAsLogInItem))),
              "a manual reopen is not mistaken for a login launch")
        if failures > 0 { print("\(failures) login item behavior checks failed"); exit(1) }
        print("All login item behavior checks passed")
    }
}
