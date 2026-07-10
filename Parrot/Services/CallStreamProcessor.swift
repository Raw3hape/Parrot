import FluidAudio
import Foundation

struct PreviewGenerationGate: Sendable {
    private var latestFinalGeneration = 0

    mutating func acceptsPreview(generation: Int) -> Bool {
        generation >= latestFinalGeneration
    }

    mutating func acceptFinal(generation: Int) {
        latestFinalGeneration = max(latestFinalGeneration, generation)
    }
}

enum TranscriptOverlapTrimmer {
    static func trim(previous: String, next: String, maximumWords: Int = 12) -> String {
        let previousWords = words(previous)
        let nextOriginal = next.split(whereSeparator: \.isWhitespace).map(String.init)
        let nextWords = nextOriginal.map(normalized)
        guard !previousWords.isEmpty, !nextWords.isEmpty else {
            return next.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let limit = min(maximumWords, previousWords.count, nextWords.count)
        var overlap = 0
        if limit > 0 {
            for count in stride(from: limit, through: 1, by: -1) {
                if Array(previousWords.suffix(count)) == Array(nextWords.prefix(count)) {
                    overlap = count
                    break
                }
            }
        }
        return nextOriginal.dropFirst(overlap).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(
            in: .punctuationCharacters.union(.symbols)
        )
    }
}

/// Processes one ordered capture source. The microphone and system streams each
/// receive their own instance, VAD state, utterance buffer, and timestamps.
actor CallStreamProcessor {
    typealias PreviewHandler = @Sendable (_ text: String, _ generation: Int) async -> Void
    typealias FinalHandler = @Sendable (
        _ result: LocalRecognitionResult,
        _ startSample: Int,
        _ endSample: Int
    ) async -> Void

    private let source: AudioSource
    private let vad: VadManager?
    private let router: LocalRecognitionRouter
    private let language: String?
    private let onPreview: PreviewHandler
    private let onFinal: FinalHandler
    private let vadConfig = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.65,
        maxSpeechDuration: 14,
        speechPadding: 0.15
    )

    private var vadState = VadStreamState.initial()
    private var vadUnavailable = false
    private var energyDetector = EnergyBoundaryDetector()
    private var assembler: UtteranceAssembler
    private var pendingSamples: [Float] = []
    private var processedSamples = 0
    private var previewTask: Task<Void, Never>?
    private var previewSequence = 0
    private var generationGate = PreviewGenerationGate()
    private var previousFinalText = ""
    private var previousFinalEndSample = 0

    init(
        source: AudioSource,
        vad: VadManager?,
        router: LocalRecognitionRouter,
        language: String?,
        config: CallSegmentationConfig = .callDefault,
        onPreview: @escaping PreviewHandler,
        onFinal: @escaping FinalHandler
    ) {
        self.source = source
        self.vad = vad
        self.router = router
        self.language = language
        self.assembler = UtteranceAssembler(config: config)
        self.onPreview = onPreview
        self.onFinal = onFinal
    }

    func append(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        pendingSamples.append(contentsOf: samples)

        while pendingSamples.count >= VadManager.chunkSize {
            let frame = Array(pendingSamples.prefix(VadManager.chunkSize))
            pendingSamples.removeFirst(VadManager.chunkSize)
            await processFrame(frame)
        }
    }

    func finish() async {
        if !pendingSamples.isEmpty {
            let tail = pendingSamples
            pendingSamples.removeAll(keepingCapacity: false)
            // Silero accepts exactly 4096 samples. Keep the real tail length and
            // let the energy fallback close it instead of padding fake time.
            await processFrame(tail, allowModelVAD: false)
        }

        await handle(assembler.flush(atSample: processedSamples))
        previewTask?.cancel()
        await previewTask?.value
        previewTask = nil
    }

    func cancelPreviews() async {
        previewTask?.cancel()
        await previewTask?.value
        previewTask = nil
    }

