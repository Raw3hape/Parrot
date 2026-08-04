import SwiftUI
import SwiftData
import CoreGraphics
import AVFoundation

/// Orchestrates audio capture, transcription, and storage for a recording session.
@MainActor
@Observable
final class RecordingManager {
    let audioCaptureManager = AudioCaptureManager()
    let transcriptionEngine: TranscriptionEngine
    let bestTranscriptionCoordinator: BestTranscriptionCoordinator
    let meetingTitleCoordinator: MeetingTitleCoordinator
    let callDetection: CallDetectionCoordinator
    let diarizationEngine = DiarizationEngine()
    let callAnalysisEngine = CallAnalysisEngine()
    let knowledgeBase = KnowledgeBaseService()
    let profileStore = ProfileStore()

    /// Optional one-line context for the next call, set from the dashboard.
    var nextCallBrief = ""

    private(set) var isRecording = false
    private(set) var recordingStartTime: Date?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var currentMeeting: Meeting?

    /// Guards against a second startRecording slipping in during the `await`s
    /// before isRecording is set — which would start a duplicate transcription
    /// loop and double every segment.
    private(set) var isStarting = false
    /// Mirror of isStarting for the stop path: stop now drains the transcription
    /// backlog (seconds, not instant), so without this a double-stop would persist
    /// insights twice and run postProcess twice, and a start-during-stop would
    /// cancel the draining loop and share buffers with the old session. Readable
    /// so the live view can show a "Finalizing…" state.
    private(set) var isStopping = false
    private var stopTask: Task<Void, Never>?
    private var postProcessingTasks: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var modelContext: ModelContext?
    private(set) var storageError: String?
    private(set) var isApplicationPrepared = false

    init() {
        let whisperGate = WhisperInferenceGate()
        let whisperService = WhisperModelService(inferenceGate: whisperGate)
        transcriptionEngine = TranscriptionEngine(whisperService: whisperService)
        bestTranscriptionCoordinator = BestTranscriptionCoordinator(
            recognizer: whisperService
        )
        meetingTitleCoordinator = MeetingTitleCoordinator()
        callDetection = CallDetectionCoordinator(
            isEnabled: CallDetectionPreference.isEnabled()
        )
        callAnalysisEngine.knowledgeBase = knowledgeBase
    }

    /// Restores lightweight application state without loading either speech
    /// model. This keeps an always-on menu-bar launch cheap; models are prepared
    /// on the first explicit recording request (or from Settings).
    func prepareApplication(modelContext: ModelContext) async {
        self.modelContext = modelContext
        meetingTitleCoordinator.configure(modelContext: modelContext)
        guard !isApplicationPrepared else { return }
        isApplicationPrepared = true
        let resumable = Self.reconcileOrphanedRecordings(in: modelContext)
        profileStore.seedAndMigrateIfNeeded(context: modelContext, knowledgeBase: knowledgeBase)
        for meeting in resumable {
            enqueuePostProcessing(for: meeting)
        }
    }

    /// Compatibility entry point for tools that intentionally want the models
    /// ready immediately. Normal app startup uses `prepareApplication`.
    func prepare(modelContext: ModelContext) async {
        await prepareApplication(modelContext: modelContext)
        await transcriptionEngine.loadModel()
    }

    /// A meeting left in `.recording` or `.processing` means a previous session was
    /// killed (crash or force-quit) before it could finish. Those can never resume
    /// and their audio file was never finalized, so mark them failed instead of
    /// letting them linger as if active.
    private static func reconcileOrphanedRecordings(in context: ModelContext) -> [Meeting] {
        guard let meetings = try? context.fetch(FetchDescriptor<Meeting>()) else { return [] }
        var changed = false
        for meeting in meetings where meeting.status == .recording {
            meeting.status = .failed
            if meeting.errorMessage == nil {
                meeting.errorMessage = "Recording was interrupted. Any saved audio and transcript were preserved."
            }
            changed = true
        }
        if changed { try? context.save() }
        return meetings.filter { $0.status == .processing }
    }

    // MARK: - Recording Control

