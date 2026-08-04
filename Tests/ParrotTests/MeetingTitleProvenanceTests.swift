import XCTest
@testable import Parrot

final class MeetingTitleProvenanceTests: XCTestCase {
    func testNewMeetingStartsWithDefaultTitleProvenance() {
        let meeting = Meeting(date: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(meeting.titleOriginRaw, "default")
        XCTAssertNil(meeting.titleTranscriptFingerprint)
        XCTAssertNil(meeting.titleGeneratorVersion)
        XCTAssertNil(meeting.titleGeneratedAt)
    }

    func testDefaultTitleFormatNeverMixesWithTheCurrentLocale() {
        let date = Date(timeIntervalSince1970: 1_721_813_167)

        let title = Meeting.defaultTitle(for: date)

        XCTAssertTrue(title.hasPrefix("Meeting Jul "), title)
        XCTAssertTrue(title.contains(" at "), title)
    }

    func testPlaceholderRecognitionIsStrict() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = Meeting(date: date)

        XCTAssertTrue(meeting.hasPlaceholderTitle)

        meeting.title = "Design Review"
        XCTAssertFalse(meeting.hasPlaceholderTitle)

        meeting.title = "Meeting with Lena"
        XCTAssertFalse(meeting.hasPlaceholderTitle)
    }

    func testLegacyPlaceholderSurvivesLocaleOrTimeZoneChange() {
        let meeting = Meeting(date: Date(timeIntervalSince1970: 0))
        meeting.title = "Meeting Jul 24, 2026 at 11:06 AM"

        XCTAssertFalse(meeting.hasPlaceholderTitle)
        XCTAssertTrue(meeting.hasLegacyPlaceholderTitle)

        meeting.title = "Meeting with Lena"
        XCTAssertFalse(meeting.hasLegacyPlaceholderTitle)
    }

    func testManualRenameTrimsOnlyDraftAndProtectsTitle() {
        let meeting = Meeting()

        XCTAssertTrue(meeting.applyManualTitle("  Polish onboarding   "))
        XCTAssertEqual(meeting.title, "Polish onboarding")
        XCTAssertEqual(meeting.titleOriginRaw, "manual")
        XCTAssertNil(meeting.titleTranscriptFingerprint)
    }

    func testBlankManualRenamePreservesExistingTitle() {
        let meeting = Meeting(title: "Existing title")

        XCTAssertFalse(meeting.applyManualTitle(" \n\t "))
        XCTAssertEqual(meeting.title, "Existing title")
    }

    func testSortedSegmentsHasDeterministicTieBreakers() {
        let meeting = Meeting()
        let laterEnd = TranscriptSegment(startTime: 1, endTime: 3, text: "later")
        let idB = TranscriptSegment(startTime: 1, endTime: 2, text: "b")
        let idA = TranscriptSegment(startTime: 1, endTime: 2, text: "a")
        idA.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        idB.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        meeting.segments = [laterEnd, idB, idA]

        XCTAssertEqual(meeting.sortedSegments.map(\.text), ["a", "b", "later"])
    }
}
