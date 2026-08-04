import Foundation

struct AudioTimelineAccumulator: Sendable {
    let capturedAt: Date
    private var firstOffsets: [BestTranscriptSpeaker: TimeInterval] = [:]
    private var frameCounts: [BestTranscriptSpeaker: Int64] = [:]

    init(capturedAt: Date) {
        self.capturedAt = capturedAt
    }

    mutating func noteFirstBuffer(
        for speaker: BestTranscriptSpeaker,
        offset: TimeInterval
    ) {
        guard firstOffsets[speaker] == nil else { return }
        firstOffsets[speaker] = max(0, offset.isFinite ? offset : 0)
    }

    mutating func addFrames(
        _ count: Int,
        for speaker: BestTranscriptSpeaker
    ) {
        guard count > 0 else { return }
        frameCounts[speaker, default: 0] += Int64(count)
    }

    func manifest(sampleRate: Double) -> AudioTimelineManifest {
        let tracks = BestTranscriptSpeaker.allCases.compactMap {
            speaker -> AudioTimelineManifest.Track? in
            let frames = frameCounts[speaker, default: 0]
            guard frames > 0 else { return nil }
            return .init(
                speaker: speaker,
                startOffset: firstOffsets[speaker] ?? 0,
                frameCount: frames,
                sampleRate: sampleRate,
                droppedFrameRanges: []
            )
        }
        .sorted { $0.speaker == .them && $1.speaker == .me }
        return AudioTimelineManifest(
            schemaVersion: AudioTimelineManifest.schemaVersion,
            capturedAt: capturedAt,
            tracks: tracks
        )
    }
}

enum AudioTimelineStore {
    static func defaultRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Parrot", isDirectory: true)
            .appendingPathComponent("AudioTimelines", isDirectory: true)
    }

    static func save(
        _ manifest: AudioTimelineManifest,
        meetingID: UUID,
        rootDirectory: URL = defaultRootDirectory()
    ) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: url(for: meetingID, rootDirectory: rootDirectory),
            options: [.atomic]
        )
    }

    static func load(
        meetingID: UUID,
        rootDirectory: URL = defaultRootDirectory()
    ) -> AudioTimelineManifest? {
        let url = url(for: meetingID, rootDirectory: rootDirectory)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(
                  AudioTimelineManifest.self,
                  from: data
              ),
              manifest.schemaVersion == AudioTimelineManifest.schemaVersion else {
            return nil
        }
        return manifest
    }

    static func remove(
        meetingID: UUID,
        rootDirectory: URL = defaultRootDirectory()
    ) throws {
        let url = url(for: meetingID, rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func url(for meetingID: UUID, rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("\(meetingID.uuidString).json")
    }
}
