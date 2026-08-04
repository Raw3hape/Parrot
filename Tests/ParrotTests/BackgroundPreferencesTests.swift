import XCTest
@testable import Parrot

final class BackgroundPreferencesTests: XCTestCase {
    func testCallDetectionDefaultsToEnabledButRespectsExplicitOptOut() {
        let defaults = isolatedDefaults()

        XCTAssertTrue(CallDetectionPreference.isEnabled(in: defaults))

        defaults.set(false, forKey: CallDetectionPreference.key)

        XCTAssertFalse(CallDetectionPreference.isEnabled(in: defaults))
    }

    func testLaunchAtLoginDefaultsToEnabledButRespectsExplicitOptOut() {
        let defaults = isolatedDefaults()

        XCTAssertTrue(LaunchAtLoginPreference.isEnabled(in: defaults))

        defaults.set(false, forKey: LaunchAtLoginPreference.key)

        XCTAssertFalse(LaunchAtLoginPreference.isEnabled(in: defaults))
    }

    func testLoginItemMayOnlyBeManagedByInstalledProductionApp() {
        let installedURL = URL(fileURLWithPath: "/Applications/Parrot.app")
        let derivedDataURL = URL(
            fileURLWithPath: "/Users/test/Library/Developer/Xcode/DerivedData/Parrot/Build/Products/Debug/Parrot.app"
        )

        XCTAssertTrue(
            LoginItemRegistrationPolicy.canManage(
                bundleURL: installedURL,
                isRunningTests: false
            )
        )
        XCTAssertFalse(
            LoginItemRegistrationPolicy.canManage(
                bundleURL: installedURL,
                isRunningTests: true
            )
        )
        XCTAssertFalse(
            LoginItemRegistrationPolicy.canManage(
                bundleURL: derivedDataURL,
                isRunningTests: false
            )
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "BackgroundPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testStartupRegistersWhenPreferenceIsEnabled() {
        let defaults = isolatedDefaults()
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            canManageService: true
        )

        controller.synchronizeAtStartup()

        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(LaunchAtLoginPreference.isEnabled(in: defaults))
    }

    func testStartupDoesNotRegisterAgainWhenApprovalIsPending() {
        let defaults = isolatedDefaults()
        let service = FakeLoginItemService(status: .requiresApproval)
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            canManageService: true
        )

        controller.synchronizeAtStartup()

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(controller.status, .requiresApproval)
    }

    func testDisablingUnregistersAndPersistsPreference() {
        let defaults = isolatedDefaults()
        let service = FakeLoginItemService(status: .enabled)
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            canManageService: true
        )

        controller.setEnabled(false)

        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(LaunchAtLoginPreference.isEnabled(in: defaults))
    }

    func testUnavailableBuildNeverTouchesSystemService() {
        let defaults = isolatedDefaults()
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            canManageService: false
        )

        controller.synchronizeAtStartup()
        controller.setEnabled(true)

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
        XCTAssertEqual(controller.status, .unavailable)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "LaunchAtLoginControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status: LaunchAtLoginStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }
}
