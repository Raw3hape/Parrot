import AppKit
import XCTest
@testable import Parrot

final class ParrotInstancePolicyTests: XCTestCase {
    func testInstalledCopyKeepsItselfAndClosesOnlyNonInstalledDuplicates() {
        let decision = ParrotInstancePolicy.decision(
            currentPID: 100,
            currentBundleURL: URL(fileURLWithPath: "/Applications/Parrot.app"),
            canonicalBundleURL: URL(fileURLWithPath: "/Applications/Parrot.app"),
            canonicalBundleExists: true,
            runningInstances: [
                .init(pid: 100, bundleURL: URL(fileURLWithPath: "/Applications/Parrot.app")),
                .init(pid: 200, bundleURL: URL(fileURLWithPath: "/tmp/DerivedData/Debug/Parrot.app")),
            ]
        )

        XCTAssertEqual(decision, .continueCurrent(terminatePIDs: [200]))
    }

    func testDebugCopyHandsOffToInstalledCopy() {
        let decision = ParrotInstancePolicy.decision(
            currentPID: 200,
            currentBundleURL: URL(fileURLWithPath: "/tmp/DerivedData/Debug/Parrot.app"),
            canonicalBundleURL: URL(fileURLWithPath: "/Applications/Parrot.app"),
            canonicalBundleExists: true,
            runningInstances: []
        )

        XCTAssertEqual(decision, .launchCanonicalAndTerminateCurrent)
    }

    func testSecondInstalledProcessHandsOffToExistingInstalledProcess() {
        let canonical = URL(fileURLWithPath: "/Applications/Parrot.app")
        let decision = ParrotInstancePolicy.decision(
            currentPID: 101,
            currentBundleURL: canonical,
            canonicalBundleURL: canonical,
            canonicalBundleExists: true,
            runningInstances: [
                .init(pid: 100, bundleURL: canonical),
                .init(pid: 101, bundleURL: canonical),
            ]
        )

        XCTAssertEqual(decision, .activateExistingAndTerminateCurrent(pid: 100))
    }
}

@MainActor
final class ParrotApplicationDelegateLifecycleTests: XCTestCase {
    func testDidFinishLaunchingBootstrapsMenuBarWithoutAnyWindowAppearing() {
        var didBootstrap = false
        let delegate = ParrotApplicationDelegate { _ in
            didBootstrap = true
        }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertTrue(didBootstrap)
    }
}

@MainActor
final class MainWindowPresentationCoordinatorTests: XCTestCase {
    private final class WindowSpy: MainWindowPresenting {
        var isReleasedWhenClosed = true
        private(set) var orderFrontCount = 0
        private(set) var makeKeyCount = 0

        func orderFrontRegardless() {
            orderFrontCount += 1
        }

        func makeKeyAndOrderFront(_ sender: Any?) {
            makeKeyCount += 1
        }
    }

    func testPresentReusesExistingWindowAndBringsItForward() {
        let window = WindowSpy()
        var activateCount = 0
        var createCount = 0
        let coordinator = MainWindowPresentationCoordinator(
            existingWindow: { window },
            createWindow: {
                createCount += 1
                return WindowSpy()
            },
            activateApplication: { activateCount += 1 }
        )

        XCTAssertTrue(coordinator.present())

        XCTAssertEqual(createCount, 0)
        XCTAssertEqual(activateCount, 1)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.orderFrontCount, 1)
        XCTAssertEqual(window.makeKeyCount, 1)
    }

    func testPresentCreatesWindowWhenSwiftUISceneDoesNotExist() {
        let window = WindowSpy()
        var activateCount = 0
        var createCount = 0
        let coordinator = MainWindowPresentationCoordinator(
            existingWindow: { nil },
            createWindow: {
                createCount += 1
                return window
            },
            activateApplication: { activateCount += 1 }
        )

        XCTAssertTrue(coordinator.present())

        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(activateCount, 1)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.orderFrontCount, 1)
        XCTAssertEqual(window.makeKeyCount, 1)
    }

    func testPresentFailsCleanlyWhenNoWindowCanBeCreated() {
        var activateCount = 0
        let coordinator = MainWindowPresentationCoordinator(
            existingWindow: { nil },
            createWindow: { nil },
            activateApplication: { activateCount += 1 }
        )

        XCTAssertFalse(coordinator.present())
        XCTAssertEqual(activateCount, 0)
    }
}
