import Foundation
@preconcurrency import WhisperKit

actor WhisperModelService: LocalSpeechRecognizing {
    static let fallbackModel = "large-v3-v20240930_turbo"

    enum ServiceError: LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded: "Whisper fallback model is not loaded"
            }
        }
    }

    private var whisperKit: WhisperKit?
    private var preparationTask: Task<PreparedWhisper, Error>?
    private var preparationGeneration = UUID()
    private(set) var isReady = false
    private(set) var preparationLaunchCount = 0

    private final class PreparedWhisper: @unchecked Sendable {
        let value: WhisperKit

        init(_ value: WhisperKit) {
            self.value = value
        }
    }

    func prepare(modelName: String = fallbackModel) async throws {
        guard !isReady else { return }

        let task: Task<PreparedWhisper, Error>
        let generation: UUID
        if let existing = preparationTask {
            task = existing
            generation = preparationGeneration
        } else {
            generation = UUID()
            preparationGeneration = generation
            preparationLaunchCount += 1
            task = Task {
                let config = WhisperKitConfig(
                    model: modelName,
                    verbose: false,
                    logLevel: .none,
                    prewarm: true,
                    load: true
                )
                return PreparedWhisper(try await WhisperKit(config))
            }
            preparationTask = task
        }

        do {
            let prepared = try await task.value
            whisperKit = prepared.value
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
        guard let whisperKit else { throw ServiceError.notLoaded }
        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil
        )
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.noSpeechThreshold = 0.6
        options.temperatureFallbackCount = 3

        let vocabulary = (UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocabulary.isEmpty, let tokenizer = whisperKit.tokenizer {
            let terms = vocabulary
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !terms.isEmpty {
                let prompt = " Glossary: " + terms.joined(separator: ", ") + "."
                options.promptTokens = tokenizer.encode(text: prompt)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                options.usePrefillPrompt = true
            }
        }

        try Task.checkCancellation()
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        let text = results.map(\.text).joined(separator: " ")
        let segments = results.flatMap(\.segments)
        let confidence: Float? = segments.isEmpty
            ? nil
            : Self.normalizedConfidence(segments.map(\.avgLogprob))

        return LocalRecognitionResult(
            text: Self.cleaned(text),
            confidence: confidence,
            engine: .whisper
        )
    }

    static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper exposes average token log-probability, while the router expects
    /// a conventional 0...1 confidence. Convert in probability space so the
    /// value is comparable and always finite.
    static func normalizedConfidence(_ logProbabilities: [Float]) -> Float {
        guard !logProbabilities.isEmpty,
              logProbabilities.allSatisfy(\.isFinite) else { return 0 }
        let mean = logProbabilities.reduce(Float.zero, +)
            / Float(logProbabilities.count)
        let probability = Foundation.exp(mean)
        guard probability.isFinite else { return mean > 0 ? 1 : 0 }
        return min(1, max(0, probability))
    }
}