    private func processFrame(_ frame: [Float], allowModelVAD: Bool = true) async {
        let frameStart = processedSamples
        let frameEnd = frameStart + frame.count
        var startBoundary: SpeechBoundary?
        var endBoundary: SpeechBoundary?

        if let vad, !vadUnavailable, allowModelVAD {
            do {
                let output = try await vad.processStreamingChunk(
                    frame,
                    state: vadState,
                    config: vadConfig
                )
                vadState = output.state
                if let event = output.event {
                    if event.isStart {
                        startBoundary = .started(atSample: event.sampleIndex)
                    } else {
                        endBoundary = .ended(atSample: event.sampleIndex)
                    }
                }
            } catch {
                vadUnavailable = true
            }
        }

        if vad == nil || vadUnavailable || !allowModelVAD {
            let boundary = energyDetector.process(
                frame,
                absoluteStartSample: frameStart
            )
            if case .started = boundary { startBoundary = boundary }
            if case .ended = boundary { endBoundary = boundary }
        }

        if let startBoundary {
            await handle(assembler.apply(startBoundary))
        }
        await handle(assembler.append(frame, absoluteStartSample: frameStart))
        processedSamples = frameEnd
        if let endBoundary {
            await handle(assembler.apply(endBoundary))
        }
    }

    private func handle(_ emissions: [UtteranceEmission]) async {
        for emission in emissions {
            switch emission {
            case .preview(let audio):
                schedulePreview(audio)
            case .final(let audio):
                await publishFinal(audio)
            }
        }
    }

    private func schedulePreview(_ audio: UtteranceAudio) {
        // Do not queue growing previews behind one another when inference takes
        // longer than the preview cadence. The next interval will try again.
        guard previewTask == nil else { return }
        previewSequence += 1
        let sequence = previewSequence
        previewTask = Task { [weak self, router, language] in
            do {
                guard !Task.isCancelled else {
                    await self?.finishPreview(sequence: sequence)
                    return
                }
                let result = try await router.transcribePreview(audio, language: language)
                if !Task.isCancelled {
                    await self?.publishPreview(result, generation: audio.generation)
                }
            } catch {
                // A failed preview is intentionally silent. The finalized path
                // still runs and can use the local Whisper fallback.
            }
            await self?.finishPreview(sequence: sequence)
        }
    }

    private func finishPreview(sequence: Int) {
        guard sequence == previewSequence else { return }
        previewTask = nil
    }

    private func publishPreview(
        _ result: LocalRecognitionResult,
        generation: Int
    ) async {
        guard generationGate.acceptsPreview(generation: generation) else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await onPreview(text, generation)
    }

    private func publishFinal(_ audio: UtteranceAudio) async {
        generationGate.acceptFinal(generation: audio.generation)
        previewTask?.cancel()
        previewSequence += 1
        previewTask = nil

        do {
            var result = try await router.transcribeFinal(audio, language: language)
            var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if audio.startSample < previousFinalEndSample {
                text = TranscriptOverlapTrimmer.trim(previous: previousFinalText, next: text)
            }
            guard !text.isEmpty else { return }

            let energy = audio.samples.reduce(into: Float.zero) { $0 += abs($1) }
                / Float(max(audio.samples.count, 1))
            guard !TranscriptionEngine.isLikelyHallucination(text, energy: energy) else { return }

            result = LocalRecognitionResult(
                text: text,
                confidence: result.confidence,
                engine: result.engine
            )
            previousFinalText = text
            previousFinalEndSample = audio.endSample
            await onFinal(result, audio.startSample, audio.endSample)
        } catch {
            // Both on-device recognizers failed. Audio is still saved on disk and
            // the failure remains isolated to this utterance.
        }
    }
}

private struct EnergyBoundaryDetector: Sendable {
    private let threshold: Float = 0.002
    private let endSilenceSamples = 10_400 // 650 ms
    private let paddingSamples = 2_400     // 150 ms
    private var active = false
    private var silenceStartSample: Int?

    mutating func process(
        _ samples: [Float],
        absoluteStartSample: Int
    ) -> SpeechBoundary? {
        let energy = samples.reduce(into: Float.zero) { $0 += abs($1) }
            / Float(max(samples.count, 1))
        let frameEnd = absoluteStartSample + samples.count

        if energy > threshold {
            silenceStartSample = nil
            if !active {
                active = true
                return .started(atSample: max(0, absoluteStartSample - paddingSamples))
            }
            return nil
        }

        guard active else { return nil }
        if silenceStartSample == nil { silenceStartSample = absoluteStartSample }
        guard let silenceStartSample,
              frameEnd - silenceStartSample >= endSilenceSamples else { return nil }

        active = false
        self.silenceStartSample = nil
        return .ended(atSample: silenceStartSample + paddingSamples)
    }
}
