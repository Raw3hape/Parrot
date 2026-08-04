import AppKit
import Observation
import ServiceManagement

enum CallDetectionPreference {
    static let key = "callDetectionEnabled"
    static let defaultValue = true

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum LaunchAtLoginPreference {
    static let key = "launchAtLogin"
    static let defaultValue = true

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum LoginItemRegistrationPolicy {
    static func canManage(
        bundleURL: URL = Bundle.main.bundleURL,
        isRunningTests: Bool = ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] != nil
    ) -> Bool {
        guard !isRunningTests else { return false }
        return bundleURL.standardizedFileURL.path == "/Applications/Parrot.app"
    }
}

enum LaunchAtLoginStatus: Equatable {
    case unavailable
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case failed(String)
}

@MainActor
protocol LoginItemServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
private final class SystemLoginItemService: LoginItemServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .failed("macOS returned an unknown Login Item state.")
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

@MainActor
@Observable
final class LaunchAtLoginController {
    static let shared = LaunchAtLoginController()

    private let service: LoginItemServicing
    private let defaults: UserDefaults
    private let canManageService: Bool

    private(set) var status: LaunchAtLoginStatus

    init(
        service: LoginItemServicing? = nil,
        defaults: UserDefaults = .standard,
        canManageService: Bool = LoginItemRegistrationPolicy.canManage()
    ) {
        let resolvedService = service ?? SystemLoginItemService()
        self.service = resolvedService
        self.defaults = defaults
        self.canManageService = canManageService
        status = canManageService ? resolvedService.status : .unavailable
    }

    func synchronizeAtStartup() {
        guard canManageService else {
            status = .unavailable
            return
        }

        let wantsLaunchAtLogin = LaunchAtLoginPreference.isEnabled(in: defaults)
        let currentStatus = service.status
        do {
            if wantsLaunchAtLogin {
                if currentStatus == .notRegistered || currentStatus == .notFound {
                    try service.register()
                }
            } else if currentStatus != .notRegistered {
                try service.unregister()
            }
            status = service.status
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: LaunchAtLoginPreference.key)
        guard canManageService else {
            status = .unavailable
            return
        }

        do {
            if isEnabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            status = service.status
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func refreshStatus() {
        status = canManageService ? service.status : .unavailable
    }

    func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
