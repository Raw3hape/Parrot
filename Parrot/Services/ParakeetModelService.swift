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
    private(set) var isReady = false

    func prepare(
        progressHandler: ProgressHandler? = nil
    ) async throws {
        let models = try await AsrModels.downloadAndLoad(
            version: .v3,
            encoderPrecision: .int8,
            progressHandler: progressHandler
        )
        manager = AsrManager(config: .default, models: models)
        isReady = true
    }

    func transcribe(
        samples: [Float],
        language: String?
    ) async throws -> LocalRecognitionResult {
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
