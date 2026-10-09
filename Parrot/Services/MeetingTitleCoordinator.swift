import Foundation
import Observation
import SwiftData

typealias MeetingTitleGenerationFunction = @Sendable (MeetingTitleSnapshot) async -> MeetingTitleGeneration
typealias MeetingSummaryGenerationFunction = @Sendable (MeetingTitleSnapshot) async -> MeetingSummaryGeneration
typealias MeetingTitlePersistence = @MainActor (ModelContext) throws -> Void

/// Serializes inexpensive on-device title work and keeps it completely
/// subordinate to recording. No transcript or language model is retained after
/// a job finishes.
@MainActor
@Observable
final class MeetingTitleCoordinator {
    static let automaticTitlesKey = "automaticMeetingTitlesEnabled"
    static let generatorVersion = "qwen3.5-9b-q4km-title-v10-complete-or-empty"
    static let summaryGeneratorVersion = "qwen3.5-9b-q4km-summary-v10-complete-or-empty"
    private static let substantialTranscriptUTF8Bytes = 120

    enum State: Equatable {
        case idle
        case pausedForRecording
        case generating(UUID)
    }

    private(set) var state: State = .idle
    private(set) var queuedCount = 0
    private(set) var lastError: String?

    private let snapshotBuilder: MeetingTitleSnapshotBuilder
    private let generate: MeetingTitleGenerationFunction
    private let generateSummary: MeetingSummaryGenerationFunction
    private let summaryGenerationEnabled: Bool
    private let persist: MeetingTitlePersistence
    private let shutdownRuntime: @Sendable () async -> Void
    private let memoryRetryDelay: Duration
    private var modelContext: ModelContext?
    private var queue: [UUID] = []
    private var currentMeetingID: UUID?
    private var worker: Task<Void, Never>?
    private var runtimeShutdown: Task<Void, Never>?
    private var memoryRetryTask: Task<Void, Never>?
    private var isPaused = false
    private var isWaitingForMemory = false

    init(
        snapshotBuilder: MeetingTitleSnapshotBuilder = MeetingTitleSnapshotBuilder(),
        persist: @escaping MeetingTitlePersistence = { context in try context.save() },
        memoryRetryDelay: Duration = .seconds(30),
        shutdownRuntime: (@Sendable () async -> Void)? = nil,
        generate: MeetingTitleGenerationFunction? = nil,
        generateSummary: MeetingSummaryGenerationFunction? = nil
    ) {
        self.snapshotBuilder = snapshotBuilder
        self.persist = persist
        self.memoryRetryDelay = memoryRetryDelay
        self.summaryGenerationEnabled = generateSummary != nil || (generate == nil && generateSummary == nil)
        if generate != nil || generateSummary != nil {
            self.generate = generate ?? { snapshot in
                MeetingTitleGeneration(
                    title: nil,
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt,
                    reductionDepth: 0
                )
            }
            self.generateSummary = generateSummary ?? { snapshot in
                MeetingSummaryGeneration(
                    summary: nil,
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt
                )
            }
            self.shutdownRuntime = shutdownRuntime ?? {}
        } else {
            let runtime = QwenLocalServerRuntime()
            let generator = QwenMeetingTitleGenerator(runtime: runtime)
            let summaryGenerator = QwenMeetingSummaryGenerator(runtime: runtime)
            self.generate = { snapshot in
                await generator.generate(from: snapshot)
            }
            self.generateSummary = { snapshot in
                await summaryGenerator.generate(from: snapshot)
            }
            self.shutdownRuntime = shutdownRuntime ?? {
                await runtime.shutdownImmediately()
            }
        }
    }

    var hasRunningJobs: Bool {
        worker != nil || currentMeetingID != nil || runtimeShutdown != nil
    }

    var isAutomaticEnabled: Bool {
        Self.automaticTitlesEnabled()
    }

    func configure(modelContext: ModelContext, enqueueExisting: Bool = true) {
        self.modelContext = modelContext
        guard enqueueExisting else { return }
        enqueueEligibleMeetings()
    }

    /// Re-scans instead of persisting a raw queue, so crash recovery cannot
    /// leave stale object references or duplicate transcript data on disk.
    func enqueueEligibleMeetings() {
        guard isAutomaticEnabled, let modelContext else { return }
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        for meeting in meetings.sorted(by: { $0.date > $1.date }) where isBasicallyEligible(meeting) {
            enqueue(meeting)
        }
    }

