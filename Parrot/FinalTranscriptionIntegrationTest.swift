import CryptoKit
import Foundation

/// Explicit local QA mode. Text is emitted only when the operator passes the
/// fixture flag; normal diagnostics remain aggregate-only.
enum FinalTranscriptionIntegrationTest {
    static func run(audioPath: String, engine: String, modelRoot: String, workers: Int) {
        Task { @MainActor in
            do {
                try await execute(audioPath: audioPath, engine: engine, modelRoot: modelRoot, workers: workers)
                exit(0)
            } catch {
                let message = ["diagnostic": "final_transcript", "status": "failed", "error_type": String(reflecting: type(of: error))]
                if let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) {
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                }
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    @MainActor
    private static func execute(audioPath: String, engine: String, modelRoot: String, workers: Int) async throws {
        let source = URL(fileURLWithPath: audioPath)
        let info = try BestAudioFileReader.inspect(url: source, speaker: .them)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ParrotFinalQA-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recognizer: any BestWhisperRecognizing
        let native: NativeFinalTranscriptionService?
        if engine == "whisper" {
            native = nil
            recognizer = WhisperModelService(exportBatchSizeOverride: workers)
        } else {
            let nativeEngine = engine == "hybrid" ? "qwen" : engine
            guard let mode = NativeFinalTranscriptionService.Engine(rawValue: nativeEngine),
                  let descriptor = FinalSpeechModelCatalog.descriptor(for: nativeEngine) else {
                throw BestTranscriptionError.failed("Unknown local fixture engine.")
            }
            let directory = URL(fileURLWithPath: modelRoot, isDirectory: true)
                .appendingPathComponent(descriptor.directoryName, isDirectory: true)
            let service = NativeFinalTranscriptionService(
                engine: mode,
                modelDirectoryURL: directory,
                executableURL: FinalSpeechModelCatalog.workerURL,
                modelIdentity: descriptor.identity,
                modelDisplayName: descriptor.displayName,
                startupAdmission: {
                    SystemQwenMemoryAdmission.speechStartupDecision() == .admitted
                }
            )
            native = service
            if engine == "hybrid" {
                recognizer = HybridFinalTranscriptionService(
                    whisper: WhisperModelService(exportBatchSizeOverride: workers), native: service
                )
            } else {
                recognizer = service
            }
        }
        let coordinator = BestTranscriptionCoordinator(recognizer: recognizer, store: BestTranscriptionStore(rootDirectory: root))
        let start = Date()
        do {
            let artifact = try await coordinator.process(
                BestTranscriptionRequest(
                    meetingID: UUID(), title: "Synthetic quality fixture", date: .now,
                    duration: info.duration, systemAudioURL: source, micAudioURL: nil,
                    vocabulary: "", timeline: nil
                ), forceReprocess: true
            )
            try await native?.shutdown()
            let text = artifact.segments.map(\.text).joined(separator: " ")
            let content = artifact.segments.map { "\($0.speaker.rawValue)|\($0.startTime)|\($0.endTime)|\($0.text)" }.joined(separator: "\n")
            let hash = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
            let workerExited: Bool
            if let native { workerExited = !(await native.hasRunningWorker) }
            else { workerExited = true }
            var output: [String: Any] = [
                "diagnostic": "final_transcript", "engine": engine,
                "modelID": artifact.modelID, "audio_seconds": info.duration,
                "elapsed_seconds": Date().timeIntervalSince(start),
                "segments": artifact.segments.count, "transcript_characters": text.count,
                "content_sha256": hash,
                "timestamps_valid": artifact.segments.allSatisfy {
                    $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0
                        && $0.endTime > $0.startTime && $0.endTime <= info.duration + 0.1
                },
                "alignment": artifact.alignmentQuality.rawValue,
                "worker_exited": workerExited
            ]
            if CommandLine.arguments.contains("--print-fixture-transcript") { output["fixture_text"] = text }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            guard !text.isEmpty else { throw BestTranscriptionError.failed("Empty fixture transcript.") }
        } catch {
            try? await native?.shutdown()
            throw error
        }
    }
}
