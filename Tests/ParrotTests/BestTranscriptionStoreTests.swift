import XCTest
@testable import Parrot

final class BestTranscriptionStoreTests: XCTestCase {
    private var root: URL!
    private var store: BestTranscriptionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParrotBestStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = BestTranscriptionStore(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        store = nil
        root = nil
    }

    func testCompletedArtifactRoundTripsOnlyForExactFingerprint() async throws {
        let meetingID = UUID()
        let fingerprint = makeFingerprint(vocabularyHash: "one")
        let artifact = makeArtifact(meetingID: meetingID, fingerprint: fingerprint)

        try await store.saveCompletedArtifact(artifact)

        let loaded = try await store.loadCompletedArtifact(
            meetingID: meetingID,
            fingerprint: fingerprint
        )
        XCTAssertEqual(loaded, artifact)

        let stale = try await store.loadCompletedArtifact(
            meetingID: meetingID,
            fingerprint: makeFingerprint(vocabularyHash: "two")
        )
        XCTAssertNil(stale)
    }

    func testCheckpointRoundTripsAndLoadsInTrackWindowOrder() async throws {
        let meetingID = UUID()
        let later = BestTranscriptionCheckpoint(
            meetingID: meetingID,
            fingerprint: makeFingerprint(),
            speaker: .me,
            window: .init(
                index: 2,
                startFrame: 20,
                endFrame: 30,
                ownedStartFrame: 21,
                ownedEndFrame: 30
            ),
            segments: []
        )
        let earlier = BestTranscriptionCheckpoint(
            meetingID: meetingID,
            fingerprint: makeFingerprint(),
            speaker: .them,
            window: .init(
                index: 0,
                startFrame: 0,
                endFrame: 10,
                ownedStartFrame: 0,
                ownedEndFrame: 9
            ),
            segments: []
        )

        try await store.saveCheckpoint(later)
        try await store.saveCheckpoint(earlier)

        let loaded = try await store.loadCheckpoints(
            meetingID: meetingID,
            fingerprint: makeFingerprint()
        )
        XCTAssertEqual(loaded.map(\.speaker), [.them, .me])
        XCTAssertEqual(loaded.map(\.window.index), [0, 2])
    }

    func testBeginningReprocessDoesNotDestroyPreviousCompletedArtifact() async throws {
        let meetingID = UUID()
        let completedFingerprint = makeFingerprint(vocabularyHash: "old")
        let artifact = makeArtifact(meetingID: meetingID, fingerprint: completedFingerprint)
        try await store.saveCompletedArtifact(artifact)

        let nextFingerprint = makeFingerprint(vocabularyHash: "new")
        try await store.saveJobManifest(
            .init(
                schemaVersion: BestTranscriptionManifest.schemaVersion,
                meetingID: meetingID,
                state: .transcribing,
                fingerprint: nextFingerprint,
                artifactFilename: nil,
                updatedAt: .now,
                lastError: nil
            )
        )
        try await store.markJob(
            meetingID: meetingID,
            state: .cancelled,
            error: nil
        )

        let stillAvailable = try await store.loadCompletedArtifact(
            meetingID: meetingID,
            fingerprint: completedFingerprint
        )
        XCTAssertEqual(stillAvailable, artifact)
    }

    func testCorruptCompletedManifestIsNeverTreatedAsReady() async throws {
        let meetingID = UUID()
        let directory = await store.directory(for: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("completed.json"),
            options: .atomic
        )

        let loaded = try await store.loadCompletedArtifact(
            meetingID: meetingID,
            fingerprint: makeFingerprint()
        )
        XCTAssertNil(loaded)
    }

    func testRemovingMeetingDeletesArtifactAndCheckpoints() async throws {
        let meetingID = UUID()
        let fingerprint = makeFingerprint()
        try await store.saveCompletedArtifact(
            makeArtifact(meetingID: meetingID, fingerprint: fingerprint)
        )

        try await store.removeMeeting(meetingID)

        let directory = await store.directory(for: meetingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeFingerprint(
        vocabularyHash: String = "same"
    ) -> BestTranscriptionFingerprint {
        .init(
            modelID: WhisperModelService.fallbackModel,
            pipelineVersion: 1,
            vocabularyHash: vocabularyHash,
            tracks: []
        )
    }

    private func makeArtifact(
        meetingID: UUID,
        fingerprint: BestTranscriptionFingerprint
    ) -> BestTranscriptArtifact {
        .init(
            meetingID: meetingID,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelID: fingerprint.modelID,
            pipelineVersion: fingerprint.pipelineVersion,
            fingerprint: fingerprint,
            alignmentQuality: .estimated,
            warnings: [],
            segments: []
        )
    }
}