    func enqueue(_ meeting: Meeting) {
        guard isAutomaticEnabled, isBasicallyEligible(meeting) else { return }
        if currentMeetingID == meeting.id {
            if worker?.isCancelled == true, !queue.contains(meeting.id) {
                queue.append(meeting.id)
                queuedCount = queue.count
            }
            return
        }
        guard !queue.contains(meeting.id) else {
            startWorkerIfNeeded()
            return
        }
        queue.append(meeting.id)
        queuedCount = queue.count
        startWorkerIfNeeded()
    }

    func generateMissingTitles() {
        memoryRetryTask?.cancel()
        memoryRetryTask = nil
        isWaitingForMemory = false
        lastError = nil
        enqueueEligibleMeetings()
        startWorkerIfNeeded()
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        if enabled {
            enqueueEligibleMeetings()
        } else {
            queue.removeAll()
            queuedCount = 0
            worker?.cancel()
            memoryRetryTask?.cancel()
            memoryRetryTask = nil
            isWaitingForMemory = false
            lastError = nil
        }
    }

    func rename(_ meeting: Meeting, draft: String) {
        let previous = PersistedMeetingTitle(meeting)
        guard meeting.applyManualTitle(draft) else { return }
        queue.removeAll { $0 == meeting.id }
        queuedCount = queue.count
        if currentMeetingID == meeting.id {
            worker?.cancel()
        }
        do {
            try persistChanges()
            lastError = nil
        } catch {
            previous.restore(on: meeting)
            lastError = "Parrot could not save the new meeting title. The previous title was restored."
        }
    }

    func removeMeeting(_ meetingID: UUID) {
        queue.removeAll { $0 == meetingID }
        queuedCount = queue.count
        if currentMeetingID == meetingID {
            worker?.cancel()
        }
        if queue.isEmpty, isWaitingForMemory {
            memoryRetryTask?.cancel()
            memoryRetryTask = nil
            isWaitingForMemory = false
        }
    }

    func pauseForRecording() async {
        isPaused = true
        state = .pausedForRecording
        requeueCurrentMeetingForResume()
        memoryRetryTask?.cancel()
        memoryRetryTask = nil
        isWaitingForMemory = false
        worker?.cancel()
        beginRuntimeShutdown()
        // The worker still owns the detached generator until it returns. Start
        // recording immediately; a late response cannot be persisted, and no
        // replacement worker starts until generation and shutdown both drain.
    }

    func resumeAfterRecording() {
        isPaused = false
        state = .idle
        startWorkerIfNeeded()
    }

    func prepareForTermination() async {
        isPaused = true
        let running = worker
        running?.cancel()
        memoryRetryTask?.cancel()
        memoryRetryTask = nil
        // Stop the server before awaiting a generation that may be blocked on
        // its response. Keep the shutdown task owned until it actually exits.
        beginRuntimeShutdown()
        if let runtimeShutdown { await runtimeShutdown.value }
        if let running { await running.value }
        worker = nil
        currentMeetingID = nil
        state = .idle
    }

    private func beginRuntimeShutdown() {
        guard runtimeShutdown == nil else { return }
        let shutdown = shutdownRuntime
        runtimeShutdown = Task { @MainActor [weak self] in
            await shutdown()
            guard let self else { return }
            self.runtimeShutdown = nil
            self.startWorkerIfNeeded()
        }
    }

    /// Internal deterministic seam used by unit tests and isolated QA. It uses
    /// exactly the same eligibility, fingerprint, and last-moment race checks as
    /// the background queue.
    func processImmediatelyForTesting(_ meeting: Meeting) async {
        await process(meeting)
    }