    /// The one shared entry point for every "start recording" button — checks
    /// permissions, then starts. Returns without starting (and without throwing)
    /// when a permission flow was triggered instead.
    func preflightPermissionsAndStart(modelContext: ModelContext) async throws {
        guard !isRecording, !isStarting, !isStopping else { return }
        isStarting = true
        defer { isStarting = false }

        // Check Screen Recording permission BEFORE touching any ScreenCaptureKit
        // API. Calling SCShareableContent while unauthorized makes macOS pop its
        // own prompt AND throws — the app then showed a second custom alert,
        // hence two dialogs. Preflight, trigger the single official prompt if
        // needed, stop.
        guard CGPreflightScreenCaptureAccess() else {
            if !CGRequestScreenCaptureAccess() {
                // Previously denied: macOS won't re-prompt, so guide the user
                // straight to the right Settings pane.
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }

        // Ensure the microphone is authorized so the user's own voice ("Me")
        // is captured. Without this the engine runs but feeds silence.
        // Non-fatal: system audio still records if denied.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        default:
            break
        }

        try await prepareModelsAndStart(modelContext: modelContext)
    }

    func startRecording(modelContext: ModelContext) async throws {
        // Reject re-entry up front (before any await) so a double-trigger can't
        // start two recordings / two transcription loops.
        guard !isRecording, !isStarting, !isStopping else { return }
        isStarting = true
        defer { isStarting = false }
        try await prepareModelsAndStart(modelContext: modelContext)
    }

    private func prepareModelsAndStart(modelContext: ModelContext) async throws {
        self.modelContext = modelContext
        await prepareApplication(modelContext: modelContext)
        await meetingTitleCoordinator.pauseForRecording()
        await bestTranscriptionCoordinator.pauseForRecording()
        var recordingDidStart = false
        defer {
            if !recordingDidStart {
                meetingTitleCoordinator.resumeAfterRecording()
                bestTranscriptionCoordinator.resumeAfterRecording()
            }
        }
        if !transcriptionEngine.isReady {
            await transcriptionEngine.loadModel()
        }
        guard transcriptionEngine.isReady else {
            throw RecordingError.modelNotReady
        }
        storageError = nil

        // Create meeting
        let meeting = Meeting()
        modelContext.insert(meeting)

        // Persist active profile/brief/snapshot onto the meeting
        let profile = profileStore.activeProfile
        meeting.profile = profile
        meeting.brief = nextCallBrief.nilIfEmpty
        meeting.profileSnapshotData = profile.flatMap { try? JSONEncoder().encode($0.kinds) }

        // Establish a durable draft before touching capture hardware. If the
        // store is unavailable (for example a full disk), fail without leaving
        // an untracked recording running in memory.
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(meeting)
            throw error
        }
        currentMeeting = meeting

        // Arm the sink and transcription intake before hardware starts so the
        // first system/mic buffers cannot fall through a setup gap.
        audioCaptureManager.onAudioBuffer = { [weak self] buffer, source in
            self?.transcriptionEngine.appendAudio(buffer, source: source)
        }

        // Wire transcription output to storage and the live copilot
        transcriptionEngine.onSegment = { [weak self, weak meeting] result in
            guard let self, let meeting else { return }
            self.addSegment(result, to: meeting)
            self.callAnalysisEngine.ingest(
                text: result.text,
                at: result.endTime,
                source: result.source
            )
        }

        // Reserve a live transcription session before startCapture suspends.
        // This also makes model reload a safe no-op throughout hardware setup.
        guard transcriptionEngine.startTranscribing(meetingStartTime: .now) else {
            audioCaptureManager.onAudioBuffer = nil
            transcriptionEngine.onSegment = nil
            if currentMeeting === meeting { currentMeeting = nil }
            modelContext.delete(meeting)
            try? modelContext.save()
            throw RecordingError.modelNotReady
        }

        // Set up audio capture. On failure, unwind the already-armed intake and
        // remove the durable draft instead of leaving an orphaned live session.
        do {
            try await audioCaptureManager.startCapture()
        } catch {
            audioCaptureManager.onAudioBuffer = nil
            await transcriptionEngine.stopTranscribing()
            transcriptionEngine.onSegment = nil
            if currentMeeting === meeting { currentMeeting = nil }
            modelContext.delete(meeting)
            try? modelContext.save()
            throw error
        }
        meeting.systemAudioPath = audioCaptureManager.systemAudioURL?.path ?? ""
        meeting.micAudioPath = audioCaptureManager.micAudioURL?.path

