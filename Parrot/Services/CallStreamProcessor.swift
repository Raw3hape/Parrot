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

/// Ordered audio retained for finalized recognition. Dequeued audio remains in
/// the retained count until `complete` because the inference task still owns
/// that memory while it is in flight.
struct FinalRecognitionBacklog: Sendable {
    private let maximumRetainedSamples: Int
    private var queue: [UtteranceAudio] = []
    private(set) var retainedSampleCount = 0

    init(maximumRetainedSamples: Int) {
        self.maximumRetainedSamples = max(0, maximumRetainedSamples)
    }

    var isEmpty: Bool { queue.isEmpty }

    mutating func enqueue(_ audio: UtteranceAudio) -> Bool {
        let sampleCount = audio.samples.count
        guard sampleCount <= maximumRetainedSamples - retainedSampleCount else {
            return false
        }
        queue.append(audio)
        retainedSampleCount += sampleCount
        return true
    }

    mutating func dequeue() -> UtteranceAudio? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    mutating func complete(sampleCount: Int) {
        retainedSampleCount = max(0, retainedSampleCount - max(0, sampleCount))
    }

    mutating func discardQueued() -> Int {
        let discarded = queue.reduce(into: 0) { $0 += $1.samples.count }
        queue.removeAll(keepingCapacity: false)
        retainedSampleCount = max(0, retainedSampleCount - discarded)
        return discarded
    }
}

enum TranscriptOverlapTrimmer {
    static func trim(previous: String, next: String, maximumWords: Int = 12) -> String {
        let originalNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousWords = words(previous)
        let nextOriginal = next.split(whereSeparator: \.isWhitespace).map(String.init)
        let nextWords = nextOriginal.map(normalized)
        guard !previousWords.isEmpty, !nextWords.isEmpty else {
            return originalNext
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
        // A complete repeated hypothesis can be a genuine short reply (for
        // example "yes yes yes"), not only forced-split context. Never erase a
        // whole finalized segment; only remove a proper overlapping prefix.
        if overlap == nextWords.count { return originalNext }
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

actor LocalPipelineMetrics {
    struct Snapshot: Sendable {
        let vadFailures: Int
        let recognitionFailures: Int
        let rejectedNoiseFrames: Int
        let finalBacklogOverflows: Int
        let droppedFinalSamples: Int
    }

    static let shared = LocalPipelineMetrics()

    private var vadFailures = 0
    private var recognitionFailures = 0
    private var rejectedNoiseFrames = 0
    private var finalBacklogOverflows = 0
    private var droppedFinalSamples = 0

    func recordVADFailure(source: AudioSource) {
        vadFailures += 1
        NSLog(
            "ParrotMetric event=vad_failure source=%@ total=%d",
            source.label,
            vadFailures
        )
    }

    func recordRecognitionFailure(source: AudioSource) {
        recognitionFailures += 1
        if Self.shouldLog(total: recognitionFailures) {
            NSLog(
                "ParrotMetric event=recognition_failure source=%@ total=%d",
                source.label,
                recognitionFailures
            )
        }
    }

    func recordNoiseRejection(source: AudioSource) {
        rejectedNoiseFrames += 1
        if Self.shouldLog(total: rejectedNoiseFrames) {
            NSLog(
                "ParrotMetric event=noise_frame_rejected source=%@ total=%d",
                source.label,
                rejectedNoiseFrames
            )
        }
    }

    func recordFinalBacklogOverflow(
        source: AudioSource,
        droppedSamples: Int,
        retainedSamples: Int
    ) {
        finalBacklogOverflows += 1
        droppedFinalSamples += max(0, droppedSamples)
        if Self.shouldLog(total: finalBacklogOverflows) {
            NSLog(
                "ParrotMetric event=final_backlog_overflow source=%@ total=%d dropped_samples=%d retained_samples=%d",
                source.label,
                finalBacklogOverflows,
                droppedSamples,
                retainedSamples
            )
        }
    }

    func recordCancelledFinalBacklog(source: AudioSource, droppedSamples: Int) {
        guard droppedSamples > 0 else { return }
        droppedFinalSamples += droppedSamples
        NSLog(
            "ParrotMetric event=final_backlog_cancelled source=%@ dropped_samples=%d",
            source.label,
            droppedSamples
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            vadFailures: vadFailures,
            recognitionFailures: recognitionFailures,
            rejectedNoiseFrames: rejectedNoiseFrames,
            finalBacklogOverflows: finalBacklogOverflows,
            droppedFinalSamples: droppedFinalSamples
        )
    }

    private static func shouldLog(total: Int) -> Bool {
        total > 0 && (total & (total - 1)) == 0
    }
}

/// Processes one ordered capture source. The microphone and system streams each
/// receive their own instance, VAD state, utterance buffer, and timestamps.
actor CallStreamProcessor {
    private static let maximumRetainedFinalSamples = 2_880_000 // 3 min at 16 kHz

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
    private var finalBacklog = FinalRecognitionBacklog(
        maximumRetainedSamples: CallStreamProcessor.maximumRetainedFinalSamples
    )
    private var finalWorkerTask: Task<Void, Never>?
    private var finalWorkerGeneration = 0
    private var isFinishing = false

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
        guard !isFinishing, !samples.isEmpty else { return }
        pendingSamples.append(contentsOf: samples)

        while pendingSamples.count >= VadManager.chunkSize {
            let frame = Array(pendingSamples.prefix(VadManager.chunkSize))
            pendingSamples.removeFirst(VadManager.chunkSize)
            await processFrame(frame)
        }
    }

    func finish() async {
        if isFinishing {
            await waitForFinalWorker()
            return
        }
        isFinishing = true

        if !pendingSamples.isEmpty {
            let tail = pendingSamples
            pendingSamples.removeAll(keepingCapacity: false)
            // Silero accepts exactly 4096 samples. Keep the real tail length and
            // let the energy fallback close it instead of padding fake time.
            await processFrame(tail, allowModelVAD: false)
        }

        await handle(assembler.flush(atSample: processedSamples))
        previewTask?.cancel()
        previewTask = nil
        await waitForFinalWorker()
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
                if vadState.triggered {
                    energyDetector.seedActive()
                }
                vadUnavailable = true
                await LocalPipelineMetrics.shared.recordVADFailure(source: source)
            }
        }

        if vad == nil || vadUnavailable || !allowModelVAD {
            let boundary = energyDetector.process(
                frame,
                absoluteStartSample: frameStart
            )
            if energyDetector.consumeNoiseRejection() {
                await LocalPipelineMetrics.shared.recordNoiseRejection(source: source)
            }
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
                await enqueueFinal(audio)
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

    private func enqueueFinal(_ audio: UtteranceAudio) async {
        generationGate.acceptFinal(generation: audio.generation)
        previewTask?.cancel()
        previewSequence += 1
        previewTask = nil

        guard finalBacklog.enqueue(audio) else {
            await LocalPipelineMetrics.shared.recordFinalBacklogOverflow(
                source: source,
                droppedSamples: audio.samples.count,
                retainedSamples: finalBacklog.retainedSampleCount
            )
            return
        }
        startFinalWorkerIfNeeded()
    }

    private func startFinalWorkerIfNeeded() {
        guard finalWorkerTask == nil, !finalBacklog.isEmpty else { return }
        finalWorkerGeneration += 1
        let generation = finalWorkerGeneration
        finalWorkerTask = Task { [weak self] in
            guard let self else { return }
            await self.runFinalWorker(generation: generation)
        }
    }

    private func runFinalWorker(generation: Int) async {
        while !Task.isCancelled, let audio = finalBacklog.dequeue() {
            await recognizeFinal(audio)
            finalBacklog.complete(sampleCount: audio.samples.count)
        }

        if Task.isCancelled {
            let discarded = finalBacklog.discardQueued()
            await LocalPipelineMetrics.shared.recordCancelledFinalBacklog(
                source: source,
                droppedSamples: discarded
            )
        }

        guard finalWorkerGeneration == generation else { return }
        finalWorkerTask = nil
        if !isFinishing, !finalBacklog.isEmpty {
            startFinalWorkerIfNeeded()
        }
    }

    private func waitForFinalWorker() async {
        while let worker = finalWorkerTask {
            await withTaskCancellationHandler {
                await worker.value
            } onCancel: { [weak self] in
                worker.cancel()
                Task {
                    guard let self else { return }
                    await self.cancelQueuedFinals()
                }
            }
            if Task.isCancelled { return }
        }
    }

    private func cancelQueuedFinals() async {
        finalWorkerTask?.cancel()
        let discarded = finalBacklog.discardQueued()
        await LocalPipelineMetrics.shared.recordCancelledFinalBacklog(
            source: source,
            droppedSamples: discarded
        )
    }

    private func recognizeFinal(_ audio: UtteranceAudio) async {

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
            if !(error is CancellationError) {
                await LocalPipelineMetrics.shared.recordRecognitionFailure(source: source)
            }
        }
    }
}

struct EnergyBoundaryDetector: Sendable {
    private let threshold: Float = 0.002
    private let endSilenceSamples = 10_400 // 650 ms
    private let paddingSamples = 2_400     // 150 ms
    private var active = false
    private var silenceStartSample: Int?
    private var rejectedNoiseInLastFrame = false