    private func startWorkerIfNeeded() {
        guard isAutomaticEnabled, !isPaused, worker == nil,
              runtimeShutdown == nil, !queue.isEmpty else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  !self.isPaused,
                  !self.isWaitingForMemory,
                  let meetingID = self.queue.first {
                self.queue.removeFirst()
                self.queuedCount = self.queue.count
                guard let meeting = self.meeting(withID: meetingID) else { continue }
                await self.process(meeting)
            }
            self.currentMeetingID = nil
            self.worker = nil
            self.state = self.isPaused ? .pausedForRecording : .idle
            if !self.isPaused, !self.isWaitingForMemory {
                self.startWorkerIfNeeded()
            }
        }
    }

    private func process(_ meeting: Meeting) async {
        guard isBasicallyEligible(meeting), !isPaused, !Task.isCancelled else { return }
        let snapshot = snapshotBuilder.build(from: meeting.sortedSegments)
        guard snapshot.coverageReceipt.isExact else {
            lastError = "The complete transcript coverage check failed. The meeting title was left unchanged."
            return
        }
        let shouldGenerateTitle = isTitleEligible(meeting)
            && (meeting.titleTranscriptFingerprint != snapshot.fingerprint
                || meeting.titleGeneratorVersion != Self.generatorVersion)
        let shouldGenerateSummary = summaryGenerationEnabled
            && isSummaryEligible(meeting)
            && (meeting.summaryTranscriptFingerprint != snapshot.fingerprint
                || meeting.summaryGeneratorVersion != Self.summaryGeneratorVersion)
        guard shouldGenerateTitle || shouldGenerateSummary else { return }

        currentMeetingID = meeting.id
        state = .generating(meeting.id)
        if shouldGenerateSummary {
            _ = await generateAndPersistSummary(for: meeting, snapshot: snapshot)
            return
        }
        if shouldGenerateTitle {
            _ = await generateAndPersistTitle(for: meeting, snapshot: snapshot)
        }
    }

    private func generateAndPersistTitle(
        for meeting: Meeting,
        snapshot: MeetingTitleSnapshot
    ) async -> Bool {
        let generate = self.generate
        let task = Task.detached(priority: .utility) { await generate(snapshot) }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !isPaused else { return false }
        if case let .deferred(reason) = result.disposition {
            handleDeferral(meetingID: meeting.id, reason: reason)
            return false
        }
        guard meeting.titleOriginRaw != "manual",
              snapshotStillMatches(meeting, snapshot: snapshot),
              result.fingerprint == snapshot.fingerprint,
              result.coverageReceipt.isExact else { return false }

        let previous = PersistedMeetingTitle(meeting)
        if let title = result.title, MeetingTitle.isValid(title) {
            meeting.title = title
            meeting.titleOriginRaw = "automatic"
        } else if meeting.titleOriginRaw == "automatic" {
            meeting.title = Meeting.defaultTitle(for: meeting.date)
            meeting.titleOriginRaw = "default"
        }
        meeting.titleTranscriptFingerprint = snapshot.fingerprint
        meeting.titleGeneratorVersion = Self.generatorVersion
        meeting.titleGeneratedAt = .now
        do {
            try persistChanges()
            lastError = nil
            return true
        } catch {
            previous.restore(on: meeting)
            lastError = "Parrot created a title but could not save it. The meeting was left unchanged."
            return false
        }
    }

    private func generateAndPersistSummary(
        for meeting: Meeting,
        snapshot: MeetingTitleSnapshot
    ) async -> Bool {
        let generateSummary = self.generateSummary
        let task = Task.detached(priority: .utility) { await generateSummary(snapshot) }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !isPaused else { return false }
        if case let .deferred(reason) = result.disposition {
            handleDeferral(meetingID: meeting.id, reason: reason)
            return false
        }
        guard isSummaryEligible(meeting),
              snapshotStillMatches(meeting, snapshot: snapshot),
              result.fingerprint == snapshot.fingerprint,
              result.coverageReceipt.isExact else { return false }

        // Nil is a valid result for silence and tiny audio checks. For a real
        // transcript it more likely means the local grounding pass could not
        // prove its output. Preserve the previous artifact and leave the job
        // eligible for a later retry instead of marking an empty result final.
        if result.summary == nil,
           snapshot.coverageReceipt.sourceUTF8ByteCount >= Self.substantialTranscriptUTF8Bytes {
            lastError = "Parrot could not ground a local summary for this meeting. The previous meeting details were preserved for a safe retry."
            return false
        }

        let previousSummary = PersistedMeetingSummary(meeting)
        let previousTitle = PersistedMeetingTitle(meeting)
        meeting.summary = result.summary.flatMap(MeetingSummary.validated)
        meeting.summaryOriginRaw = "local"
        meeting.summaryTranscriptFingerprint = snapshot.fingerprint
        meeting.summaryGeneratorVersion = Self.summaryGeneratorVersion
        meeting.summaryGeneratedAt = .now
        if meeting.titleOriginRaw != "manual" {
            if let title = result.title.flatMap(MeetingSummary.validatedContextualTitle) {
                meeting.title = title
                meeting.titleOriginRaw = "automatic"
            } else if meeting.titleOriginRaw == "automatic" {
                meeting.title = Meeting.defaultTitle(for: meeting.date)
                meeting.titleOriginRaw = "default"
            }
            meeting.titleTranscriptFingerprint = snapshot.fingerprint
            meeting.titleGeneratorVersion = Self.generatorVersion
            meeting.titleGeneratedAt = .now
        }
        do {
            try persistChanges()
            lastError = nil
            return true
        } catch {
            previousSummary.restore(on: meeting)
            previousTitle.restore(on: meeting)
            lastError = "Parrot created a summary but could not save it. The meeting was left unchanged."
            return false
        }
    }

    private func snapshotStillMatches(_ meeting: Meeting, snapshot: MeetingTitleSnapshot) -> Bool {
        let fresh = snapshotBuilder.build(from: meeting.sortedSegments)
        guard fresh.fingerprint == snapshot.fingerprint else {
            if !queue.contains(meeting.id) {
                queue.insert(meeting.id, at: 0)
                queuedCount = queue.count
            }
            return false
        }
        return true
    }

    private func meeting(withID id: UUID) -> Meeting? {
        guard let modelContext else { return nil }
        return ((try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? [])
            .first { $0.id == id }
    }

    private func persistChanges() throws {
        guard let modelContext else { throw MeetingTitleCoordinatorError.missingModelContext }
        try persist(modelContext)
    }

    private func requeueCurrentMeetingForResume() {
        guard let currentMeetingID,
              !queue.contains(currentMeetingID),
              let meeting = meeting(withID: currentMeetingID),
              isBasicallyEligible(meeting) else { return }
        queue.insert(currentMeetingID, at: 0)
        queuedCount = queue.count
    }

    private func handleDeferral(meetingID: UUID, reason: MeetingTitleDeferralReason) {
        switch reason {
        case .memoryPressure:
            if !queue.contains(meetingID) {
                queue.insert(meetingID, at: 0)
                queuedCount = queue.count
            }
            isWaitingForMemory = true
            lastError = "Local meeting details are waiting for memory. Recording and the rest of Parrot continue normally."
            scheduleMemoryRetry()
        case .runtimeUnavailable:
            lastError = "The local meeting model is unavailable. Existing meeting data was left unchanged."
        case .runtimeFailure:
            lastError = "The local meeting model stopped unexpectedly. Existing meeting data was left unchanged."
        }
    }

    private func scheduleMemoryRetry() {
        guard memoryRetryTask == nil else { return }
        let delay = memoryRetryDelay
        memoryRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.memoryRetryTask = nil
            self.isWaitingForMemory = false
            self.lastError = nil
            guard self.isAutomaticEnabled, !self.isPaused else { return }
            self.startWorkerIfNeeded()
        }
    }

    private func isBasicallyEligible(_ meeting: Meeting) -> Bool {
        guard meeting.status == .done || meeting.status == .failed else { return false }
        guard !meeting.segments.isEmpty else { return false }
        return isTitleEligible(meeting) || isSummaryEligible(meeting)
    }

    private func isTitleEligible(_ meeting: Meeting) -> Bool {
        guard meeting.titleOriginRaw != "manual" else { return false }
        // Existing custom titles predate provenance. Treat them as manual unless
        // Parrot itself already marked them automatic.
        if meeting.titleOriginRaw != "automatic", !meeting.hasLegacyPlaceholderTitle {
            return false
        }
        return true
    }

    private func isSummaryEligible(_ meeting: Meeting) -> Bool {
        let hasSummary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        // A non-local legacy/cloud report is user data. Preserve it verbatim.
        return !hasSummary || meeting.summaryOriginRaw == "local"
    }

    private static func automaticTitlesEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: automaticTitlesKey) == nil { return true }
        return defaults.bool(forKey: automaticTitlesKey)
    }
}