        do {
            try modelContext.save()
        } catch {
            await audioCaptureManager.stopCapture()
            audioCaptureManager.onAudioBuffer = nil
            await transcriptionEngine.stopTranscribing()
            transcriptionEngine.onSegment = nil
            if currentMeeting === meeting { currentMeeting = nil }
            modelContext.delete(meeting)
            try? modelContext.save()
            throw error
        }

        // Start the optional copilot loop only after capture is confirmed.
        callAnalysisEngine.provider.resetUsage()  // this call's token meter starts at zero
        callAnalysisEngine.start(profile: profile, brief: nextCallBrief)

        recordingStartTime = .now
        isRecording = true
        recordingDidStart = true

        // Start elapsed time timer
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = Date.now.timeIntervalSince(start)
            }
        }
    }

    func stopRecording() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard isRecording else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStopRecording()
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStopRecording() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        timer?.invalidate()
        timer = nil

        // Stop the copilot (its ingest no-ops once inactive), then capture — so
        // the transcription buffers stop growing and the drain below terminates.
        // Capture stops first also so both .caf files are finalized before the
        // diarization task can read them.
        callAnalysisEngine.stop()
        await audioCaptureManager.stopCapture()
        audioCaptureManager.onAudioBuffer = nil

        // Drain the transcription backlog so the call's final words land before
        // the transcript is assembled for the summary/coaching reports.
        await transcriptionEngine.stopTranscribing()
        transcriptionEngine.onSegment = nil
        let transcriptTimedOut = transcriptionEngine.lastStopTimedOut

        // Update meeting
        if let meeting = currentMeeting {
            meeting.duration = elapsedTime
            meeting.status = transcriptTimedOut ? .failed : .processing
            if transcriptTimedOut {
                meeting.errorMessage = "Local transcription stopped responding before the final phrases completed. All recorded audio is preserved and can still be played or opened from local storage."
            }
            if let timeline = audioCaptureManager.lastTimelineManifest {
                do {
                    try AudioTimelineStore.save(timeline, meetingID: meeting.id)
                } catch {
                    NSLog(
                        "ParrotMetric event=timeline_save_failed meeting=%@ error=%@",
                        meeting.id.uuidString,
                        error.localizedDescription
                    )
                }
            }

            // Persist the copilot's insights so they survive into the meeting report.
            // Same SwiftData rule as addSegment: insert before setting the relationship.
            for insight in callAnalysisEngine.insights {
                let stored = CallInsight(from: insight)
                modelContext?.insert(stored)
                stored.meeting = meeting
            }
            do {
                try modelContext?.save()
            } catch {
                storageError = error.localizedDescription
                meeting.errorMessage = "The transcript is saved in memory, but Parrot could not persist the latest changes: \(error.localizedDescription)"
            }

            // Post-processing chain, strictly sequential: polish rebuilds the
            // transcript (optional, best-effort), diarization refines labels on
            // whatever transcript survived, and the report is generated from
            // the FINAL text — never from a transcript that's about to change.
            if !transcriptTimedOut {
                enqueuePostProcessing(for: meeting)
            }
        }

        isRecording = false
        elapsedTime = 0
        recordingStartTime = nil
        bestTranscriptionCoordinator.resumeAfterRecording()
        meetingTitleCoordinator.resumeAfterRecording()
    }

    /// Normal Cmd-Q / menu quit waits for an in-flight start to settle and then
    /// performs the same deterministic Stop & Save path as the UI.
    func prepareForTermination() async {
        let deadline = ContinuousClock.now + .seconds(30)
        while isStarting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isRecording || isStopping {
            await stopRecording()
        }
        await meetingTitleCoordinator.prepareForTermination()
        await bestTranscriptionCoordinator.prepareForTermination()
    }

    // MARK: - Deletion

    private func enqueuePostProcessing(for meeting: Meeting) {
        guard postProcessingTasks[meeting.id] == nil else { return }
        let id = meeting.id
        postProcessingTasks[id] = Task { @MainActor [weak self, weak meeting] in
            guard let self, let meeting, !Task.isCancelled else { return }
            defer { self.postProcessingTasks[id] = nil }
            let polishSeconds = 0.0
            await self.postProcess(meeting: meeting)
            guard !Task.isCancelled else { return }
            self.meetingTitleCoordinator.enqueue(meeting)
            if self.callAnalysisEngine.isEnabled,
               self.callAnalysisEngine.provider.isConfigured {
                await self.generateSummary(meeting: meeting)
            }
            guard !Task.isCancelled else { return }
            self.writeAIUsage(meeting: meeting, polishSeconds: polishSeconds)
        }
    }

    /// Deletes a meeting and its audio files. The only removal path in the app —
    /// without it storage grows forever. Refuses the active recording.
    func delete(_ meeting: Meeting) async {
        guard !((isStarting || isRecording || isStopping)
                && meeting.id == currentMeeting?.id) else { return }
        postProcessingTasks.removeValue(forKey: meeting.id)?.cancel()
        meetingTitleCoordinator.removeMeeting(meeting.id)
        await bestTranscriptionCoordinator.removeMeeting(meeting.id)
        for path in [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? AudioTimelineStore.remove(meetingID: meeting.id)
        if currentMeeting?.id == meeting.id { currentMeeting = nil }
        modelContext?.delete(meeting)
        try? modelContext?.save()
    }

    /// The single rename path protects a user title from any in-flight local
    /// background generation and persists it immediately.
    func rename(_ meeting: Meeting, to draft: String) {
        meetingTitleCoordinator.rename(meeting, draft: draft)
    }

    // MARK: - Segment Storage

    private func addSegment(
        _ result: TranscriptionEngine.TranscriptionResult,
        to meeting: Meeting
    ) {
        // Use the live meeting object directly. The previous code looked the
        // meeting up via model(for: meetingID) where meetingID was captured before
        // the context was saved — i.e. a TEMPORARY identifier that goes stale after
        // save. Resolving that stale id returned a malformed object and assigning it
        // to segment.meeting tripped a SwiftData assertion (crash). currentMeeting
        // is the same registered instance in the same context, set before any
        // segment can arrive.
        guard let modelContext else { return }

        let segment = TranscriptSegment(
            startTime: result.startTime,
            endTime: result.endTime,
            text: result.text,
            speakerLabel: result.source.label,
            confidence: result.confidence
        )

        modelContext.insert(segment)
        segment.meeting = meeting
        try? modelContext.save()
    }

    // MARK: - Post-Call Summary

    private func generateSummary(meeting: Meeting) async {
        let segments = meeting.sortedSegments
        guard !segments.isEmpty else { return }

        let transcript = segments
            .map { "[\($0.formattedTimestamp)] \($0.speakerLabel ?? "Speaker"): \($0.text)" }
            .joined(separator: "\n")
        let insightTitles = meeting.sortedInsights.map { "\($0.style.label): \($0.title)" }
        let instructions = meeting.profile?.tone ?? (UserDefaults.standard.string(forKey: "copilotInstructions") ?? "")
        let counterpart = meeting.profile?.counterpart ?? "the other person"

        do {
            let summary = try await callAnalysisEngine.provider.summarize(
                transcript: transcript,
                insightTitles: insightTitles,
                instructions: instructions,
                counterpart: counterpart
            )
            meeting.summary = summary
            meeting.summaryOriginRaw = "cloud"
            meeting.summaryTranscriptFingerprint = nil
            meeting.summaryGeneratorVersion = nil
            meeting.summaryGeneratedAt = .now
            try? modelContext?.save()
        } catch {
            // Best-effort: the transcript and insights are already saved.
        }

        // Coaching + follow-ups report, with the user's real talk balance.
        let meWords = segments
            .filter { $0.speakerLabel == "Me" }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
        let totalWords = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let talkPercentMe = totalWords > 0 ? Int(Double(meWords) / Double(totalWords) * 100) : 0
        do {
            let coaching = try await callAnalysisEngine.provider.coachingReport(
                transcript: transcript,
                talkPercentMe: talkPercentMe,
                instructions: instructions,
                counterpart: counterpart
            )
            meeting.coaching = coaching
            try? modelContext?.save()
        } catch {
            // Best-effort.
        }
    }

    // MARK: - Post-call polish

    /// Re-transcribe the saved audio through Groq's large model and replace the
    /// live transcript with the cleaner one. Opt-in, best-effort: any failure
    /// leaves the live transcript untouched.
    /// Returns the seconds of audio billed (all tracks summed) for cost tracking,
    /// 0 when polish didn't run.
    @discardableResult
    private func polishTranscript(meeting: Meeting) async -> Double {
        guard PersonalBuildPolicy.cloudFeaturesAllowed,
              UserDefaults.standard.bool(forKey: "polishAfterCall"),
              let key = APIKeyStore.load(account: TranscriptionBackend.groq.keychainAccount!),
              !key.isEmpty,
              let modelContext else { return 0 }

        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        let language = (setting == nil || setting == "auto") ? nil : setting

        do {
            let polished = try await TranscriptPolisher.polish(
                systemPath: meeting.systemAudioPath.nilIfEmpty,
                micPath: meeting.micAudioPath?.nilIfEmpty,
                language: language,
                apiKey: key
            )
            guard !polished.isEmpty else { return 0 }

            for old in meeting.segments {
                modelContext.delete(old)
            }
            for s in polished {
                let segment = TranscriptSegment(
                    startTime: s.start, endTime: s.end,
                    text: s.text, speakerLabel: s.speaker, confidence: nil)
                modelContext.insert(segment)
                segment.meeting = meeting
            }
            try? modelContext.save()
            NSLog("Parrot: transcript polished — \(polished.count) segments")
            // Billed audio ≈ call duration per re-transcribed track.
            let tracks = [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty]
                .compactMap { $0 }.count
            return meeting.duration * Double(tracks)
        } catch {
            NSLog("Parrot: polish failed, keeping live transcript — \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - AI usage snapshot

    /// Freezes this call's AI usage (copilot tokens + transcription/polish audio
    /// seconds) onto the meeting so the detail view can show what it cost.
    private func writeAIUsage(meeting: Meeting, polishSeconds: Double) {
        var usage = AIUsage()
        usage.copilotModel = ClaudeAnalysisProvider.model
        usage.copilot = callAnalysisEngine.provider.usageTotals
        // ponytail: reads the backend setting at stop time; a mid-call engine
        // switch or cloud→local fallback mislabels one estimated row.
        usage.transcriptionBackend = TranscriptionBackend.local.rawValue
        usage.transcriptionSeconds = meeting.duration
        usage.transcriptionTracks = meeting.micAudioPath?.nilIfEmpty != nil ? 2 : 1
        usage.polishSeconds = polishSeconds
        meeting.aiUsageData = try? JSONEncoder().encode(usage)
        try? modelContext?.save()
    }

    // MARK: - Post-Processing

    private func postProcess(meeting: Meeting) async {
        guard let audioPath = meeting.systemAudioPath.nilIfEmpty,
              FileManager.default.fileExists(atPath: audioPath) else {
            meeting.status = .done
            try? modelContext?.save()
            return
        }

        do {
            let audioURL = URL(fileURLWithPath: audioPath)
            let speakerSegments = try await diarizationEngine.diarize(audioURL: audioURL)
            try Task.checkCancellation()

            // Assign speaker labels to transcript segments by time overlap.
            // "Me" segments come from the mic stream and are already attributed;
            // diarization only refines who's who within the system audio ("Them").
            for transcriptSegment in meeting.segments {
                guard transcriptSegment.speakerLabel != "Me" else { continue }
                let bestMatch = speakerSegments.max { a, b in
                    overlap(a, transcriptSegment) < overlap(b, transcriptSegment)
                }
                if let match = bestMatch, overlap(match, transcriptSegment) > 0 {
                    transcriptSegment.speakerLabel = match.speakerLabel
                }
            }
            meeting.status = .done
            try? modelContext?.save()
        } catch is CancellationError {
            return
        } catch {
            // Diarization is a refinement pass; the audio and transcript are
            // already saved. Keep the generic "Them" labels rather than showing
            // a perfectly good meeting as failed.
            NSLog("Parrot: diarization failed — \(error.localizedDescription)")
            meeting.status = .done
            try? modelContext?.save()
        }
    }

    /// Calculate time overlap between a speaker segment and transcript segment
    private nonisolated func overlap(
        _ speaker: DiarizationEngine.SpeakerSegmentResult,
        _ transcript: TranscriptSegment
    ) -> TimeInterval {
        let overlapStart = max(speaker.startTime, transcript.startTime)
        let overlapEnd = min(speaker.endTime, transcript.endTime)
        return max(0, overlapEnd - overlapStart)
    }

    var formattedElapsedTime: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum RecordingError: LocalizedError {
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotReady: "Local speech models are not ready yet. Please wait or retry them in Settings."
        }
    }
}
