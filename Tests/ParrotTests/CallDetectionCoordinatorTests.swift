import XCTest
@testable import Parrot

@MainActor
final class CallDetectionCoordinatorTests: XCTestCase {
    /// A scheduling delay is not a coordinator failure. Wait for the observable
    /// state with a deadline instead of assuming a 10 ms task runs within 30 ms.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Coordinator state did not settle before deadline", file: file, line: line)
    }

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
        await waitUntil { coordinator.suggestion != nil }

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
        await waitUntil { coordinator.suggestion != nil }
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
        await waitUntil { coordinator.suggestion != nil }
        XCTAssertNotNil(coordinator.suggestion)

        coordinator.setRecordingActive(true)
        coordinator.setRecordingActive(false)
        monitor.emit([slackActivity()])

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
        await waitUntil { coordinator.suggestion != nil }

        coordinator.dismissSuggestion()
        monitor.emit([slackActivity()])

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
        await waitUntil { coordinator.suggestion != nil }
        XCTAssertNotNil(coordinator.suggestion)

        monitor.emit([])
        XCTAssertNotNil(coordinator.suggestion)
        await waitUntil { coordinator.suggestion == nil }

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