private enum MeetingTitleCoordinatorError: Error {
    case missingModelContext
}

private struct PersistedMeetingTitle {
    let title: String
    let origin: String
    let fingerprint: String?
    let generatorVersion: String?
    let generatedAt: Date?

    init(_ meeting: Meeting) {
        title = meeting.title
        origin = meeting.titleOriginRaw
        fingerprint = meeting.titleTranscriptFingerprint
        generatorVersion = meeting.titleGeneratorVersion
        generatedAt = meeting.titleGeneratedAt
    }

    func restore(on meeting: Meeting) {
        meeting.title = title
        meeting.titleOriginRaw = origin
        meeting.titleTranscriptFingerprint = fingerprint
        meeting.titleGeneratorVersion = generatorVersion
        meeting.titleGeneratedAt = generatedAt
    }
}

private struct PersistedMeetingSummary {
    let summary: String?
    let origin: String
    let fingerprint: String?
    let generatorVersion: String?
    let generatedAt: Date?

    init(_ meeting: Meeting) {
        summary = meeting.summary
        origin = meeting.summaryOriginRaw
        fingerprint = meeting.summaryTranscriptFingerprint
        generatorVersion = meeting.summaryGeneratorVersion
        generatedAt = meeting.summaryGeneratedAt
    }

    func restore(on meeting: Meeting) {
        meeting.summary = summary
        meeting.summaryOriginRaw = origin
        meeting.summaryTranscriptFingerprint = fingerprint
        meeting.summaryGeneratorVersion = generatorVersion
        meeting.summaryGeneratedAt = generatedAt
    }
}
