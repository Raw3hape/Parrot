import XCTest
@testable import Parrot

final class RecordingNavigationPolicyTests: XCTestCase {
    func testRecordingCanContinueWhileAnotherSectionIsVisible() {
        let state = RecordingNavigationPolicy.presentation(
            isRecording: true,
            prefersLiveRecording: false
        )

        XCTAssertEqual(state, .selectedDestinationWithRecordingBanner)
    }

    func testNewRecordingDestinationReturnsToLiveView() {
        let state = RecordingNavigationPolicy.presentation(
            isRecording: true,
            prefersLiveRecording: true
        )

        XCTAssertEqual(state, .liveRecording)
    }

    func testIdleNavigationNeverShowsRecordingControls() {
        let state = RecordingNavigationPolicy.presentation(
            isRecording: false,
            prefersLiveRecording: true
        )

        XCTAssertEqual(state, .selectedDestination)
    }
}
