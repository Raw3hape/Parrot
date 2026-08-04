import XCTest
@testable import Parrot

final class RecordingNavigationPolicyTests: XCTestCase {
    func testRecordingCanContinueWhileAnotherSectionIsVisible() {
        let state = RecordingNavigationPolicy.presentation(
            sessionPhase: .recording,
            prefersLiveRecording: false
        )

        XCTAssertEqual(state, .selectedDestinationWithRecordingBanner)
    }

    func testNewRecordingDestinationReturnsToLiveView() {
        let state = RecordingNavigationPolicy.presentation(
            sessionPhase: .recording,
            prefersLiveRecording: true
        )

        XCTAssertEqual(state, .liveRecording)
    }

    func testIdleNavigationNeverShowsRecordingControls() {
        let state = RecordingNavigationPolicy.presentation(
            sessionPhase: nil,
            prefersLiveRecording: true
        )

        XCTAssertEqual(state, .selectedDestination)
    }

    func testStartingSessionImmediatelyOwnsAnActiveRecordingDestination() {
        let phase = RecordingNavigationPolicy.sessionPhase(
            isStarting: true,
            isRecording: false,
            isStopping: false
        )

        XCTAssertEqual(phase, .starting)
        XCTAssertEqual(
            RecordingNavigationPolicy.presentation(
                sessionPhase: phase,
                prefersLiveRecording: true
            ),
            .liveRecording
        )
    }

    func testStoppingSessionRemainsReachableUntilFinalizationCompletes() {
        let phase = RecordingNavigationPolicy.sessionPhase(
            isStarting: false,
            isRecording: true,
            isStopping: true
        )

        XCTAssertEqual(phase, .stopping)
        XCTAssertEqual(
            RecordingNavigationPolicy.presentation(
                sessionPhase: phase,
                prefersLiveRecording: false
            ),
            .selectedDestinationWithRecordingBanner
        )
    }

    func testInactiveSessionShowsNewRecordingInsteadOfActiveRecording() {
        XCTAssertNil(
            RecordingNavigationPolicy.sessionPhase(
                isStarting: false,
                isRecording: false,
                isStopping: false
            )
        )
    }
}

final class LiveTranscriptPresentationPolicyTests: XCTestCase {
    func testEmptyLiveTranscriptAlwaysShowsImmediateStatus() {
        XCTAssertTrue(
            LiveTranscriptPresentationPolicy.shouldShowStatus(
                persistedSegmentCount: 0,
                hasInterimText: false
            )
        )
    }

    func testInterimTextReplacesListeningStatusWithoutWaitingForCommittedSegment() {
        XCTAssertFalse(
            LiveTranscriptPresentationPolicy.shouldShowStatus(
                persistedSegmentCount: 0,
                hasInterimText: true
            )
        )
    }

    func testPersistedTranscriptReturnsImmediatelyWithoutEmptyStatus() {
        XCTAssertFalse(
            LiveTranscriptPresentationPolicy.shouldShowStatus(
                persistedSegmentCount: 4,
                hasInterimText: false
            )
        )
    }
}
