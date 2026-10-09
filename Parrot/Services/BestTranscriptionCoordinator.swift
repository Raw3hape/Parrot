import Foundation
import Observation

struct BestWhisperWindowInput: Sendable {
    var samples: [Float]
    var speaker: BestTranscriptSpeaker
    var absoluteWindowStart: TimeInterval
}

protocol BestWhisperRecognizing: Sendable {
    var preferredWindowBatchSize: Int { get }
    var modelIdentity: String { get }
    var modelDisplayName: String { get }
    var windowOverlapSeconds: TimeInterval { get }
    var hasWordAlignment: Bool { get }
    func prepareLocalOnly(modelName: String) async throws
    func transcribeWindow(
        samples: [Float],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        vocabulary: String
    ) async throws -> [BestTranscriptSegment]
    func transcribeWindows(
        _ windows: [BestWhisperWindowInput],
        vocabulary: String
    ) async throws -> [[BestTranscriptSegment]]
}

extension BestWhisperRecognizing {
    var preferredWindowBatchSize: Int { 1 }
    var modelIdentity: String { WhisperModelService.fallbackModel }
    var modelDisplayName: String { "Whisper Large V3 Turbo" }
    var windowOverlapSeconds: TimeInterval { 2 }
    var hasWordAlignment: Bool { true }

    func transcribeWindows(
        _ windows: [BestWhisperWindowInput],
        vocabulary: String
    ) async throws -> [[BestTranscriptSegment]] {
        var results: [[BestTranscriptSegment]] = []
        for window in windows {
            results.append(try await transcribeWindow(
                samples: window.samples,
                speaker: window.speaker,
                absoluteWindowStart: window.absoluteWindowStart,
                vocabulary: vocabulary
            ))
        }
        return results
    }
}

extension WhisperModelService: BestWhisperRecognizing {}

struct AudioTimelineManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    struct Track: Codable, Equatable, Sendable {
        var speaker: BestTranscriptSpeaker
        var startOffset: TimeInterval
        var frameCount: Int64
        var sampleRate: Double
        var droppedFrameRanges: [Range<Int64>]
    }

    var schemaVersion: Int
    var capturedAt: Date
    var tracks: [Track]

    func track(for speaker: BestTranscriptSpeaker) -> Track? {
        tracks.first { $0.speaker == speaker }
    }
}

struct BestTranscriptionRequest: Sendable {
    var meetingID: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var systemAudioURL: URL?
    var micAudioURL: URL?
    var vocabulary: String
    var timeline: AudioTimelineManifest?
    var allowPartialDamagedTracks = false
}

enum BestTranscriptionError: LocalizedError, Equatable {
    case noAudio
    case insufficientDiskSpace
    case cancelled
    case damagedAudioAvailable([String])
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio:
            "Recording audio is missing."
        case .insufficientDiskSpace:
            "There is not enough free disk space to create the best transcript."
        case .cancelled:
            "Local transcription was cancelled."
        case .damagedAudioAvailable(let warnings):
            """
            Part of the recording is damaged or missing. \(warnings.joined(separator: " ")) \
            You can retry or explicitly export only the available track.
            """
        case .failed(let message):
            message
        }
    }
}

private struct BestCheckpointInterruption: Error {}

enum BestTranscriptionStage: String, Sendable {
    case idle
    case queued
    case validating
    case preparingModel
    case transcribingSystem
    case transcribingMicrophone
    case merging
    case saving
    case ready
    case cancelled
    case interrupted
    case failed

    var title: String {
        switch self {
        case .idle: "Ready"
        case .queued: "Waiting for another final transcript…"
        case .validating: "Checking recording audio…"
        case .preparingModel: "Preparing local speech model…"
        case .transcribingSystem: "Transcribing system audio…"
        case .transcribingMicrophone: "Transcribing microphone…"
        case .merging: "Merging speakers…"
        case .saving: "Saving best transcript…"
        case .ready: "Best transcript ready"
        case .cancelled: "Processing cancelled"
        case .interrupted: "Processing paused"
        case .failed: "Couldn’t create the best transcript"
        }
    }
}

