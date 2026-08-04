import XCTest
@testable import Parrot

final class AudioTimelineStoreTests: XCTestCase {
    func testTimelineRoundTripsByMeetingID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParrotTimelineTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let manifest = AudioTimelineManifest(
            schemaVersion: AudioTimelineManifest.schemaVersion,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tracks: [
                .init(
                    speaker: .them,
                    startOffset: 0.1,
                    frameCount: 16_000,
                    sampleRate: 16_000,
                    droppedFrameRanges: []
                ),
                .init(
                    speaker: .me,
                    startOffset: 0.4,
                    frameCount: 15_900,
                    sampleRate: 16_000,
                    droppedFrameRanges: [100..<120]
                ),
            ]
        )

        try AudioTimelineStore.save(
            manifest,
            meetingID: meetingID,
            rootDirectory: root
        )

        XCTAssertEqual(
            AudioTimelineStore.load(
                meetingID: meetingID,
                rootDirectory: root
            ),
            manifest
        )
        try AudioTimelineStore.remove(
            meetingID: meetingID,
            rootDirectory: root
        )
        XCTAssertNil(
            AudioTimelineStore.load(
                meetingID: meetingID,
                rootDirectory: root
            )
        )
    }
}
