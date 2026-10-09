import Foundation
@preconcurrency import WhisperKit

struct WhisperLongFormPolicy: Equatable, Sendable {
    var language: String?
    var detectLanguage: Bool
    var wordTimestamps: Bool
    var withoutTimestamps: Bool
    var concurrentWorkerCount: Int
    var usesVADChunking: Bool

    static func bestLocal(workerCount: Int) -> Self {
        Self(
            language: nil,
            detectLanguage: true,
            wordTimestamps: true,
            withoutTimestamps: false,
            concurrentWorkerCount: max(1, workerCount),
            usesVADChunking: true
        )
    }

    static func recommendedWindowBatchSize(
        processorCount: Int,
        physicalMemory: UInt64
    ) -> Int {
        // Feed Core ML without multiplying model pressure on smaller Macs or
        // delaying live transcription behind a large background batch.
        let processorBudget = max(1, processorCount / 4)
        let memoryBudget = max(1, Int(physicalMemory / (8 * 1_024 * 1_024 * 1_024)))
        return min(4, min(processorBudget, memoryBudget))
    }
}

struct WhisperPreparationPolicy: Equatable, Sendable {
    var allowDownload: Bool

    static let liveFallback = Self(allowDownload: true)
    static let bestExport = Self(allowDownload: false)
}

enum WhisperLocalModelLocator {
    static func modelFolder(
        modelName: String,
        homeDirectories: [URL]? = nil
    ) -> URL? {
        let homes = homeDirectories ?? defaultHomeDirectories()
        let folderName = "openai_whisper-\(modelName)"
        for home in homes {
            let folder = home
                .appendingPathComponent(
                    "Documents/huggingface/models/argmaxinc/whisperkit-coreml",
                    isDirectory: true
                )
                .appendingPathComponent(folderName, isDirectory: true)
                .standardizedFileURL
            let required = [
                folder.appendingPathComponent("config.json"),
                folder.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true),
                folder.appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true),
            ]
            if required.allSatisfy({
                FileManager.default.fileExists(atPath: $0.path)
            }) {
                return folder
            }
        }
        return nil
    }

    private static func defaultHomeDirectories() -> [URL] {
        var homes: [URL] = []
        if let environmentHome = ProcessInfo.processInfo.environment["HOME"] {
            homes.append(URL(fileURLWithPath: environmentHome, isDirectory: true))
        }
        let systemHome = FileManager.default.homeDirectoryForCurrentUser
        homes.append(systemHome)
        homes.append(
            systemHome
                .appendingPathComponent(
                    "Library/Containers/com.uygar.parrot/Data",
                    isDirectory: true
                )
        )
        var seen: Set<String> = []
        return homes.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

actor WhisperInferenceGate {
    enum Priority: Sendable {
        case live
        case background
    }

    private var held = false
    private var liveWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    func acquire(priority: Priority) async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            switch priority {
            case .live:
                liveWaiters.append(continuation)
            case .background:
                backgroundWaiters.append(continuation)
            }
        }
    }

    func release() {
        if !liveWaiters.isEmpty {
            liveWaiters.removeFirst().resume()
        } else if !backgroundWaiters.isEmpty {
            backgroundWaiters.removeFirst().resume()
        } else {
            held = false
        }
    }

    /// Internal observability used by deterministic concurrency tests. It
    /// exposes counts only—never continuations or mutable gate state.
    func waitingCounts() -> (live: Int, background: Int) {
        (liveWaiters.count, backgroundWaiters.count)
    }
}

