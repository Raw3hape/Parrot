import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @Environment(RecordingManager.self) private var recordingManager
    let meeting: Meeting
    /// Parent clears the selection and performs the actual delete — this view
    /// must be gone before the model object is.
    var onDelete: (() -> Void)? = nil
    /// Optional coordination seam for callers that need to cancel an in-flight
    /// automatic title job before applying a manual name.
    var onRename: ((String) -> Void)? = nil
    @State private var confirmingDelete = false
    @State private var editingTitle = false
    @State private var titleText = ""
    @State private var audioPlayer: AVAudioPlayer?      // system audio ("Them")
    @State private var micPlayer: AVAudioPlayer?        // mic audio ("Me")
    @State private var isPlaying = false
    @State private var playbackTime: TimeInterval = 0
    @State private var playbackSpeed: Float = 1.0
    @State private var playbackTimer: Timer?
    @State private var activeSegmentID: UUID?
    @State private var themNameText = ""
    @State private var showCostBreakdown = false
    @State private var showBestTranscriptProgress = false
    @State private var hasCachedBestTranscript = false
    @State private var bestExportError: String?
    @State private var partialAudioWarning: String?
    @State private var pendingPartialExportRequest: BestTranscriptionRequest?
    @State private var pendingPartialForceReprocess = false
    @State private var notesExpanded = false
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            meetingHeader

            Divider()

            if MeetingPresentationPolicy.shouldShowPlayer(
                status: meeting.status,
                hasPlayableAudio: hasPlayableAudio
            ) {
                audioPlayerBar
                Divider()
            }

            transcriptFirstContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.canvas)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            prepareMeetingView()
        }
        .onChange(of: meeting.id) { _, _ in
            prepareMeetingView()
        }
        .onDisappear {
            stopPlayback()
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Export as TXT") { exportTXT() }
                    Button("Export as SRT") { exportSRT() }
                    Divider()
                    Button("Export Best Transcript (Whisper)…") {
                        startBestTranscriptExport(forceReprocess: false)
                    }
                    .disabled(!canExportBestTranscript || bestProgress.isRunning)
                    if bestProgress.isRunning {
                        Button("Show Best Transcript Progress…") {
                            showBestTranscriptProgress = true
                        }
                    }
                    if hasCachedBestTranscript || bestProgress.stage == .ready {
                        Button("Reprocess with Whisper…") {
                            startBestTranscriptExport(forceReprocess: true)
                        }
                        .disabled(bestProgress.isRunning)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Export meeting")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { onDelete?() }
        } message: {
            Text("The recording, transcript, and insights will be permanently removed.")
        }
        .sheet(isPresented: $showBestTranscriptProgress) {
            BestTranscriptionProgressView(
                progress: bestProgress,
                onCancel: {
                    recordingManager.bestTranscriptionCoordinator.cancel(
                        meetingID: meeting.id
                    )
                },
                onHide: {
                    showBestTranscriptProgress = false
                }
            )
        }
        .alert(
            "Couldn’t save the best transcript",
            isPresented: Binding(
                get: { bestExportError != nil },
                set: { if !$0 { bestExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bestExportError ?? "")
        }
        .alert(
            "Part of the recording is unavailable",
            isPresented: Binding(
                get: { partialAudioWarning != nil },
                set: {
                    if !$0 {
                        partialAudioWarning = nil
                        pendingPartialExportRequest = nil
                    }
                }
            )
        ) {
            Button("Try Again") {
                guard let request = pendingPartialExportRequest else { return }
                let forceReprocess = pendingPartialForceReprocess
                partialAudioWarning = nil
                pendingPartialExportRequest = nil
                submitBestTranscript(
                    request,
                    forceReprocess: forceReprocess
                )
            }
            Button("Export Available Track") {
                guard var request = pendingPartialExportRequest else { return }
                let forceReprocess = pendingPartialForceReprocess
                request.allowPartialDamagedTracks = true
                partialAudioWarning = nil
                pendingPartialExportRequest = nil
                submitBestTranscript(
                    request,
                    forceReprocess: forceReprocess
                )
            }
            Button("Cancel", role: .cancel) {
                partialAudioWarning = nil
                pendingPartialExportRequest = nil
            }
        } message: {
            Text(
                "\(partialAudioWarning ?? "") You can retry, or knowingly export only the track that is still readable."
            )
        }
    }

    // MARK: - Header

    private var meetingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editingTitle {
                TextField("Meeting title", text: $titleText)
                    .font(.title)
                    .textFieldStyle(.plain)
                    .focused($titleFieldFocused)
                    .accessibilityLabel("Meeting title")
                    .onSubmit(commitTitleEdit)
                    .onKeyPress(.escape) {
                        cancelTitleEdit()
                        return .handled
                    }
            } else {
                HStack(spacing: 8) {
                    Text(meeting.title)
                        .font(Theme.Typography.title(26))
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)

                    Button {
                        beginTitleEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.ink3)
                    .help("Rename meeting")
                    .accessibilityLabel("Rename meeting")
                }
            }

            HStack(spacing: 12) {
                Label(meeting.date.formatted(date: .long, time: .shortened), systemImage: "calendar")
                Label(meeting.formattedDuration, systemImage: "clock")
                if meeting.speakerCount > 0 {
                    Label("\(meeting.speakerCount) speakers", systemImage: "person.2")
                }
                statusBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // What the AI cost for this call (estimated); old meetings have no data.
            if let usage = meeting.aiUsage {
                aiCostRow(usage)
            }

            // Name the other party so the transcript/report read naturally.
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                TextField("Name the other speaker (e.g. Sam)", text: $themNameText) {
                    meeting.themName = themNameText.trimmingCharacters(in: .whitespaces).nilIfEmpty
                }
                .textFieldStyle(.plain)
                .frame(maxWidth: 240)
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One-line estimated AI cost; click for the per-line breakdown.
    private func aiCostRow(_ usage: AIUsage) -> some View {
        Button {
            showCostBreakdown.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                Text("AI cost ~\(AIUsage.formatUSD(usage.totalUSD))")
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.Colors.ink)
                Text(usage.costBreakdown()
                    .map { "\($0.label) \(AIUsage.formatUSD($0.usd))" }
                    .joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCostBreakdown, arrowEdge: .bottom) {
            costBreakdownPopover(usage)
        }
    }

    private func costBreakdownPopover(_ usage: AIUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI cost breakdown")
                .font(Theme.Typography.sectionLabel)
            ForEach(Array(usage.costBreakdown().enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(Theme.Typography.secondary)
                        Text(item.detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 24)
                    Text(AIUsage.formatUSD(item.usd))
                        .font(Theme.Typography.secondary)
                        .monospacedDigit()
                }
            }
            Divider()
            HStack {
                Text("Total").font(Theme.Typography.secondary.weight(.semibold))
                Spacer()
                Text(AIUsage.formatUSD(usage.totalUSD))
                    .font(Theme.Typography.secondary.weight(.semibold))
                    .monospacedDigit()
            }
            Text("Estimated from provider list prices — not a bill.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func beginTitleEdit() {
        titleText = meeting.title
        editingTitle = true
        Task { @MainActor in
            titleFieldFocused = true
        }
    }

    private func commitTitleEdit() {
        let committed = MeetingPresentationPolicy.committedTitle(
            draft: titleText,
            previousTitle: meeting.title
        )
        if committed != meeting.title {
            if let onRename {
                onRename(committed)
            } else {
                _ = meeting.applyManualTitle(committed)
            }
        }
        titleText = meeting.title
        editingTitle = false
        titleFieldFocused = false
    }

    private func cancelTitleEdit() {
        titleText = meeting.title
        editingTitle = false
        titleFieldFocused = false
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.status {
        case .processing:
            Label("Processing", systemImage: "gearshape.2")
                .foregroundStyle(.orange)
        case .failed:
            Label("Failed", systemImage: "xmark.circle")
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    // MARK: - Audio Player

    private var hasPlayableAudio: Bool {
        audioPlayer != nil || micPlayer != nil
    }

    private var playbackDuration: TimeInterval {
        max(audioPlayer?.duration ?? 0, micPlayer?.duration ?? 0)
    }

    private var audioPlayerBar: some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")

            Slider(
                value: Binding(
                    get: { min(playbackTime, playbackDuration) },
                    set: { seekTo($0) }
                ),
                in: 0...max(playbackDuration, 0.01)
            )
            .accessibilityLabel("Recording position")
            .accessibilityValue(formatTime(playbackTime))

            // Time display
            Text("\(formatTime(playbackTime)) / \(formatTime(playbackDuration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 100)

            // Speed selector
            Picker("Speed", selection: $playbackSpeed) {
                Text("0.5x").tag(Float(0.5))
                Text("1x").tag(Float(1.0))
                Text("1.5x").tag(Float(1.5))
                Text("2x").tag(Float(2.0))
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: playbackSpeed) { _, newValue in
                audioPlayer?.rate = newValue
                micPlayer?.rate = newValue
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Transcript-first content

    private var transcriptPresentation: MeetingTranscriptPresentation {
        MeetingPresentationPolicy.transcriptPresentation(
            status: meeting.status,
            segmentCount: meeting.segments.count,
            errorMessage: meeting.errorMessage
        )
    }

    private var transcriptFirstContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Summary", systemImage: "text.alignleft")
                            .font(Theme.Typography.sectionLabel)
                            .foregroundStyle(Theme.Colors.ink)
                        Text(summary)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.ink2)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Theme.Colors.panel,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }

                if MeetingPresentationPolicy.shouldShowNotes(meeting.notes) || notesExpanded {
                    @Bindable var meeting = meeting
                    DisclosureGroup(isExpanded: $notesExpanded) {
                        TextEditor(text: $meeting.notes)
                            .font(Theme.Typography.body)
                            .scrollContentBackground(.hidden)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 84)
                            .padding(.top, 6)
                    } label: {
                        Label("Notes", systemImage: "square.and.pencil")
                            .font(Theme.Typography.sectionLabel)
                    }
                }

                Text("Transcript")
                    .font(Theme.Typography.sectionLabel)
                    .foregroundStyle(Theme.Colors.ink)

                if let message = transcriptPresentation.message {
                    transcriptStatus(message, presentation: transcriptPresentation)
                }

                if transcriptPresentation.showsTranscript {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(meeting.sortedSegments) { segment in
                            transcriptSegmentControl(segment)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transcriptStatus(
        _ message: String,
        presentation: MeetingTranscriptPresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if presentation.showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: presentation.tone == .error
                    ? "exclamationmark.circle"
                    : "text.bubble")
            }
            Text(message)
                .font(Theme.Typography.secondary)
                .textSelection(.enabled)
        }
        .foregroundStyle(presentation.tone == .error ? Color.red : Theme.Colors.ink2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func transcriptSegmentControl(_ segment: TranscriptSegment) -> some View {
        if hasPlayableAudio {
            TranscriptSegmentRow(
                segment: segment,
                isActive: segment.id == activeSegmentID,
                themName: meeting.themName,
                onSeek: { seekTo(segment.startTime) }
            )
        } else {
            TranscriptSegmentRow(
                segment: segment,
                isActive: segment.id == activeSegmentID,
                themName: meeting.themName
            )
        }
    }

    // MARK: - Audio Playback

    private func prepareMeetingView() {
        stopPlayback()
        audioPlayer = nil
        micPlayer = nil
        playbackTime = 0
        activeSegmentID = nil
        editingTitle = false
        titleFieldFocused = false
        titleText = meeting.title
        themNameText = meeting.themName ?? ""
        notesExpanded = false
        hasCachedBestTranscript = false
        prepareAudioPlayer()

        let meetingID = meeting.id
        Task {
            let hasArtifact = await recordingManager
                .bestTranscriptionCoordinator
                .latestCompletedArtifact(meetingID: meetingID) != nil
            guard meeting.id == meetingID else { return }
            hasCachedBestTranscript = hasArtifact
        }
    }

    private func prepareAudioPlayer() {
        // Two separate tracks were recorded: system audio ("Them") and the mic
        // ("Me"). Load both so playback contains the full conversation, not just
        // the other side.
        if let path = meeting.systemAudioPath.nilIfEmpty,
           FileManager.default.fileExists(atPath: path) {
            audioPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            audioPlayer?.enableRate = true
            audioPlayer?.prepareToPlay()
        }
        if let micPath = meeting.micAudioPath?.nilIfEmpty,
           FileManager.default.fileExists(atPath: micPath) {
            micPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: micPath))
            micPlayer?.enableRate = true
            micPlayer?.prepareToPlay()
        }
    }

    /// Starts both tracks at the same device-clock instant so they stay in sync.
    private func startSynced() {
        audioPlayer?.rate = playbackSpeed
        micPlayer?.rate = playbackSpeed
        let clock = audioPlayer?.deviceCurrentTime ?? micPlayer?.deviceCurrentTime ?? 0
        let startAt = clock + 0.08
        audioPlayer?.play(atTime: startAt)
        micPlayer?.play(atTime: startAt)
    }

    private func togglePlayback() {
        if isPlaying {
            audioPlayer?.pause()
            micPlayer?.pause()
            playbackTimer?.invalidate()
        } else {
            startSynced()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                // AVAudioPlayer goes silent at end-of-track without a callback
                // here — detect it, or the timer runs forever and the button
                // stays stuck on pause.
                if audioPlayer?.isPlaying != true && micPlayer?.isPlaying != true {
                    stopPlayback()
                    playbackTime = 0
                    updateActiveSegment()
                    return
                }
                playbackTime = audioPlayer?.currentTime ?? micPlayer?.currentTime ?? 0
                updateActiveSegment()
            }
        }
        isPlaying.toggle()
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        micPlayer?.stop()
        playbackTimer?.invalidate()
        isPlaying = false
    }

    private func seekTo(_ time: TimeInterval) {
        let wasPlaying = isPlaying
        audioPlayer?.pause()
        micPlayer?.pause()
        audioPlayer?.currentTime = min(time, audioPlayer?.duration ?? time)
        micPlayer?.currentTime = min(time, micPlayer?.duration ?? time)
        // Clamp the UI too: an insight callTime past the audio's end must not
        // draw a >100% progress bar.
        let duration = max(audioPlayer?.duration ?? 0, micPlayer?.duration ?? 0)
        playbackTime = duration > 0 ? min(time, duration) : time
        updateActiveSegment()
        if wasPlaying { startSynced() }
    }

    private func updateActiveSegment() {
        activeSegmentID = meeting.sortedSegments.last { $0.startTime <= playbackTime }?.id
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Export

    private var bestProgress: BestTranscriptionProgress {
        recordingManager.bestTranscriptionCoordinator.progress(for: meeting.id)
    }

    private var canExportBestTranscript: Bool {
        guard meeting.status != .recording else { return false }
        return hasCachedBestTranscript
            || !meeting.systemAudioPath.isEmpty
            || meeting.micAudioPath?.isEmpty == false
    }

    private func exportTXT() {
        let content = ExportService.exportToTXT(meeting: meeting)
        let filename = meeting.title.replacingOccurrences(of: " ", with: "_")
        if let url = try? ExportService.save(content: content, filename: filename, extension: "txt") {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    private func exportSRT() {
        let content = ExportService.exportToSRT(meeting: meeting)
        let filename = meeting.title.replacingOccurrences(of: " ", with: "_")
        if let url = try? ExportService.save(content: content, filename: filename, extension: "srt") {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    private func startBestTranscriptExport(forceReprocess: Bool) {
        let request = BestTranscriptionRequest(
            meetingID: meeting.id,
            title: meeting.title,
            date: meeting.date,
            duration: meeting.duration,
            systemAudioURL: meeting.systemAudioPath.nilIfEmpty.map {
                URL(fileURLWithPath: $0)
            },
            micAudioURL: meeting.micAudioPath?.nilIfEmpty.map {
                URL(fileURLWithPath: $0)
            },
            vocabulary: UserDefaults.standard.string(
                forKey: "customVocabulary"
            ) ?? "",
            timeline: AudioTimelineStore.load(meetingID: meeting.id)
        )
        submitBestTranscript(
            request,
            forceReprocess: forceReprocess
        )
    }

    private func submitBestTranscript(
        _ request: BestTranscriptionRequest,
        forceReprocess: Bool
    ) {
        showBestTranscriptProgress = true
        let completion: (Result<BestTranscriptArtifact, Error>) -> Void = {
            result in
            switch result {
            case .success(let artifact):
                hasCachedBestTranscript = true
                saveBestTranscript(artifact)
            case .failure(let error):
                if case .damagedAudioAvailable(let warnings) =
                    error as? BestTranscriptionError {
                    showBestTranscriptProgress = false
                    partialAudioWarning = warnings.joined(separator: " ")
                    pendingPartialExportRequest = request
                    pendingPartialForceReprocess = forceReprocess
                } else if error as? BestTranscriptionError != .cancelled {
                    bestExportError = error.localizedDescription
                }
            }
        }
        if forceReprocess {
            recordingManager.bestTranscriptionCoordinator.reprocess(
                request,
                completion: completion
            )
        } else {
            recordingManager.bestTranscriptionCoordinator.startOrResume(
                request,
                completion: completion
            )
        }
    }

    private func saveBestTranscript(_ artifact: BestTranscriptArtifact) {
        let content = ExportService.exportBestTranscriptTXT(
            title: meeting.title,
            date: meeting.date,
            duration: meeting.duration,
            artifact: artifact
        )
        let filename = "\(meeting.title) — Best Whisper Transcript"
        do {
            let url = try ExportService.save(
                content: content,
                filename: filename,
                extension: "txt"
            )
            showBestTranscriptProgress = false
            NSWorkspace.shared.selectFile(
                url.path,
                inFileViewerRootedAtPath: url.deletingLastPathComponent().path
            )
        } catch {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "\(filename).txt"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else {
                showBestTranscriptProgress = false
                return
            }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                showBestTranscriptProgress = false
                NSWorkspace.shared.selectFile(
                    url.path,
                    inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                )
            } catch {
                bestExportError = "The transcript is ready and cached, but the TXT file could not be written: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Transcript Segment Row

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    var themName: String? = nil
    var onSeek: (() -> Void)? = nil

    private static let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint
    ]

    /// Resolved speaker name: "Me" stays "Me"; everyone else shows the user's
    /// assigned name (e.g. "Sam") if set, otherwise the raw label.
    private var displayLabel: String? {
        guard let label = segment.speakerLabel else { return nil }
        if label == "Me" { return "Me" }
        return themName ?? label
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            if let onSeek {
                Button(action: onSeek) {
                    timestampLabel
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Play from this moment")
                .accessibilityLabel("Play from \(segment.formattedTimestamp)")
            } else {
                timestampLabel
            }

            // Speaker label
            if let speaker = displayLabel {
                Text(speaker)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(speakerColor(for: speaker))
                    .frame(width: 70, alignment: .leading)
            }

            // Text
            Text(segment.text)
                .font(Theme.Typography.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isActive ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    private var timestampLabel: some View {
        Text(segment.formattedTimestamp)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 40, alignment: .trailing)
    }

    private func speakerColor(for label: String) -> Color {
        Self.speakerColors[label.stableHash % Self.speakerColors.count]
    }
}

// MARK: - String Extension

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    /// Deterministic non-negative hash. `hashValue` is per-process seeded, so
    /// hash-derived UI colors would reshuffle on every launch (and abs(Int.min)
    /// traps). Used for stable speaker/sidebar colors.
    var stableHash: Int {
        unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }
}
