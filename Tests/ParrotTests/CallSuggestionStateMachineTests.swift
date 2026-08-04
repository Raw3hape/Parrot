import XCTest
@testable import Parrot

final class CallSuggestionStateMachineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testCandidateMustRemainActiveForFourSeconds() {
        var machine = CallSuggestionStateMachine(
            debounceInterval: 4,
            idleResetInterval: 12
        )
        let candidate = makeCandidate(family: "browser.chrome")

        machine.update(candidate: candidate, now: start, isRecording: false)
        machine.update(
            candidate: candidate,
            now: start.addingTimeInterval(3.99),
            isRecording: false
        )
        XCTAssertNil(machine.suggestion)

        machine.update(
            candidate: candidate,
            now: start.addingTimeInterval(4),
            isRecording: false
        )
        XCTAssertEqual(machine.suggestion, candidate)
    }

    func testTransientActivityNeverCreatesSuggestion() {
        var machine = CallSuggestionStateMachine()
        let candidate = makeCandidate(family: "native.slack")

        machine.update(candidate: candidate, now: start, isRecording: false)
        machine.update(
            candidate: nil,
            now: start.addingTimeInterval(2),
            isRecording: false
        )
        machine.update(
            candidate: candidate,
            now: start.addingTimeInterval(20),
            isRecording: false
        )

        XCTAssertNil(machine.suggestion)
    }

    func testDismissSuppressesSameSessionUntilTwelveSecondsOfIdle() {
        var machine = CallSuggestionStateMachine()
        let candidate = makeCandidate(family: "browser.chrome")
        show(candidate, in: &machine, at: start)

        machine.dismiss(now: start.addingTimeInterval(5))
        machine.update(
            candidate: candidate,
            now: start.addingTimeInterval(50),
            isRecording: false
        )
        XCTAssertNil(machine.suggestion)

        machine.update(
            candidate: nil,
            now: start.addingTimeInterval(51),
            isRecording: false
        )
        machine.update(
            candidate: nil,
            now: start.addingTimeInterval(63),
            isRecording: false
        )
        machine.update(
            candidate: candidate,
            now: start.addingTimeInterval(64),
            isRecording: false
        )
        machine.update(
            candidate: candidate,
            now: start.addingTimeInterval(68),
            isRecording: false
        )

        XCTAssertEqual(machine.suggestion, candidate)
    }

    func testRecordingSuppressesCurrentCallBeforeAndAfterStop() {
        var machine = CallSuggestionStateMachine()
        let candidate = makeCandidate(family: "native.zoom")

        machine.update(candidate: candidate, now: start, isRecording: true)
        machine.update(
            candidate: candidate,
            now: start.addingTimeInterval(30),
            isRecording: false
        )

        XCTAssertNil(machine.suggestion)
        XCTAssertEqual(machine.suppressedSessionKey, "native.zoom")
    }

    func testAcceptSuppressesCallEvenIfRecordingStartLaterFails() {
        var machine = CallSuggestionStateMachine()
        let candidate = makeCandidate(family: "native.telegram")
        show(candidate, in: &machine, at: start)

        machine.accept(now: start.addingTimeInterval(5))
        machine.update(
            candidate: candidate,
            now: start.addingTimeInterval(10),
            isRecording: false
        )

        XCTAssertNil(machine.suggestion)
        XCTAssertEqual(machine.suppressedSessionKey, "native.telegram")
    }

    func testHelperProcessChangeDoesNotRestartDebounce() {
        var machine = CallSuggestionStateMachine()
        let app = makeCandidate(
            family: "system.facetime",
            detail: "FaceTime is using the microphone"
        )
        let helper = makeCandidate(
            family: "system.facetime",
            detail: "FaceTime"
        )

        machine.update(candidate: app, now: start, isRecording: false)
        machine.update(
            candidate: helper,
            now: start.addingTimeInterval(3),
            isRecording: false
        )
        machine.update(
            candidate: helper,
            now: start.addingTimeInterval(4),
            isRecording: false
        )

        XCTAssertEqual(machine.suggestion, helper)
    }

    func testDifferentSourceCanPromptAfterCurrentSessionWasDismissed() {
        var machine = CallSuggestionStateMachine()
        let slack = makeCandidate(family: "native.slack")
        let chrome = makeCandidate(family: "browser.chrome")
        show(slack, in: &machine, at: start)
        machine.dismiss(now: start.addingTimeInterval(5))

        machine.update(
            candidate: chrome,
            now: start.addingTimeInterval(6),
            isRecording: false
        )
        machine.update(
            candidate: chrome,
            now: start.addingTimeInterval(10),
            isRecording: false
        )

        XCTAssertEqual(machine.suggestion, chrome)
    }

    func testOpenSuggestionClosesAfterCallRemainsIdle() {
        var machine = CallSuggestionStateMachine()
        let candidate = makeCandidate(family: "native.viber")
        show(candidate, in: &machine, at: start)

        machine.update(
            candidate: nil,
            now: start.addingTimeInterval(5),
            isRecording: false
        )
        XCTAssertEqual(machine.suggestion, candidate)

        machine.update(
            candidate: nil,
            now: start.addingTimeInterval(17),
            isRecording: false
        )
        XCTAssertNil(machine.suggestion)
    }

    private func show(
        _ candidate: CallCandidate,
        in machine: inout CallSuggestionStateMachine,
        at date: Date
    ) {
        machine.update(candidate: candidate, now: date, isRecording: false)
        machine.update(
            candidate: candidate,
            now: date.addingTimeInterval(4),
            isRecording: false
        )
        XCTAssertEqual(machine.suggestion, candidate)
    }

    private func makeCandidate(
        family: String,
        detail: String = "Call app is using the microphone"
    ) -> CallCandidate {
        .init(
            source: .init(
                familyID: family,
                displayName: "Call app",
                applicationName: "Call app",
                kind: .native
            ),
            promptDetail: detail,
            confidence: .audioConfirmed
        )
    }
}