actor WhisperModelService: LocalSpeechRecognizing {
    static let fallbackModel = "large-v3-v20240930_turbo"

    enum ServiceError: LocalizedError {
        case notLoaded
        case localModelMissing
        case localModelCorrupt

        var errorDescription: String? {
            switch self {
            case .notLoaded: "Whisper fallback model is not loaded"
            case .localModelMissing:
                "Whisper Large V3 Turbo is not installed locally. Reload the model in Settings, then try again."
            case .localModelCorrupt:
                "The local Whisper Large V3 Turbo model could not be opened. Reload the model in Settings, then try again."
            }
        }
    }

    private var whisperKit: WhisperKit?
    private var preparationTask: Task<PreparedWhisper, Error>?
    private var preparationGeneration = UUID()
    private let inferenceGate: WhisperInferenceGate
    private nonisolated let exportBatchSizeOverride: Int?
    private(set) var isReady = false
    private(set) var preparationLaunchCount = 0

    init(
        inferenceGate: WhisperInferenceGate = WhisperInferenceGate(),
        exportBatchSizeOverride: Int? = nil
    ) {
        self.inferenceGate = inferenceGate
        self.exportBatchSizeOverride = exportBatchSizeOverride
    }

    nonisolated var preferredWindowBatchSize: Int {
        if let exportBatchSizeOverride {
            return max(1, exportBatchSizeOverride)
        }
        let process = ProcessInfo.processInfo
        return WhisperLongFormPolicy.recommendedWindowBatchSize(
            processorCount: process.activeProcessorCount,
            physicalMemory: process.physicalMemory
        )
    }

    private final class PreparedWhisper: @unchecked Sendable {
        let value: WhisperKit

        init(_ value: WhisperKit) {
            self.value = value
        }
    }

    func prepare(modelName: String = fallbackModel) async throws {
        try await prepare(
            modelName: modelName,
            policy: .liveFallback
        )
    }

    func prepareLocalOnly(modelName: String = fallbackModel) async throws {
        try await prepare(
            modelName: modelName,
            policy: .bestExport
        )
    }

    private func prepare(
        modelName: String,
        policy: WhisperPreparationPolicy
    ) async throws {
        guard !isReady else { return }
        // Live fallback must also work offline after setup. Resolve a complete
        // local model first; permit a download only when that cache is absent.
        let localModelFolder = WhisperLocalModelLocator.modelFolder(
            modelName: modelName
        )
        if localModelFolder == nil && !policy.allowDownload {
            throw ServiceError.localModelMissing
        }

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
                    model: localModelFolder == nil ? modelName : nil,
                    modelFolder: localModelFolder?.path,
                    verbose: false,
                    logLevel: .none,
                    prewarm: true,
                    load: true,
                    download: localModelFolder == nil && policy.allowDownload
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
            if !policy.allowDownload {
                throw ServiceError.localModelCorrupt
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
        let results: [TranscriptionResult]
        await inferenceGate.acquire(priority: .live)
        do {
            try Task.checkCancellation()
            results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            await inferenceGate.release()
        } catch {
            await inferenceGate.release()
            throw error
        }
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

    func transcribeWindow(
        samples: [Float],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        vocabulary: String
    ) async throws -> [BestTranscriptSegment] {
        let results = try await transcribeWindows(
            [BestWhisperWindowInput(
                samples: samples,
                speaker: speaker,
                absoluteWindowStart: absoluteWindowStart
            )],
            vocabulary: vocabulary
        )
        return results[0]
    }

    func transcribeWindows(
        _ windows: [BestWhisperWindowInput],
        vocabulary: String
    ) async throws -> [[BestTranscriptSegment]] {
        try Task.checkCancellation()
        guard !windows.isEmpty else { return [] }
        guard let whisperKit else { throw ServiceError.notLoaded }
        let policy = WhisperLongFormPolicy.bestLocal(
            workerCount: min(windows.count, preferredWindowBatchSize)
        )
        var options = DecodingOptions(
            task: .transcribe,
            language: policy.language,
            detectLanguage: policy.detectLanguage,
            skipSpecialTokens: true,
            withoutTimestamps: policy.withoutTimestamps,
            wordTimestamps: policy.wordTimestamps,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: policy.concurrentWorkerCount,
            chunkingStrategy: policy.usesVADChunking ? .vad : nil
        )
        options.temperatureFallbackCount = 3
        Self.applyVocabulary(vocabulary, tokenizer: whisperKit.tokenizer, options: &options)

        let results: [Result<[TranscriptionResult], Error>]
        await inferenceGate.acquire(priority: .background)
        do {
            try Task.checkCancellation()
            results = await whisperKit.transcribeWithResults(
                audioArrays: windows.map(\.samples),
                decodeOptions: options,
                callback: { _ in
                    Task<Never, Never>.isCancelled ? false : true
                }
            )
            await inferenceGate.release()
        } catch {
            await inferenceGate.release()
            throw error
        }
        try Task.checkCancellation()

        guard results.count == windows.count else {
            throw BestTranscriptionError.failed("Whisper returned an incomplete audio batch.")
        }
        var mapped: [[BestTranscriptSegment]] = []
        for (window, result) in zip(windows, results) {
            let raw = try result.get().flatMap { transcription in
                transcription.segments.map { segment in
                    BestRawWhisperSegment(
                        startTime: TimeInterval(segment.start),
                        endTime: TimeInterval(segment.end),
                        text: segment.text,
                        averageLogProbability: segment.avgLogprob,
                        detectedLanguage: transcription.language,
                        words: (segment.words ?? []).map { word in
                            BestRawWhisperWord(
                                text: word.word,
                                startTime: TimeInterval(word.start),
                                endTime: TimeInterval(word.end),
                                probability: word.probability
                            )
                        }
                    )
                }
            }
            mapped.append(BestWhisperResultMapper.map(
                raw,
                speaker: window.speaker,
                absoluteWindowStart: window.absoluteWindowStart
            ))
        }
        return mapped
    }

    static func cleaned(_ text: String) -> String {
        BestWhisperResultMapper.cleaned(text)
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

    private static func applyVocabulary(
        _ vocabulary: String,
        tokenizer: (any WhisperTokenizer)?,
        options: inout DecodingOptions
    ) {
        let normalized = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let tokenizer else { return }
        let terms = normalized
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return }
        let prompt = " Glossary: " + terms.joined(separator: ", ") + "."
        options.promptTokens = tokenizer.encode(text: prompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        options.usePrefillPrompt = true
        options.detectLanguage = true
    }
}
