import AVFoundation
import FluidAudio
import Foundation
import os

/// FIFO storage for realtime audio intake. Advancing a head index keeps the
/// common dequeue path O(1); consumed storage is compacted only occasionally,
/// so long calls do not repeatedly copy their entire remaining backlog.
struct AudioSampleQueue: Sendable {
    private var storage: [Float] = []
    private var head = 0

    var isEmpty: Bool { head >= storage.count }
    var storageCount: Int { storage.count }
    var count: Int { max(storage.count - head, 0) }

    mutating func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        storage.append(contentsOf: samples)
    }

    mutating func dequeue(upTo maximumCount: Int) -> [Float] {
        guard maximumCount > 0, !isEmpty else { return [] }
        let end = min(head + maximumCount, storage.count)
        let result = Array(storage[head..<end])
        head = end
        compactIfNeeded()
        return result
    }

    @discardableResult
    mutating func discardOldest(_ requestedCount: Int) -> Int {
        let count = min(max(0, requestedCount), self.count)
        guard count > 0 else { return 0 }
        head += count
        compactIfNeeded()
        return count
    }

    private mutating func compactIfNeeded() {
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 4_096, head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
    }
}

private enum AudioIntakeStatus: Equatable {
    case accepting
    case draining
    case stale
}

/// The only transcription state touched by realtime audio callbacks. Keeping it
/// behind one unfair lock makes `appendAudio` safe without hopping to MainActor.
private struct AudioIntakeState: Sendable {
    private static let maximumBufferedSamplesPerSource = 2_880_000 // 3 min
    private var generation: Int?
    private var isAccepting = false
    private var queues: [AudioSource: AudioSampleQueue] = Self.emptyQueues
    private var droppedSamples = 0

    var acceptedGeneration: Int? {
        guard isAccepting else { return nil }
        return generation
    }

    mutating func begin(generation: Int) {
        self.generation = generation
        isAccepting = true
        queues = Self.emptyQueues
        droppedSamples = 0
    }

    mutating func append(
        _ samples: [Float],
        source: AudioSource,
        generation expectedGeneration: Int
    ) {
        guard isAccepting, generation == expectedGeneration else { return }
        var queue = queues[source, default: AudioSampleQueue()]
        queue.append(samples)
        let overflow = max(0, queue.count - Self.maximumBufferedSamplesPerSource)
        droppedSamples += queue.discardOldest(overflow)
        queues[source] = queue
    }

    mutating func close(generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        isAccepting = false
    }

    mutating func invalidate(generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        generation = nil
        isAccepting = false
        queues = Self.emptyQueues
        droppedSamples = 0
    }

    func status(for expectedGeneration: Int) -> AudioIntakeStatus {
        guard generation == expectedGeneration else { return .stale }
        return isAccepting ? .accepting : .draining
    }

    mutating func dequeue(
        source: AudioSource,
        generation expectedGeneration: Int,
        maximumCount: Int,
        allowPartial: Bool
    ) -> [Float] {
        guard generation == expectedGeneration,
              var queue = queues[source],
              allowPartial || queue.count >= maximumCount else { return [] }
        let result = queue.dequeue(upTo: maximumCount)
        queues[source] = queue
        return result
    }

    mutating func consumeDroppedSamples() -> Int {
        defer { droppedSamples = 0 }
        return droppedSamples
    }

    private static var emptyQueues: [AudioSource: AudioSampleQueue] {
        [.me: AudioSampleQueue(), .them: AudioSampleQueue()]
    }
}

/// Which capture stream a piece of audio came from.
enum AudioSource: CaseIterable, Sendable {
    /// Microphone — the user.
    case me
    /// System audio — everyone else on the call.
    case them

    var label: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        }
    }
}

/// Fully on-device, call-oriented transcription. The microphone and system
/// streams have independent VAD/utterance state, so every finalized segment is
/// already attributed without a diarization model.
@Observable
@MainActor
final class TranscriptionEngine {
    private let parakeetService = ParakeetModelService()
    private let whisperService: WhisperModelService
    private var recognitionRouter: LocalRecognitionRouter?
    private var vadManager: VadManager?
    private var streamProcessors: [AudioSource: CallStreamProcessor] = [:]
    private var fallbackPreparationTask: Task<Void, Never>?
    private var modelLoadTask: Task<Void, Never>?
    private var whisperIsReady = false

    private nonisolated let intakeLock = OSAllocatedUnfairLock(
        initialState: AudioIntakeState()
    )
    private var transcriptionTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var sessionGeneration = 0
    private var completedSessions: Set<Int> = []
    private var drainWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var drainTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var intakeOverflowReported = false

    private(set) var isReady = false
    private(set) var isTranscribing = false
    private(set) var lastStopTimedOut = false
    private(set) var currentText = ""
    private(set) var modelState: ModelState = .notLoaded
    /// Retained for the existing live status bar. It now reports only local
    /// degradation (for example, Whisper unavailable), never a cloud fallback.
    private(set) var cloudNotice: String?

    /// Called when a finalized transcript segment is ready.
    var onSegment: (@MainActor (TranscriptionResult) -> Void)?

