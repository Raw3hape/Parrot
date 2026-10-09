import CryptoKit
import Foundation

/// Real-model smoke test for the complete on-device Best Transcript path.
/// It prints only counts/timings, never transcript text.
enum BestTranscriptionIntegrationTest {
    static func run(
        audioPath: String,
        workerCount: Int? = nil,
        exportPath: String? = nil
    ) {
        Task { @MainActor in
            do {
                let passed = try await execute(
                    audioPath: audioPath,
                    workerCount: workerCount,
                    exportPath: exportPath
                )
                exit(passed ? 0 : 2)
            } catch {
                FileHandle.standardError.write(
                    Data(
                        "diagnostic=best_transcription status=failed error_type=\(String(reflecting: type(of: error)))\n".utf8
                    )
                )
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    @MainActor
    private static func execute(
        audioPath: String,
        workerCount: Int?,
        exportPath: String?
    ) async throws -> Bool {
        let audioURL = URL(fileURLWithPath: audioPath)
        let info = try BestAudioFileReader.inspect(
            url: audioURL,
            speaker: .them
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ParrotBestIntegration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let service = WhisperModelService(exportBatchSizeOverride: workerCount)
        let store = BestTranscriptionStore(rootDirectory: temporaryRoot)
        let coordinator = BestTranscriptionCoordinator(
            recognizer: service,
            store: store
        )
        let startedAt = Date()
        let artifact = try await coordinator.process(
            BestTranscriptionRequest(
                meetingID: UUID(),
                title: "Integration test",
                date: .now,
                duration: info.duration,
                systemAudioURL: audioURL,
                micAudioURL: nil,
                vocabulary: "",
                timeline: nil
            ),
            forceReprocess: true
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let output = ExportService.exportBestTranscriptTXT(
            title: "Integration test",
            date: .now,
            duration: info.duration,
            artifact: artifact
        )
        if let exportPath {
            try output.write(
                to: URL(fileURLWithPath: exportPath),
                atomically: true,
                encoding: .utf8
            )
        }
        let timestampsValid = artifact.segments.allSatisfy {
            $0.startTime.isFinite
                && $0.endTime.isFinite
                && $0.startTime >= 0
                && $0.endTime > $0.startTime
        }
        let containsSpecialTokens = output.contains("<|")
        let content = artifact.segments.map { segment in
            "\(segment.speaker.rawValue)|\(segment.startTime)|\(segment.endTime)|\(segment.text)"
        }.joined(separator: "\n")
        let contentHash = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        print("diagnostic: best_transcription")
        print("window_batch_size: \(service.preferredWindowBatchSize)")
        print(String(format: "audio_seconds: %.3f", info.duration))
        print(String(format: "decode_seconds: %.3f", elapsed))
        print(String(format: "real_time_factor: %.3f", elapsed / max(info.duration, 0.001)))
        print("segments: \(artifact.segments.count)")
        print("transcript_characters: \(artifact.segments.reduce(0) { $0 + $1.text.count })")
        print("content_sha256: \(contentHash)")
        print("timestamps_valid: \(timestampsValid ? 1 : 0)")
        print("contains_special_tokens: \(containsSpecialTokens ? 1 : 0)")
        print("warnings: \(artifact.warnings.count)")

        return !artifact.segments.isEmpty
            && artifact.segments.allSatisfy {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            && timestampsValid
            && !containsSpecialTokens
    }
}
