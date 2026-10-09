import Foundation

protocol LanguageAwareFinalRecognizing: BestWhisperRecognizing {
    var lastDetectedLanguages: [String] { get async }
}

extension NativeFinalTranscriptionService: LanguageAwareFinalRecognizing {}

/// Preserve the stronger monolingual baseline and use independent language
/// detection for genuine language switches. This policy uses model telemetry,
/// never meeting/reference text or a fixture's identity.
actor HybridFinalTranscriptionService: BestWhisperRecognizing {
    private let whisper: any BestWhisperRecognizing
    private let native: any LanguageAwareFinalRecognizing
    nonisolated let modelIdentity: String
    nonisolated let modelDisplayName: String
    nonisolated let preferredWindowBatchSize: Int
    nonisolated let windowOverlapSeconds: TimeInterval = 0
    nonisolated let hasWordAlignment = false

    init(whisper: any BestWhisperRecognizing, native: any LanguageAwareFinalRecognizing) {
        self.whisper = whisper
        self.native = native
        modelIdentity = "hybrid:\(WhisperModelService.fallbackModel)|\(native.modelIdentity):language-switch-v1"
        modelDisplayName = "Whisper Turbo + \(native.modelDisplayName)"
        preferredWindowBatchSize = whisper.preferredWindowBatchSize
    }

    func prepareLocalOnly(modelName: String) async throws {
        try await whisper.prepareLocalOnly(modelName: WhisperModelService.fallbackModel)
        do {
            try await native.prepareLocalOnly(modelName: native.modelIdentity)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The validated baseline remains available when the refinement
            // worker is absent, unavailable, or deferred by its memory guard.
        }
    }

    func transcribeWindow(samples: [Float], speaker: BestTranscriptSpeaker, absoluteWindowStart: TimeInterval, vocabulary: String) async throws -> [BestTranscriptSegment] {
        let results = try await transcribeWindows([BestWhisperWindowInput(samples: samples, speaker: speaker, absoluteWindowStart: absoluteWindowStart)], vocabulary: vocabulary)
        return results[0]
    }

    func transcribeWindows(_ windows: [BestWhisperWindowInput], vocabulary: String) async throws -> [[BestTranscriptSegment]] {
        var output = Array(repeating: [BestTranscriptSegment](), count: windows.count)
        var baselineIndices: [Int] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            do {
                let refined = try await native.transcribeWindow(
                    samples: window.samples, speaker: window.speaker,
                    absoluteWindowStart: window.absoluteWindowStart, vocabulary: vocabulary
                )
                let languages = await native.lastDetectedLanguages
                if Self.containsLanguageSwitch(languages), !refined.isEmpty {
                    output[index] = refined
                } else {
                    baselineIndices.append(index)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                baselineIndices.append(index)
            }
        }
        if !baselineIndices.isEmpty {
            try Task.checkCancellation()
            let baseline = try await whisper.transcribeWindows(baselineIndices.map { windows[$0] }, vocabulary: vocabulary)
            guard baseline.count == baselineIndices.count else {
                throw BestTranscriptionError.failed("The final transcript batch was incomplete.")
            }
            for (index, segments) in zip(baselineIndices, baseline) { output[index] = segments }
        }
        return output
    }

    nonisolated static func containsLanguageSwitch(_ input: [String]) -> Bool {
        let aliases = ["ru": "russian", "pl": "polish", "en": "english"]
        let languages = Set(input.compactMap { value -> String? in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, normalized != "unknown", normalized.count <= 32 else { return nil }
            return aliases[normalized] ?? normalized
        })
        return languages.count > 1
    }
}
