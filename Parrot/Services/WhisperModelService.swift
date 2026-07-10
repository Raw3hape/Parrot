import Foundation
import WhisperKit

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
    private(set) var isReady = false

    func prepare(modelName: String = fallbackModel) async throws {
        guard !isReady else { return }
        let config = WhisperKitConfig(
            model: modelName,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true
        )
        whisperKit = try await WhisperKit(config)
        isReady = true
    }

    func transcribe(
        samples: [Float],
        language: String?
    ) async throws -> LocalRecognitionResult {
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

        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        let text = results.map(\.text).joined(separator: " ")
        let segments = results.flatMap(\.segments)
        let confidence: Float? = segments.isEmpty
            ? nil
            : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)

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
}
