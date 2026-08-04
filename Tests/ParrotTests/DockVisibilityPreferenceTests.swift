import XCTest
@testable import Parrot

final class DockVisibilityPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DockVisibilityPreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDockIsHiddenByDefault() {
        XCTAssertFalse(DockVisibilityPreference.isEnabled(in: defaults))
    }

    func testExplicitDockPreferenceIsRestored() {
        defaults.set(true, forKey: DockVisibilityPreference.key)
        XCTAssertTrue(DockVisibilityPreference.isEnabled(in: defaults))

        defaults.set(false, forKey: DockVisibilityPreference.key)
        XCTAssertFalse(DockVisibilityPreference.isEnabled(in: defaults))
    }
}
