import XCTest
@testable import Parrot

final class MeetingTitleSnapshotBuilderTests: XCTestCase {
    func testDefaultLeafBudgetFitsEightKRuntimeContextWithPromptHeadroom() {
        let oversized = String(repeating: "x", count: 20 * 1024)

        let snapshot = MeetingTitleSnapshotBuilder().build(from: [
            source(start: 0, end: 1, text: oversized),
        ])

        XCTAssertFalse(snapshot.leaves.isEmpty)
        XCTAssertTrue(snapshot.leaves.allSatisfy { $0.utf8ByteCount <= 7 * 1024 })
    }

    func testSnapshotUsesStableChronologicalOrderingWithDeterministicTieBreaks() {
        let later = source(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            start: 4,
            end: 5,
            text: "later"
        )
        let tieB = source(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            start: 1,
            end: 2,
            text: "tie B"
        )
        let tieA = source(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            start: 1,
            end: 2,
            text: "tie A"
        )

        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 64).build(
            from: [later, tieB, tieA]
        )

        XCTAssertEqual(snapshot.orderedSegments.map(\.id), [tieA.id, tieB.id, later.id])
    }

    func testSnapshotPreservesWhitespaceAndUnicodeByteForByte() {
        let text = "  Zażółć\tgęślą\nПривет 👩🏽‍💻  \r\n"
        let segment = source(start: 0, end: 1, text: text)

        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 7).build(from: [segment])

        XCTAssertEqual(snapshot.reconstructedText(for: segment.id), text)
        XCTAssertEqual(
            Array(snapshot.reconstructedText(for: segment.id)?.utf8 ?? "".utf8),
            Array(text.utf8)
        )
        XCTAssertTrue(snapshot.coverageReceipt.isExact)
    }

    func testOversizedSegmentIsBoundedAndReconstructsWithoutLoss() {
        let text = String(repeating: "ważny проект launch 👋 ", count: 500)
        let segment = source(start: 0, end: 10, text: text)
        let limit = 96

        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: limit).build(from: [segment])

        XCTAssertGreaterThan(snapshot.leaves.count, 1)
        XCTAssertTrue(snapshot.leaves.allSatisfy { $0.utf8ByteCount <= limit + 4 })
        XCTAssertEqual(snapshot.reconstructedText(for: segment.id), text)
        XCTAssertTrue(snapshot.coverageReceipt.isExact)
    }

    func testFingerprintChangesForAnyRawTranscriptChange() {
        let id = UUID()
        let builder = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 64)
        let original = builder.build(from: [source(id: id, start: 0, end: 1, text: "project launch")])
        let whitespaceChanged = builder.build(from: [source(id: id, start: 0, end: 1, text: "project  launch")])
        let speakerChanged = builder.build(
            from: [source(id: id, start: 0, end: 1, speaker: "Me", text: "project launch")]
        )

        XCTAssertNotEqual(original.fingerprint, whitespaceChanged.fingerprint)
        XCTAssertNotEqual(original.fingerprint, speakerChanged.fingerprint)
        XCTAssertEqual(
            original.fingerprint,
            builder.build(from: [source(id: id, start: 0, end: 1, text: "project launch")]).fingerprint
        )
    }

    func testTenThousandSegmentsHaveExactOnceCoverage() {
        let segments = (0..<10_000).map { index in
            source(
                id: deterministicUUID(index),
                start: Double(index),
                end: Double(index) + 0.5,
                text: "segment \(index) projekt проект project"
            )
        }

        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 256).build(from: segments)

        XCTAssertEqual(snapshot.orderedSegments.count, 10_000)
        XCTAssertEqual(Set(snapshot.coverageReceipt.sourceSegmentIDs).count, 10_000)
        XCTAssertTrue(snapshot.coverageReceipt.isExact)
        XCTAssertEqual(snapshot.coverageReceipt.sourceUTF8ByteCount, segments.reduce(0) { $0 + $1.text.utf8.count })
        XCTAssertEqual(snapshot.coverageReceipt.coveredUTF8ByteCount, snapshot.coverageReceipt.sourceUTF8ByteCount)
    }

    func testEmptySegmentsStillParticipateInCoverage() {
        let empty = source(start: 0, end: 0, text: "")
        let whitespace = source(start: 1, end: 2, text: " \n\t")

        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 8).build(from: [empty, whitespace])

        XCTAssertEqual(Set(snapshot.coverageReceipt.sourceSegmentIDs), Set([empty.id, whitespace.id]))
        XCTAssertEqual(snapshot.reconstructedText(for: empty.id), "")
        XCTAssertEqual(snapshot.reconstructedText(for: whitespace.id), " \n\t")
        XCTAssertTrue(snapshot.coverageReceipt.isExact)
    }

    private func source(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        speaker: String? = nil,
        text: String
    ) -> MeetingTitleSourceSegment {
        MeetingTitleSourceSegment(
            id: id,
            startTime: start,
            endTime: end,
            speakerLabel: speaker,
            text: text
        )
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}
