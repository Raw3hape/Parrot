import XCTest
@testable import Parrot

final class MenuBarPresentationPolicyTests: XCTestCase {
    func testSuggestionTakesPrecedenceOverIdleMenu() {
        XCTAssertEqual(
            MenuBarPresentationPolicy.presentation(
                isRecording: false,
                isStarting: false,
                suggestion: candidate
            ),
            .suggestion
        )
    }

    func testRecordingTakesPrecedenceOverSuggestion() {
        XCTAssertEqual(
            MenuBarPresentationPolicy.presentation(
                isRecording: true,
                isStarting: false,
                suggestion: candidate
            ),
            .recording
        )
    }

    func testStartingTakesPrecedenceOverSuggestion() {
        XCTAssertEqual(
            MenuBarPresentationPolicy.presentation(
                isRecording: false,
                isStarting: true,
                suggestion: candidate
            ),
            .starting
        )
    }

    func testIdleWithoutSuggestionShowsManualControls() {
        XCTAssertEqual(
            MenuBarPresentationPolicy.presentation(
                isRecording: false,
                isStarting: false,
                suggestion: nil
            ),
            .manual
        )
    }

    private var candidate: CallCandidate {
        .init(
            source: .init(
                familyID: "browser.chrome",
                displayName: "Google Meet",
                applicationName: "Google Chrome",
                kind: .browser
            ),
            promptDetail: "Google Meet in Google Chrome",
            confidence: .providerConfirmed
        )
    }
}