    mutating func seedActive() {
        active = true
        silenceStartSample = nil
    }

    mutating func consumeNoiseRejection() -> Bool {
        defer { rejectedNoiseInLastFrame = false }
        return rejectedNoiseInLastFrame
    }

    mutating func process(
        _ samples: [Float],
        absoluteStartSample: Int
    ) -> SpeechBoundary? {
        rejectedNoiseInLastFrame = Self.isImplausibleStationaryNoise(samples)
        let measuredEnergy = samples.reduce(into: Float.zero) { $0 += abs($1) }
            / Float(max(samples.count, 1))
        let energy = rejectedNoiseInLastFrame ? 0 : measuredEnergy
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

    /// Alternating full-scale samples have enough average energy to look like
    /// speech, but their near-constant envelope and sample-by-sample polarity
    /// changes are not a plausible voice waveform. Keep the gate deliberately
    /// narrow so short real speech and ordinary sibilants still pass.
    static func isImplausibleStationaryNoise(_ samples: [Float]) -> Bool {
        guard samples.count >= 32 else { return false }

        var crossings = 0
        var magnitudeSum: Float = 0
        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(samples.count)

        var previous = samples[0]
        for sample in samples {
            let magnitude = abs(sample)
            guard magnitude.isFinite else { return true }
            magnitudes.append(magnitude)
            magnitudeSum += magnitude
            if (previous < 0 && sample > 0) || (previous > 0 && sample < 0) {
                crossings += 1
            }
            previous = sample
        }

        let meanMagnitude = magnitudeSum / Float(samples.count)
        guard meanMagnitude > 0.002 else { return false }
        let crossingRate = Float(crossings) / Float(samples.count - 1)
        guard crossingRate > 0.80 else { return false }

        let envelopeDeviation = magnitudes.reduce(into: Float.zero) {
            $0 += abs($1 - meanMagnitude)
        } / Float(samples.count)
        return envelopeDeviation / meanMagnitude < 0.12
    }
}
