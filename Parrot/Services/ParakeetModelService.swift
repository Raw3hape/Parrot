import FluidAudio
import Foundation

actor ParakeetModelService: LocalSpeechRecognizing {
    enum ServiceError: LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded: "Parakeet model is not loaded"
            }
        }
    }

    private var manager: AsrManager?
    private var preparationTask: Task<AsrManager, Error>?
    private var preparationGeneration = UUID()
    private(set) var isReady = false
    private(set) var preparationLaunchCount = 0

    func prepare(
        progressHandler: ProgressHandler? = nil
    ) async throws {
        guard !isReady else { return }

        let task: Task<AsrManager, Error>
        let generation: UUID
        if let existing = preparationTask {
            task = existing
            generation = preparationGeneration
        } else {
            generation = UUID()
            preparationGeneration = generation
            preparationLaunchCount += 1
            task = Task {
                let models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    encoderPrecision: .int8,
                    progressHandler: progressHandler
                )
                return AsrManager(config: .default, models: models)
            }
            preparationTask = task
        }

        do {
            let prepared = try await task.value
            manager = prepared
            isReady = true
            if preparationGeneration == generation {
                preparationTask = nil
            }
        } catch {
            if preparationGeneration == generation {
                preparationTask = nil
            }
            throw error
        }
    }

    func transcribe(
        samples: [Float],
        language: String?
    ) async throws -> LocalRecognitionResult {
        try Task.checkCancellation()
        guard let manager else { throw ServiceError.notLoaded }

        // FluidAudio requires at least 300 ms. Silence padding preserves short
        // replies such as "tak", "да", and "yes" without inventing speech.
        var input = samples
        if input.count < 4_800 {
            input.append(contentsOf: repeatElement(Float.zero, count: 4_800 - input.count))
        }

        var decoderState = TdtDecoderState.make(
            decoderLayers: await manager.decoderLayerCount
        )
        try Task.checkCancellation()
        let result = try await manager.transcribe(
            input,
            decoderState: &decoderState,
            language: nil
        )
        return LocalRecognitionResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: result.confidence,
            engine: .parakeet
        )
    }
}
