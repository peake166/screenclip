import AppKit
import Carbon
import ServiceManagement

enum LoginItemState: Equatable {
    case notRegistered, enabled, requiresApproval, notFound

    var isRequested: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
protocol LoginItemService: AnyObject {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

struct LoginItemChange {
    let state: LoginItemState
    let errorMessage: String?
}

@MainActor
final class LoginItemController {
    private let service: LoginItemService

    init(service: LoginItemService) { self.service = service }
    var state: LoginItemState { service.state }

    func setEnabled(_ enabled: Bool) -> LoginItemChange {
        let current = service.state
        // An unregistered main app may initially report notFound. Let register()
        // create its service, then validate the resulting system state below.
        guard enabled != current.isRequested else {
            return LoginItemChange(state: current, errorMessage: nil)
        }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
        } catch {
            let state = service.state
            // macOS may record the registration while still requiring the user to approve it.
            if enabled && state == .requiresApproval {
                return LoginItemChange(state: state, errorMessage: nil)
            }
            return LoginItemChange(state: state, errorMessage: enabled
                ? "未能开启登录时启动。请确认截图助手位于“应用程序”中，然后重试。"
                : "未能关闭登录时启动。请重试，或在系统设置的“登录项”中关闭。")
        }
        let state = service.state
        return LoginItemChange(state: state, errorMessage: enabled == state.isRequested ? nil
            : "登录启动设置未能生效，请重试或检查系统设置中的“登录项”。")
    }

    func openSettings() { service.openSettings() }
}

enum LoginItemLaunch {
    static func shouldShowWindow(for event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return true }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue != OSType(keyAELaunchedAsLogInItem)
    }
}

@MainActor
final class SystemLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp

    var state: LoginItemState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
