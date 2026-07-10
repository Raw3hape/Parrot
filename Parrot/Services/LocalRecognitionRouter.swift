import Foundation

enum LocalSpeechEngine: String, Sendable {
    case parakeet
    case whisper
}

struct LocalRecognitionResult: Sendable, Equatable {
    let text: String
    let confidence: Float?
    let engine: LocalSpeechEngine
}

protocol LocalSpeechRecognizing: Sendable {
    func transcribe(
        samples: [Float],
        language: String?
    ) async throws -> LocalRecognitionResult
}

struct RecognitionFallbackPolicy: Sendable {
    let confidenceThreshold: Float

    func needsFallback(
        _ primary: Result<LocalRecognitionResult, Error>
    ) -> Bool {
        switch primary {
        case .failure:
            return true
        case .success(let result):
            if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            // Whisper is already the recovery engine. Sending a valid Whisper
            // result through the same fallback again only repeats an expensive
            // large-model inference and cannot improve engine diversity.
            if result.engine == .whisper { return false }
            guard let confidence = result.confidence else { return false }
            guard confidence.isFinite else { return true }
            return confidence < confidenceThreshold
        }
    }

    func shouldAttemptFallback(
        _ primary: Result<LocalRecognitionResult, Error>,
        fallbackAvailable: Bool
    ) -> Bool {
        fallbackAvailable && needsFallback(primary)
    }

    func resolve(
        primary: Result<LocalRecognitionResult, Error>,
        fallback: Result<LocalRecognitionResult, Error>
    ) -> Result<LocalRecognitionResult, Error> {
        if !needsFallback(primary) { return primary }
        if case .success(let fallbackResult) = fallback,
           !fallbackResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(fallbackResult)
        }

        if case .success(let primaryResult) = primary,
           !primaryResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(primaryResult)
        }

        return fallback
    }
}

actor LocalRecognitionRouter {
    private let primary: any LocalSpeechRecognizing
    private let fallback: (any LocalSpeechRecognizing)?
    private let policy: RecognitionFallbackPolicy

    init(
        primary: any LocalSpeechRecognizing,
        fallback: (any LocalSpeechRecognizing)?,
        policy: RecognitionFallbackPolicy = RecognitionFallbackPolicy(
            confidenceThreshold: 0.45
        )
    ) {
        self.primary = primary
        self.fallback = fallback
        self.policy = policy
    }

    func transcribePreview(
        _ audio: UtteranceAudio,
        language: String?
    ) async throws -> LocalRecognitionResult {
        try Task.checkCancellation()
        return try await primary.transcribe(samples: audio.samples, language: language)
    }

    func transcribeFinal(
        _ audio: UtteranceAudio,
        language: String?
    ) async throws -> LocalRecognitionResult {
        try Task.checkCancellation()
        let primaryAttempt: Result<LocalRecognitionResult, Error>
        do {
            primaryAttempt = .success(
                try await primary.transcribe(samples: audio.samples, language: language)
            )
        } catch {
            primaryAttempt = .failure(error)
        }

        guard policy.shouldAttemptFallback(
            primaryAttempt,
            fallbackAvailable: fallback != nil
        ) else {
            return try primaryAttempt.get()
        }

        // Whisper-primary recovery deliberately has no second recognizer. An
        // empty/error result must propagate once rather than running the exact
        // same 1.5 GB model twice.
        guard let fallback else { return try primaryAttempt.get() }

        try Task.checkCancellation()
        let fallbackAttempt: Result<LocalRecognitionResult, Error>
        do {
            fallbackAttempt = .success(
                try await fallback.transcribe(samples: audio.samples, language: language)
            )
        } catch {
            fallbackAttempt = .failure(error)
        }
        return try policy.resolve(primary: primaryAttempt, fallback: fallbackAttempt).get()
    }
}
