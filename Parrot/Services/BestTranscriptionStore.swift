import Foundation

struct BestTranscriptionCheckpoint: Codable, Equatable, Sendable {
    var meetingID: UUID
    var fingerprint: BestTranscriptionFingerprint
    var speaker: BestTranscriptSpeaker
    var window: BestAudioWindow
    var segments: [BestTranscriptSegment]
}

actor BestTranscriptionStore {
    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL = BestTranscriptionStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    nonisolated static func defaultRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Parrot", isDirectory: true)
            .appendingPathComponent("BestTranscripts", isDirectory: true)
    }

    func directory(for meetingID: UUID) -> URL {
        rootDirectory.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    func saveJobManifest(_ manifest: BestTranscriptionManifest) throws {
        let directory = directory(for: manifest.meetingID)
        try ensureDirectory(directory)
        try write(manifest, to: directory.appendingPathComponent("job.json"))
    }

    func loadJobManifest(meetingID: UUID) -> BestTranscriptionManifest? {
        decodeIfPresent(
            BestTranscriptionManifest.self,
            at: directory(for: meetingID).appendingPathComponent("job.json")
        )
    }

    func markJob(
        meetingID: UUID,
        state: BestTranscriptionPersistentState,
        error: String?
    ) throws {
        guard var manifest = loadJobManifest(meetingID: meetingID) else { return }
        manifest.state = state
        manifest.updatedAt = .now
        manifest.lastError = error
        try saveJobManifest(manifest)
    }

    func saveCheckpoint(_ checkpoint: BestTranscriptionCheckpoint) throws {
        let checkpoints = checkpointDirectory(for: checkpoint.meetingID)
        try ensureDirectory(checkpoints)
        let filename = String(
            format: "%@-%08d.json",
            checkpoint.speaker.rawValue.lowercased(),
            checkpoint.window.index
        )
        try write(checkpoint, to: checkpoints.appendingPathComponent(filename))
    }

    func loadCheckpoints(
        meetingID: UUID,
        fingerprint: BestTranscriptionFingerprint
    ) throws -> [BestTranscriptionCheckpoint] {
        let directory = checkpointDirectory(for: meetingID)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap {
            decodeIfPresent(BestTranscriptionCheckpoint.self, at: $0)
        }
        .filter { $0.meetingID == meetingID && $0.fingerprint == fingerprint }
        .sorted {
            if $0.speaker != $1.speaker { return $0.speaker == .them }
            return $0.window.index < $1.window.index
        }
    }

    func saveCompletedArtifact(_ artifact: BestTranscriptArtifact) throws {
        let directory = directory(for: artifact.meetingID)
        try ensureDirectory(directory)

        let previous = decodeIfPresent(
            BestTranscriptionManifest.self,
            at: directory.appendingPathComponent("completed.json")
        )
        let artifactFilename = "artifact-\(UUID().uuidString).json"
        let artifactURL = directory.appendingPathComponent(artifactFilename)
        try write(artifact, to: artifactURL)

        do {
            let manifest = BestTranscriptionManifest.completed(
                meetingID: artifact.meetingID,
                fingerprint: artifact.fingerprint,
                artifactFilename: artifactFilename
            )
            try write(manifest, to: directory.appendingPathComponent("completed.json"))
        } catch {
            try? FileManager.default.removeItem(at: artifactURL)
            throw error
        }

        if let oldFilename = previous?.artifactFilename,
           oldFilename != artifactFilename {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(oldFilename)
            )
        }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("job.json")
        )
        try? FileManager.default.removeItem(at: checkpointDirectory(for: artifact.meetingID))
    }

    func loadCompletedArtifact(
        meetingID: UUID,
        fingerprint: BestTranscriptionFingerprint
    ) throws -> BestTranscriptArtifact? {
        let directory = directory(for: meetingID)
        guard let manifest = decodeIfPresent(
            BestTranscriptionManifest.self,
            at: directory.appendingPathComponent("completed.json")
        ),
        manifest.meetingID == meetingID,
        manifest.hasValidCompletedArtifact(for: fingerprint),
        let filename = manifest.artifactFilename,
        let artifact = decodeIfPresent(
            BestTranscriptArtifact.self,
            at: directory.appendingPathComponent(filename)
        ),
        artifact.meetingID == meetingID,
        artifact.fingerprint == fingerprint else {
            return nil
        }
        return artifact
    }

    func loadLatestCompletedArtifact(meetingID: UUID) -> BestTranscriptArtifact? {
        let directory = directory(for: meetingID)
        guard let manifest = decodeIfPresent(
            BestTranscriptionManifest.self,
            at: directory.appendingPathComponent("completed.json")
        ),
        manifest.meetingID == meetingID,
        manifest.state == .completed,
        let filename = manifest.artifactFilename else {
            return nil
        }
        return decodeIfPresent(
            BestTranscriptArtifact.self,
            at: directory.appendingPathComponent(filename)
        )
    }

    func removeMeeting(_ meetingID: UUID) throws {
        let directory = directory(for: meetingID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func resetPendingJob(meetingID: UUID) throws {
        let directory = directory(for: meetingID)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("job.json")
        )
        try? FileManager.default.removeItem(at: checkpointDirectory(for: meetingID))
    }

    private func checkpointDirectory(for meetingID: UUID) -> URL {
        directory(for: meetingID).appendingPathComponent("checkpoints", isDirectory: true)
    }

    private func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func decodeIfPresent<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
