import Foundation

/// Real-model smoke test for the complete on-device Best Transcript path.
/// It prints only counts/timings, never transcript text.
enum BestTranscriptionIntegrationTest {
    static func run(audioPath: String) {
        Task { @MainActor in
            do {
                let passed = try await execute(audioPath: audioPath)
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
    private static func execute(audioPath: String) async throws -> Bool {
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

        let service = WhisperModelService()
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
        let timestampsValid = artifact.segments.allSatisfy {
            $0.startTime.isFinite
                && $0.endTime.isFinite
                && $0.startTime >= 0
                && $0.endTime > $0.startTime
        }
        let containsSpecialTokens = output.contains("<|")

        print("diagnostic: best_transcription")
        print(String(format: "audio_seconds: %.3f", info.duration))
        print(String(format: "decode_seconds: %.3f", elapsed))
        print(String(format: "real_time_factor: %.3f", elapsed / max(info.duration, 0.001)))
        print("segments: \(artifact.segments.count)")
        print("transcript_characters: \(artifact.segments.reduce(0) { $0 + $1.text.count })")
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