    init(whisperService: WhisperModelService = WhisperModelService()) {
        self.whisperService = whisperService
    }

    enum ModelState {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case error(String)
    }

    struct TranscriptionResult {
        let text: String
        let source: AudioSource
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float?
    }

    // MARK: - Model Management

    /// Prepare the local Parakeet primary model, local Whisper fallback, and
    /// Silero VAD. The argument remains for source compatibility with the old
    /// settings UI; this personal build intentionally pins its tested models.
    func loadModel(_ ignoredModelName: String = WhisperModelService.fallbackModel) async {
        if let modelLoadTask {
            await modelLoadTask.value
            return
        }
        guard !isTranscribing, transcriptionTask == nil, stopTask == nil else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performModelLoad()
        }
        modelLoadTask = task
        await task.value
        modelLoadTask = nil
    }

    private func performModelLoad() async {
        modelState = .loading
        isReady = false
        cloudNotice = nil

        var parakeetError: Error?
        var vadNotice: String?

        do {
            try await parakeetService.prepare()
        } catch {
            parakeetError = error
            NSLog("Parrot: local Parakeet model unavailable — \(error.localizedDescription)")
        }

        do {
            vadManager = try await VadManager(
                config: VadConfig(defaultThreshold: 0.55)
            )
        } catch {
            vadManager = nil
            vadNotice = "Silero VAD unavailable — local energy detection active"
            NSLog("Parrot: Silero VAD unavailable, using local energy VAD — \(error.localizedDescription)")
        }

        if parakeetError == nil {
            recognitionRouter = LocalRecognitionRouter(
                primary: parakeetService,
                fallback: whisperService
            )
            modelState = .ready
            isReady = true

            if whisperIsReady {
                cloudNotice = vadNotice
            } else {
                cloudNotice = Self.combinedNotice(
                    "Local Whisper fallback is warming up — Parakeet is ready",
                    vadNotice
                )
                prepareWhisperFallbackInBackground(vadNotice: vadNotice)
            }
            return
        }

        // Parakeet is the fast path. If it cannot load at all, wait for the
        // already-local Whisper model so the app still has a working engine.
        if let fallbackPreparationTask {
            await fallbackPreparationTask.value
        } else if !whisperIsReady {
            do {
                try await whisperService.prepare()
                whisperIsReady = true
            } catch {
                recognitionRouter = nil
                let message = [
                    "Parakeet: \(parakeetError?.localizedDescription ?? "unavailable")",
                    "Whisper: \(error.localizedDescription)",
                ].joined(separator: " | ")
                modelState = .error(message)
                return
            }
        }

        recognitionRouter = LocalRecognitionRouter(
            primary: whisperService,
            fallback: nil
        )
        cloudNotice = Self.combinedNotice(
            "Parakeet unavailable — using local Whisper",
            vadNotice
        )
        modelState = .ready
        isReady = true
    }

    private func prepareWhisperFallbackInBackground(vadNotice: String?) {
        guard fallbackPreparationTask == nil, !whisperIsReady else { return }
        fallbackPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.whisperService.prepare()
                self.whisperIsReady = true
                self.cloudNotice = vadNotice
                self.fallbackPreparationTask = nil
            } catch {
                NSLog("Parrot: local Whisper fallback unavailable — \(error.localizedDescription)")
                self.cloudNotice = Self.combinedNotice(
                    "Local Whisper fallback unavailable — Parakeet remains active",
                    vadNotice
                )
                self.fallbackPreparationTask = nil
            }
        }
    }

    private static func combinedNotice(_ first: String, _ second: String?) -> String {
        second.map { first + ". " + $0 } ?? first
    }

    // MARK: - Audio Input

    /// Feed 16 kHz mono audio from AudioCaptureManager, tagged by capture stream.
    nonisolated func appendAudio(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let generation = intakeLock.withLock({ $0.acceptedGeneration }),
              let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(
            UnsafeBufferPointer(start: channelData, count: frameCount)
        )

        intakeLock.withLock {
            $0.append(samples, source: source, generation: generation)
        }
    }

    // MARK: - Transcription Loop

    @discardableResult
    func startTranscribing(meetingStartTime: Date) -> Bool {
        guard isReady,
              !isTranscribing,
              transcriptionTask == nil,
              stopTask == nil,
              let recognitionRouter else { return false }

        _ = meetingStartTime
        currentText = ""
        lastStopTimedOut = false
        sessionGeneration += 1
        let session = sessionGeneration
        completedSessions.removeAll()
        intakeOverflowReported = false
        intakeLock.withLock { $0.begin(generation: session) }
        isTranscribing = true

        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        let language = (setting == nil || setting == "auto") ? nil : setting
        let vadManager = self.vadManager

        var processors: [AudioSource: CallStreamProcessor] = [:]
        for source in AudioSource.allCases {
            processors[source] = CallStreamProcessor(
                source: source,
                vad: vadManager,
                router: recognitionRouter,
                language: language,
                onPreview: { [weak self] text, _ in
                    await self?.acceptPreview(text, session: session)
                },
                onFinal: { [weak self] result, startSample, endSample in
                    await self?.acceptFinal(
                        result,
                        source: source,
                        startSample: startSample,
                        endSample: endSample,
                        session: session
                    )
                }
            )
        }
        streamProcessors = processors

        transcriptionTask = Task { @MainActor [weak self, processors] in
            guard let self else { return }

            while !Task.isCancelled {
                let newlyDroppedSamples = self.intakeLock.withLock {
                    $0.consumeDroppedSamples()
                }
                if newlyDroppedSamples > 0, !self.intakeOverflowReported {
                    self.intakeOverflowReported = true
                    self.cloudNotice = Self.combinedNotice(
                        "Live transcription fell behind — saved audio is intact",
                        self.cloudNotice
                    )
                    NSLog(
                        "ParrotMetric event=intake_overflow dropped_samples=%d",
                        newlyDroppedSamples
                    )
                }
                let intakeStatus = self.intakeLock.withLock {
                    $0.status(for: session)
                }
                if case .stale = intakeStatus { break }
                let draining = intakeStatus == .draining
                var didWork = false

                for source in AudioSource.allCases {
                    let chunk = self.intakeLock.withLock {
                        $0.dequeue(
                            source: source,
                            generation: session,
                            maximumCount: VadManager.chunkSize,
                            allowPartial: draining
                        )
                    }
                    guard !chunk.isEmpty, let processor = processors[source] else { continue }
                    didWork = true
                    await processor.append(chunk)
                }

                if !didWork {
                    if draining {
                        for source in AudioSource.allCases {
                            await processors[source]?.finish()
                        }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }

            self.transcriptionLoopDidFinish(session: session)
        }
        return true
    }

    private func acceptPreview(_ text: String, session: Int) {
        guard sessionGeneration == session, isTranscribing else { return }
        currentText = text
    }

    private func acceptFinal(
        _ result: LocalRecognitionResult,
        source: AudioSource,
        startSample: Int,
        endSample: Int,
        session: Int
    ) {
        guard sessionGeneration == session else { return }
        currentText = result.text
        onSegment?(TranscriptionResult(
            text: result.text,
            source: source,
            startTime: Double(startSample) / 16_000.0,
            endTime: Double(endSample) / 16_000.0,
            confidence: result.confidence
        ))
    }

    /// Drain both streams and finalize any short tail that remained below one
    /// VAD frame. Capture must already be stopped before calling this method.
    func stopTranscribing() async {
        if let stopTask {
            await stopTask.value
            return
        }

        guard transcriptionTask != nil || isTranscribing else {
            currentText = ""
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStopTranscribing()
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStopTranscribing() async {
        let session = sessionGeneration
        isTranscribing = false
        intakeLock.withLock { $0.close(generation: session) }

        // Parakeet normally clears even a capped three-minute backlog in a few
        // seconds; local Whisper can need longer on first use. Thirty seconds is
        // finite for a hung Core ML request but avoids discarding a healthy slow
        // fallback tail.
        let drained = await waitForDrain(session: session, timeout: .seconds(30))
        if !drained {
            lastStopTimedOut = true
            // Inference libraries are not guaranteed to cooperate with task
            // cancellation. Invalidate immediately so late callbacks cannot
            // mutate the finished meeting, then return without awaiting them.
            sessionGeneration += 1
            transcriptionTask?.cancel()
            intakeLock.withLock { $0.invalidate(generation: session) }
            cloudNotice = Self.combinedNotice(
                "Final transcript could not finish — saved audio remains available",
                cloudNotice
            )
        } else {
            intakeLock.withLock { $0.invalidate(generation: session) }
        }

        transcriptionTask = nil
        streamProcessors = [:]
        currentText = ""
    }

    private func waitForDrain(session: Int, timeout: Duration) async -> Bool {
        if completedSessions.remove(session) != nil { return true }

        return await withCheckedContinuation { continuation in
            drainWaiters[session] = continuation
            drainTimeoutTasks[session] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.resolveDrainWaiter(session: session, drained: false)
            }
        }
    }

    private func transcriptionLoopDidFinish(session: Int) {
        guard drainWaiters[session] != nil else {
            completedSessions.insert(session)
            return
        }
        resolveDrainWaiter(session: session, drained: true)
    }

    private func resolveDrainWaiter(session: Int, drained: Bool) {
        guard let continuation = drainWaiters.removeValue(forKey: session) else { return }
        drainTimeoutTasks.removeValue(forKey: session)?.cancel()
        continuation.resume(returning: drained)
    }

    /// The classic Whisper silence hallucinations — phrases the model invents
    /// verbatim on near-silent chunks. Applied to both local recognizers.
    nonisolated static let hallucinationPhrases: Set<String> = [
        "you", "okay", "ok", "thank you", "thanks", "bye", "bye-bye",
        "thank you for watching", "thanks for watching", "hmm", "mm-hmm",
        "uh", "um", "the end", "subtitles by", "1", "2",
    ]

    nonisolated static func isLikelyHallucination(_ text: String, energy: Float) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…-—"))
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return true }
        guard energy < 0.006 else { return false }
        return hallucinationPhrases.contains(normalized)
    }

    nonisolated static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"<\|[^|>]*\|>"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