struct BestTranscriptionProgress: Sendable {
    var stage: BestTranscriptionStage = .idle
    var fraction: Double = 0
    var processedDuration: TimeInterval = 0
    var totalDuration: TimeInterval = 0
    var estimatedRemaining: TimeInterval?
    var warning: String?
    var error: String?

    var isRunning: Bool {
        switch stage {
        case .queued, .validating, .preparingModel,
             .transcribingSystem, .transcribingMicrophone, .merging, .saving:
            true
        default:
            false
        }
    }
}

private actor BestTranscriptionJobGate {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !held {
            held = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().1.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}

@MainActor
@Observable
final class BestTranscriptionCoordinator {
    nonisolated static let pipelineVersion = 1

    private let recognizer: any BestWhisperRecognizing
    var modelDisplayName: String { recognizer.modelDisplayName }
    private let store: BestTranscriptionStore
    private let jobGate = BestTranscriptionJobGate()
    private struct JobSpec {
        var request: BestTranscriptionRequest
        var forceReprocess: Bool
    }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var activeRequests: [UUID: JobSpec] = [:]
    private var pausedForRecording: [UUID: JobSpec] = [:]
    private var suspendingForRecording: Set<UUID> = []
    private var isPausedForRecording = false
    private var isTerminating = false
    private var userCancelled: Set<UUID> = []
    private var completionHandlers: [
        UUID: [(Result<BestTranscriptArtifact, Error>) -> Void]
    ] = [:]

    private(set) var progressByMeeting: [UUID: BestTranscriptionProgress] = [:]

    var hasRunningJobs: Bool {
        !tasks.isEmpty
    }

    init(
        recognizer: any BestWhisperRecognizing,
        store: BestTranscriptionStore = BestTranscriptionStore()
    ) {
        self.recognizer = recognizer
        self.store = store
    }

    func progress(for meetingID: UUID) -> BestTranscriptionProgress {
        progressByMeeting[meetingID] ?? BestTranscriptionProgress()
    }

    func startOrResume(
        _ request: BestTranscriptionRequest,
        forceReprocess: Bool = false,
        completion: @escaping (Result<BestTranscriptArtifact, Error>) -> Void
    ) {
        completionHandlers[request.meetingID, default: []].append(completion)
        guard tasks[request.meetingID] == nil,
              pausedForRecording[request.meetingID] == nil else { return }
        userCancelled.remove(request.meetingID)
        let spec = JobSpec(
            request: request,
            forceReprocess: forceReprocess
        )
        activeRequests[request.meetingID] = spec
        if isPausedForRecording || isTerminating {
            pausedForRecording[request.meetingID] = spec
            suspendingForRecording.insert(request.meetingID)
            update(request.meetingID, stage: .interrupted, fraction: 0)
            return
        }
        update(request.meetingID, stage: .queued, fraction: 0)
        launch(spec)
    }

    private func launch(_ spec: JobSpec) {
        let request = spec.request
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result: Result<BestTranscriptArtifact, Error>
            do {
                result = .success(
                    try await self.process(
                        request,
                        forceReprocess: spec.forceReprocess
                    )
                )
            } catch {
                result = .failure(error)
            }
            self.tasks[request.meetingID] = nil
            if self.suspendingForRecording.remove(request.meetingID) != nil {
                // A recording can end before an uncooperative model returns.
                // Keep that task owned and resume only after its gate releases.
                self.resumePausedJobIfPossible(request.meetingID)
                return
            }
            self.activeRequests.removeValue(forKey: request.meetingID)
            let handlers = self.completionHandlers.removeValue(
                forKey: request.meetingID
            ) ?? []
            handlers.forEach { $0(result) }
        }
        tasks[request.meetingID] = task
    }

    func reprocess(
        _ request: BestTranscriptionRequest,
        completion: @escaping (Result<BestTranscriptArtifact, Error>) -> Void
    ) {
        startOrResume(request, forceReprocess: true, completion: completion)
    }

    func cancel(meetingID: UUID) {
        pausedForRecording.removeValue(forKey: meetingID)
        activeRequests.removeValue(forKey: meetingID)
        suspendingForRecording.remove(meetingID)
        userCancelled.insert(meetingID)
        tasks[meetingID]?.cancel()
        if tasks[meetingID] == nil {
            let handlers = completionHandlers.removeValue(forKey: meetingID) ?? []
            handlers.forEach { $0(.failure(BestTranscriptionError.cancelled)) }
        }
        Task {
            try? await store.markJob(
                meetingID: meetingID,
                state: .cancelled,
                error: nil
            )
        }
        update(
            meetingID,
            stage: .cancelled,
            error: BestTranscriptionError.cancelled.errorDescription
        )
    }

    func removeMeeting(_ meetingID: UUID) async {
        if let task = tasks.removeValue(forKey: meetingID) {
            suspendingForRecording.remove(meetingID)
            task.cancel()
            _ = await task.result
        }
        activeRequests.removeValue(forKey: meetingID)
        pausedForRecording.removeValue(forKey: meetingID)
        userCancelled.remove(meetingID)
        completionHandlers.removeValue(forKey: meetingID)
        progressByMeeting.removeValue(forKey: meetingID)
        try? await store.removeMeeting(meetingID)
    }

    func prepareForTermination() async {
        isTerminating = true
        isPausedForRecording = true
        let running = tasks
        for meetingID in running.keys {
            suspendingForRecording.insert(meetingID)
            update(meetingID, stage: .interrupted)
        }
        for (meetingID, task) in running {
            _ = await task.result
            try? await store.markJob(
                meetingID: meetingID,
                state: .interrupted,
                error: nil
            )
        }
        tasks.removeAll()
    }

    func pauseForRecording() async {
        isPausedForRecording = true
        for (meetingID, spec) in activeRequests {
            pausedForRecording[meetingID] = spec
            suspendingForRecording.insert(meetingID)
            update(meetingID, stage: .interrupted)
        }
        // Do not await an active Core ML batch on the recording-start path.
        // Its task remains tracked until it commits its completed checkpoints;
        // no subsequent batch, queued meeting, or replacement task can start.
    }

    func resumeAfterRecording() {
        guard !isTerminating else { return }
        isPausedForRecording = false
        for meetingID in Array(pausedForRecording.keys) {
            resumePausedJobIfPossible(meetingID)
        }
    }

    private func resumePausedJobIfPossible(_ meetingID: UUID) {
        guard !isPausedForRecording, !isTerminating,
              tasks[meetingID] == nil,
              let spec = pausedForRecording.removeValue(forKey: meetingID) else { return }
        suspendingForRecording.remove(meetingID)
        activeRequests[meetingID] = spec
        update(meetingID, stage: .queued)
        launch(spec)
    }

    func latestCompletedArtifact(meetingID: UUID) async -> BestTranscriptArtifact? {
        await store.loadLatestCompletedArtifact(meetingID: meetingID)
    }

    func process(
        _ request: BestTranscriptionRequest,
        forceReprocess: Bool
    ) async throws -> BestTranscriptArtifact {
        update(request.meetingID, stage: .queued, fraction: 0)
        var holdsJobGate = false
        defer {
            if holdsJobGate { Task { await jobGate.release() } }
        }

        do {
            try await jobGate.acquire()
            holdsJobGate = true
            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()
            update(request.meetingID, stage: .validating, fraction: 0.01)
            try await Self.preflightDiskSpace()
            try throwIfCheckpointPauseRequested(request.meetingID)

            let validation = try await Self.validateTracks(request)
            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()
            if validation.tracks.isEmpty,
               !forceReprocess,
               let cached = await store.loadLatestCompletedArtifact(
                   meetingID: request.meetingID
               ) {
                update(
                    request.meetingID,
                    stage: .ready,
                    fraction: 1,
                    warning: cached.warnings.first
                )
                return cached
            }
            if !validation.damagedWarnings.isEmpty,
               !request.allowPartialDamagedTracks,
               !validation.tracks.isEmpty {
                throw BestTranscriptionError.damagedAudioAvailable(
                    validation.damagedWarnings
                )
            }
            guard !validation.tracks.isEmpty else {
                throw BestTranscriptionError.noAudio
            }
            let fingerprint = try await Self.makeFingerprint(
                tracks: validation.tracks,
                vocabulary: request.vocabulary,
                modelIdentity: recognizer.modelIdentity
            )
            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()

            if !forceReprocess,
               let cached = try await store.loadCompletedArtifact(
                   meetingID: request.meetingID,
                   fingerprint: fingerprint
               ) {
                try throwIfCheckpointPauseRequested(request.meetingID)
                try Task.checkCancellation()
                update(
                    request.meetingID,
                    stage: .ready,
                    fraction: 1,
                    warning: cached.warnings.first
                )
                return cached
            }

            if forceReprocess {
                try await store.resetPendingJob(meetingID: request.meetingID)
                // Reprocess invalidates old checkpoints once. A later recording
                // pause must resume the new checkpoints rather than erase them.
                if activeRequests[request.meetingID] != nil {
                    activeRequests[request.meetingID]?.forceReprocess = false
                    pausedForRecording[request.meetingID]?.forceReprocess = false
                }
            }
            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()
            try await store.saveJobManifest(
                .init(
                    schemaVersion: BestTranscriptionManifest.schemaVersion,
                    meetingID: request.meetingID,
                    state: .waitingForModel,
                    fingerprint: fingerprint,
                    artifactFilename: nil,
                    updatedAt: .now,
                    lastError: nil
                )
            )

            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()
            update(request.meetingID, stage: .preparingModel, fraction: 0.03)
            try await recognizer.prepareLocalOnly(
                modelName: recognizer.modelIdentity
            )
            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()

            var checkpoints = forceReprocess
                ? []
                : try await store.loadCheckpoints(
                    meetingID: request.meetingID,
                    fingerprint: fingerprint
                )
            let checkpointKeys = Set(
                checkpoints.map { Self.checkpointKey($0.speaker, $0.window.index) }
            )
            var knownCheckpointKeys = checkpointKeys
            let totalFrames = validation.tracks.reduce(Int64.zero) {
                $0 + $1.canonicalFrameCount
            }
            var processedFrames = checkpoints.reduce(Int64.zero) {
                $0 + max(0, $1.window.ownedEndFrame - $1.window.ownedStartFrame)
            }
            let startedAt = Date()

            try await store.saveJobManifest(
                .init(
                    schemaVersion: BestTranscriptionManifest.schemaVersion,
                    meetingID: request.meetingID,
                    state: .transcribing,
                    fingerprint: fingerprint,
                    artifactFilename: nil,
                    updatedAt: .now,
                    lastError: nil
                )
            )

            for track in validation.tracks {
                let stage: BestTranscriptionStage = track.speaker == .them
                    ? .transcribingSystem
                    : .transcribingMicrophone
                let windows = BestAudioWindowPlanner.plan(
                    totalFrames: track.canonicalFrameCount,
                    sampleRate: BestAudioFileReader.canonicalSampleRate,
                    overlapSeconds: recognizer.windowOverlapSeconds
                )
                let batchSize = max(1, recognizer.preferredWindowBatchSize)
                for batchStart in stride(from: 0, to: windows.count, by: batchSize) {
                    try throwIfCheckpointPauseRequested(request.meetingID)
                    try Task.checkCancellation()
                    let batch = windows[batchStart..<min(batchStart + batchSize, windows.count)]
                    var inputs: [BestWhisperWindowInput] = []
                    var inputWindowIndices: [Int] = []
                    for window in batch {
                        let key = Self.checkpointKey(track.speaker, window.index)
                        guard !knownCheckpointKeys.contains(key) else { continue }
                        let samples = try await Self.readWindow(
                            url: track.url,
                            window: window
                        )
                        try throwIfCheckpointPauseRequested(request.meetingID)
                        try Task.checkCancellation()
                        guard !BestTranscriptionSignalPolicy.isSilent(samples) else { continue }
                        inputs.append(BestWhisperWindowInput(
                            samples: samples,
                            speaker: track.speaker,
                            absoluteWindowStart: Double(window.startFrame)
                                / BestAudioFileReader.canonicalSampleRate
                        ))
                        inputWindowIndices.append(window.index)
                    }

                    let recognizedBatch: [[BestTranscriptSegment]]
                    try throwIfCheckpointPauseRequested(request.meetingID)
                    try Task.checkCancellation()
                    if inputs.isEmpty {
                        recognizedBatch = []
                    } else {
                        recognizedBatch = try await recognizer.transcribeWindows(
                            inputs,
                            vocabulary: request.vocabulary
                        )
                    }
                    guard recognizedBatch.count == inputs.count else {
                        throw BestTranscriptionError.failed(
                            "Whisper returned an incomplete audio batch."
                        )
                    }
                    try Task.checkCancellation()
                    let recognizedByIndex = Dictionary(
                        uniqueKeysWithValues: zip(inputWindowIndices, recognizedBatch)
                    )
                    for window in batch {
                        try Task.checkCancellation()
                        let key = Self.checkpointKey(track.speaker, window.index)
                        guard !knownCheckpointKeys.contains(key) else { continue }
                        let owned = BestWindowOwnership.segmentsOwned(
                            recognizedByIndex[window.index] ?? [],
                            by: window,
                            sampleRate: BestAudioFileReader.canonicalSampleRate
                        )
                        let checkpoint = BestTranscriptionCheckpoint(
                            meetingID: request.meetingID,
                            fingerprint: fingerprint,
                            speaker: track.speaker,
                            window: window,
                            segments: owned
                        )
                        try await store.saveCheckpoint(checkpoint)
                        checkpoints.append(checkpoint)
                        knownCheckpointKeys.insert(key)
                        processedFrames += max(
                            0,
                            window.ownedEndFrame - window.ownedStartFrame
                        )
                        updateTranscriptionProgress(
                            request.meetingID,
                            stage: stage,
                            processedFrames: processedFrames,
                            totalFrames: totalFrames,
                            startedAt: startedAt,
                            warning: validation.warnings.first
                        )
                    }
                    try throwIfCheckpointPauseRequested(request.meetingID)
                }
            }

            try Task.checkCancellation()
            try throwIfCheckpointPauseRequested(request.meetingID)
            update(request.meetingID, stage: .merging, fraction: 0.92)
            try await store.markJob(
                meetingID: request.meetingID,
                state: .merging,
                error: nil
            )
            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()
            let aligned = Self.align(
                checkpoints.flatMap(\.segments),
                tracks: validation.tracks,
                timeline: request.timeline
            )
            let merged = BestTranscriptMerger.merge(aligned.segments)

            update(request.meetingID, stage: .saving, fraction: 0.97)
            try await store.markJob(
                meetingID: request.meetingID,
                state: .exporting,
                error: nil
            )
            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()
            let artifact = BestTranscriptArtifact(
                meetingID: request.meetingID,
                generatedAt: .now,
                modelID: recognizer.modelIdentity,
                pipelineVersion: Self.pipelineVersion,
                fingerprint: fingerprint,
                alignmentQuality: recognizer.hasWordAlignment ? aligned.quality : .estimated,
                warnings: validation.warnings + aligned.warnings
                    + (recognizer.hasWordAlignment ? [] : ["Transcript positions are approximate; the recorded audio is unchanged."]),
                segments: merged
            )
            try await store.saveCompletedArtifact(artifact)
            try throwIfCheckpointPauseRequested(request.meetingID)
            try Task.checkCancellation()
            update(
                request.meetingID,
                stage: .ready,
                fraction: 1,
                processedDuration: Double(totalFrames)
                    / BestAudioFileReader.canonicalSampleRate,
                totalDuration: Double(totalFrames)
                    / BestAudioFileReader.canonicalSampleRate,
                warning: artifact.warnings.first
            )
            return artifact
        } catch is BestCheckpointInterruption {
            try? await store.markJob(
                meetingID: request.meetingID,
                state: .interrupted,
                error: nil
            )
            update(
                request.meetingID,
                stage: .interrupted,
                error: nil
            )
            throw BestCheckpointInterruption()
        } catch is CancellationError {
            let cancellation = await recordCancellation(request.meetingID)
            throw cancellation
        } catch {
            // Some native engines report their own error when cancellation
            // terminates inference. Preserve the user's cancellation state.
            if Task.isCancelled {
                let cancellation = await recordCancellation(request.meetingID)
                throw cancellation
            }
            if isPausedForRecording || suspendingForRecording.contains(request.meetingID) {
                try? await store.markJob(
                    meetingID: request.meetingID,
                    state: .interrupted,
                    error: nil
                )
                update(request.meetingID, stage: .interrupted)
                throw BestCheckpointInterruption()
            }
            try? await store.markJob(
                meetingID: request.meetingID,
                state: .failed,
                error: error.localizedDescription
            )
            update(
                request.meetingID,
                stage: .failed,
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func recordCancellation(_ meetingID: UUID) async -> BestTranscriptionError {
        let cancelledByUser = userCancelled.remove(meetingID) != nil
        try? await store.markJob(
            meetingID: meetingID,
            state: cancelledByUser ? .cancelled : .interrupted,
            error: nil
        )
        update(
            meetingID,
            stage: cancelledByUser ? .cancelled : .interrupted,
            error: BestTranscriptionError.cancelled.errorDescription
        )
        return .cancelled
    }

    private func throwIfCheckpointPauseRequested(_ meetingID: UUID) throws {
        try Task.checkCancellation()
        if isPausedForRecording || suspendingForRecording.contains(meetingID) {
            throw BestCheckpointInterruption()
        }
    }

    private func updateTranscriptionProgress(
        _ meetingID: UUID,
        stage: BestTranscriptionStage,
        processedFrames: Int64,
        totalFrames: Int64,
        startedAt: Date,
        warning: String?
    ) {
        let ratio = totalFrames > 0
            ? min(1, max(0, Double(processedFrames) / Double(totalFrames)))
            : 0
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = ratio > 0
            ? max(0, elapsed / ratio - elapsed)
            : nil
        update(
            meetingID,
            stage: stage,
            fraction: 0.05 + ratio * 0.85,
            processedDuration: Double(processedFrames)
                / BestAudioFileReader.canonicalSampleRate,
            totalDuration: Double(totalFrames)
                / BestAudioFileReader.canonicalSampleRate,
            estimatedRemaining: remaining,
            warning: warning
        )
    }

    private func update(
        _ meetingID: UUID,
        stage: BestTranscriptionStage,
        fraction: Double? = nil,
        processedDuration: TimeInterval? = nil,
        totalDuration: TimeInterval? = nil,
        estimatedRemaining: TimeInterval? = nil,
        warning: String? = nil,
        error: String? = nil
    ) {
        var progress = progressByMeeting[meetingID] ?? BestTranscriptionProgress()
        switch stage {
        case .queued, .validating, .preparingModel, .transcribingSystem,
             .transcribingMicrophone, .merging, .saving, .ready:
            if userCancelled.contains(meetingID) {
                progress.stage = .cancelled
            } else {
                progress.stage = isPausedForRecording || suspendingForRecording.contains(meetingID)
                    ? .interrupted : stage
            }
        default:
            progress.stage = stage
        }
        if let fraction { progress.fraction = min(1, max(0, fraction)) }
        if let processedDuration { progress.processedDuration = processedDuration }
        if let totalDuration { progress.totalDuration = totalDuration }
        progress.estimatedRemaining = estimatedRemaining
        progress.warning = warning
        progress.error = error
        progressByMeeting[meetingID] = progress
    }

    private static func checkpointKey(
        _ speaker: BestTranscriptSpeaker,
        _ index: Int
    ) -> String {
        "\(speaker.rawValue)-\(index)"
    }

    private static func validateTracks(
        _ request: BestTranscriptionRequest
    ) async throws -> (
        tracks: [BestAudioTrackInfo],
        warnings: [String],
        damagedWarnings: [String]
    ) {
        await Task.detached(priority: .utility) {
            var tracks: [BestAudioTrackInfo] = []
            var warnings: [String] = []
            var damagedWarnings: [String] = []
            let candidates: [(BestTranscriptSpeaker, URL?)] = [
                (.them, request.systemAudioURL),
                (.me, request.micAudioURL),
            ]
            for (speaker, url) in candidates {
                guard let url else {
                    let label = speaker == .me ? "Microphone" : "System"
                    warnings.append("\(label) audio was not recorded.")
                    continue
                }
                do {
                    tracks.append(
                        try BestAudioFileReader.inspect(url: url, speaker: speaker)
                    )
                } catch {
                    let label = speaker == .me ? "Microphone" : "System"
                    let warning = "\(label) audio could not be read."
                    warnings.append(warning)
                    damagedWarnings.append(warning)
                }
            }
            return (
                tracks.sorted { $0.speaker == .them && $1.speaker == .me },
                warnings,
                damagedWarnings
            )
        }.value
    }

    private static func makeFingerprint(
        tracks: [BestAudioTrackInfo],
        vocabulary: String,
        modelIdentity: String
    ) async throws -> BestTranscriptionFingerprint {
        try await Task.detached(priority: .utility) {
            try BestTranscriptionFingerprintBuilder.make(
                tracks: tracks.map { ($0.speaker, $0.url) },
                modelID: modelIdentity,
                pipelineVersion: Self.pipelineVersion,
                vocabulary: vocabulary
            )
        }.value
    }

    private static func readWindow(
        url: URL,
        window: BestAudioWindow
    ) async throws -> [Float] {
        try await Task.detached(priority: .utility) {
            try BestAudioFileReader.readWindow(url: url, window: window)
        }.value
    }

    private static func preflightDiskSpace() async throws {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let available = try await Task.detached(priority: .utility) {
            let values = try root.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            return values.volumeAvailableCapacityForImportantUsage ?? Int64.max
        }.value
        guard available >= 256 * 1_024 * 1_024 else {
            throw BestTranscriptionError.insufficientDiskSpace
        }
    }

    private static func align(
        _ segments: [BestTranscriptSegment],
        tracks: [BestAudioTrackInfo],
        timeline: AudioTimelineManifest?
    ) -> (
        segments: [BestTranscriptSegment],
        quality: BestTranscriptAlignmentQuality,
        warnings: [String]
    ) {
        let durationBySpeaker = Dictionary(
            uniqueKeysWithValues: tracks.map { ($0.speaker, $0.duration) }
        )
        let referenceDuration = tracks.map(\.duration).max() ?? 0
        var warnings: [String] = []
        let hasExactTimeline = timeline?.schemaVersion
            == AudioTimelineManifest.schemaVersion
            && tracks.allSatisfy { timeline?.track(for: $0.speaker) != nil }

        let aligned = segments.map { segment -> BestTranscriptSegment in
            var output = segment
            let offset = timeline?.track(for: segment.speaker)?.startOffset ?? 0
            let sourceDuration = durationBySpeaker[segment.speaker] ?? referenceDuration
            let scale: Double
            if hasExactTimeline || sourceDuration <= 0 || referenceDuration <= 0 {
                scale = 1
            } else {
                scale = referenceDuration / sourceDuration
            }
            output.startTime = offset + segment.startTime * scale
            output.endTime = offset + segment.endTime * scale
            output.words = segment.words.map { word in
                var adjusted = word
                adjusted.startTime = offset + word.startTime * scale
                adjusted.endTime = offset + word.endTime * scale
                return adjusted
            }
            return output
        }

        if !hasExactTimeline, tracks.count > 1,
           let shortest = tracks.map(\.duration).min(),
           referenceDuration - shortest > max(1, referenceDuration * 0.002) {
            warnings.append(
                "Speaker timing was estimated because this recording predates precise track synchronization."
            )
        }
        return (
            aligned,
            hasExactTimeline ? .exact : .estimated,
            warnings
        )
    }
}
