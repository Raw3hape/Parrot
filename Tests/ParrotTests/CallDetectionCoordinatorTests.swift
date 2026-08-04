import XCTest
@testable import Parrot

@MainActor
final class CallDetectionCoordinatorTests: XCTestCase {
    func testSustainedActivityPublishesExactlyOneSuggestion() async {
        let monitor = FakeAudioProcessMonitor()
        let windows = FakeCallWindowProvider()
        let coordinator = CallDetectionCoordinator(
            monitor: monitor,
            windowProvider: windows,
            debounceInterval: 0.02,
            idleResetInterval: 0.03
        )
        var published: [CallCandidate?] = []
        coordinator.onSuggestionChanged = { published.append($0) }

        coordinator.start()
        monitor.emit([slackActivity()])
        monitor.emit([slackActivity()])
        monitor.emit([slackActivity()])
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(coordinator.suggestion?.source.familyID, "native.slack")
        XCTAssertEqual(published.compactMap { $0 }.count, 1)
        XCTAssertTrue(monitor.isMonitoring)
    }

    func testDisablingStopsMonitorAndHidesOpenSuggestion() async {
        let monitor = FakeAudioProcessMonitor()
        let coordinator = CallDetectionCoordinator(
            monitor: monitor,
            windowProvider: FakeCallWindowProvider(),
            debounceInterval: 0.01,
            idleResetInterval: 0.02
        )
        coordinator.start()
        monitor.emit([slackActivity()])
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(coordinator.suggestion)

        coordinator.setEnabled(false)

        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertNil(coordinator.suggestion)
    }

    func testRecordingStateSuppressesOpenSuggestionForSameCall() async {
        let monitor = FakeAudioProcessMonitor()
        let coordinator = CallDetectionCoordinator(
            monitor: monitor,
            windowProvider: FakeCallWindowProvider(),
            debounceInterval: 0.01,
            idleResetInterval: 0.02
        )
        coordinator.start()
        monitor.emit([slackActivity()])
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(coordinator.suggestion)

        coordinator.setRecordingActive(true)
        coordinator.setRecordingActive(false)
        monitor.emit([slackActivity()])
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(coordinator.suggestion)
        XCTAssertEqual(coordinator.suppressedSessionKey, "native.slack")
    }

    func testDismissalClosesSuggestionAndDoesNotRepromptSameActivity() async {
        let monitor = FakeAudioProcessMonitor()
        let coordinator = CallDetectionCoordinator(
            monitor: monitor,
            windowProvider: FakeCallWindowProvider(),
            debounceInterval: 0.01,
            idleResetInterval: 0.02
        )
        coordinator.start()
        monitor.emit([slackActivity()])
        try? await Task.sleep(nanoseconds: 30_000_000)

        coordinator.dismissSuggestion()
        monitor.emit([slackActivity()])
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(coordinator.suggestion)
        XCTAssertEqual(coordinator.suppressedSessionKey, "native.slack")
    }

    func testCallEndClearsSuggestionAfterIdleGrace() async {
        let monitor = FakeAudioProcessMonitor()
        let coordinator = CallDetectionCoordinator(
            monitor: monitor,
            windowProvider: FakeCallWindowProvider(),
            debounceInterval: 0.01,
            idleResetInterval: 0.02
        )
        coordinator.start()
        monitor.emit([slackActivity()])
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(coordinator.suggestion)

        monitor.emit([])
        XCTAssertNotNil(coordinator.suggestion)
        try? await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertNil(coordinator.suggestion)
    }

    func testWindowProviderIsConsultedOnlyAfterAudioActivity() {
        let monitor = FakeAudioProcessMonitor()
        let windows = FakeCallWindowProvider()
        let coordinator = CallDetectionCoordinator(
            monitor: monitor,
            windowProvider: windows,
            debounceInterval: 1,
            idleResetInterval: 1
        )
        coordinator.start()
        XCTAssertEqual(windows.readCount, 0)

        monitor.emit([])
        XCTAssertEqual(windows.readCount, 0)

        monitor.emit([slackActivity()])
        XCTAssertEqual(windows.readCount, 1)
    }

    private func slackActivity() -> AudioProcessActivity {
        .init(
            audioObjectID: 7,
            processID: 99,
            bundleIdentifier: "com.tinyspeck.slackmacgap.helper",
            applicationName: "Slack Helper",
            isInputActive: true,
            isOutputActive: true
        )
    }
}

@MainActor
private final class FakeAudioProcessMonitor: AudioProcessMonitoring {
    var onActivitiesChanged: (([AudioProcessActivity]) -> Void)?
    private(set) var isMonitoring = false

    func start() {
        isMonitoring = true
    }

    func stop() {
        isMonitoring = false
    }

    func emit(_ activities: [AudioProcessActivity]) {
        guard isMonitoring else { return }
        onActivitiesChanged?(activities)
    }
}

@MainActor
private final class FakeCallWindowProvider: CallWindowProviding {
    private(set) var readCount = 0
    var result: [CallWindowInfo] = []

    func currentWindows() -> [CallWindowInfo] {
        readCount += 1
        return result
    }
}
