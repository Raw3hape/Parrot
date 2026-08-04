import XCTest
@testable import Parrot

final class MeetingPresentationPolicyTests: XCTestCase {
    func testSidebarRowUsesAValueSnapshotInsteadOfReadingTheModelDuringRemoval() {
        let date = Date(timeIntervalSince1970: 1234)
        let meeting = Meeting(title: "Audio route test", date: date)
        meeting.duration = 65
        meeting.status = .done

        let snapshot = MeetingRowSnapshot(meeting: meeting)

        meeting.title = "Changed after snapshot"
        meeting.status = .failed
        XCTAssertEqual(snapshot.title, "Audio route test")
        XCTAssertEqual(snapshot.date, date)
        XCTAssertEqual(snapshot.formattedDuration, "1:05")
        XCTAssertEqual(snapshot.status, .done)
    }

    func testPendingDeletionIsRemovedFromSidebarBeforeSwiftDataDelete() {
        let deletingID = UUID()
        let otherID = UUID()

        XCTAssertFalse(
            MeetingPresentationPolicy.shouldPresentMeeting(
                id: deletingID,
                pendingDeletionIDs: [deletingID]
            )
        )
        XCTAssertTrue(
            MeetingPresentationPolicy.shouldPresentMeeting(
                id: otherID,
                pendingDeletionIDs: [deletingID]
            )
        )
    }

    func testPlayerRequiresFinishedCaptureAndReadableAudio() {
        XCTAssertFalse(
            MeetingPresentationPolicy.shouldShowPlayer(
                status: .recording,
                hasPlayableAudio: true
            )
        )
        XCTAssertFalse(
            MeetingPresentationPolicy.shouldShowPlayer(
                status: .done,
                hasPlayableAudio: false
            )
        )
        XCTAssertTrue(
            MeetingPresentationPolicy.shouldShowPlayer(
                status: .processing,
                hasPlayableAudio: true
            )
        )
        XCTAssertTrue(
            MeetingPresentationPolicy.shouldShowPlayer(
                status: .failed,
                hasPlayableAudio: true
            )
        )
    }

    func testProcessingPresentationKeepsPartialTranscriptVisible() {
        let presentation = MeetingPresentationPolicy.transcriptPresentation(
            status: .processing,
            segmentCount: 3,
            errorMessage: nil
        )

        XCTAssertTrue(presentation.showsProgress)
        XCTAssertTrue(presentation.showsTranscript)
        XCTAssertEqual(presentation.tone, .progress)
        XCTAssertEqual(presentation.message, "Finalizing the local transcript…")
    }

    func testDoneMeetingWithoutSegmentsHasHonestEmptyMessage() {
        let presentation = MeetingPresentationPolicy.transcriptPresentation(
            status: .done,
            segmentCount: 0,
            errorMessage: nil
        )

        XCTAssertFalse(presentation.showsProgress)
        XCTAssertFalse(presentation.showsTranscript)
        XCTAssertEqual(presentation.tone, .information)
        XCTAssertEqual(presentation.message, "No speech was transcribed for this meeting.")
    }

    func testFailedPresentationUsesStoredErrorAndKeepsPartialTranscript() {
        let presentation = MeetingPresentationPolicy.transcriptPresentation(
            status: .failed,
            segmentCount: 2,
            errorMessage: "  Local transcription timed out.  "
        )

        XCTAssertFalse(presentation.showsProgress)
        XCTAssertTrue(presentation.showsTranscript)
        XCTAssertEqual(presentation.tone, .error)
        XCTAssertEqual(presentation.message, "Local transcription timed out.")
    }

    func testFailedPresentationHasSafeFallbackMessage() {
        let presentation = MeetingPresentationPolicy.transcriptPresentation(
            status: .failed,
            segmentCount: 0,
            errorMessage: " \n "
        )

        XCTAssertEqual(
            presentation.message,
            "Transcription did not finish. Any captured audio and transcript were preserved."
        )
        XCTAssertEqual(presentation.tone, .error)
    }

    func testNotesDisclosureOnlyAppearsForMeaningfulNotes() {
        XCTAssertFalse(MeetingPresentationPolicy.shouldShowNotes(" \n\t "))
        XCTAssertTrue(MeetingPresentationPolicy.shouldShowNotes("Follow up with Lena"))
    }

    func testSearchMatchesTitleAndTranscriptCaseInsensitively() {
        XCTAssertTrue(
            MeetingPresentationPolicy.matchesSearch(
                query: "ONBOARDING",
                title: "Polish onboarding",
                transcript: ["Cześć", "Jak się masz?"]
            )
        )
        XCTAssertTrue(
            MeetingPresentationPolicy.matchesSearch(
                query: "МАШ",
                title: "Weekly sync",
                transcript: ["Привет, Маша"]
            )
        )
        XCTAssertFalse(
            MeetingPresentationPolicy.matchesSearch(
                query: "budget",
                title: "Polish onboarding",
                transcript: ["Cześć", "Jak się masz?"]
            )
        )
        XCTAssertTrue(
            MeetingPresentationPolicy.matchesSearch(
                query: " \n ",
                title: "Anything",
                transcript: []
            )
        )
    }

    func testBlankRenamePreservesExistingTitle() {
        XCTAssertEqual(
            MeetingPresentationPolicy.committedTitle(
                draft: " \n\t ",
                previousTitle: "Existing title"
            ),
            "Existing title"
        )
        XCTAssertEqual(
            MeetingPresentationPolicy.committedTitle(
                draft: "  Design review  ",
                previousTitle: "Existing title"
            ),
            "Design review"
        )
    }
}
