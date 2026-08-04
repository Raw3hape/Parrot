import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var modelContext
    @State private var selectedMeeting: Meeting?
    @State private var showDashboard = true
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var hasPreparedApplication = false
    @State private var prefersLiveRecording = false

    var body: some View {
        VStack(spacing: 0) {
            if RecordingNavigationPolicy.presentation(
                isRecording: recordingManager.isRecording,
                prefersLiveRecording: prefersLiveRecording
            ) == .selectedDestinationWithRecordingBanner {
                ActiveRecordingBanner(
                    returnToRecording: { prefersLiveRecording = true }
                )
            }

            NavigationSplitView {
                SidebarView(
                    selectedMeeting: $selectedMeeting,
                    showDashboard: $showDashboard,
                    showSettings: $showSettings,
                    searchText: $searchText,
                    prefersLiveRecording: $prefersLiveRecording
                )
                .navigationSplitViewColumnWidth(min: 215, ideal: 236, max: 320)
            } detail: {
                if RecordingNavigationPolicy.presentation(
                    isRecording: recordingManager.isRecording,
                    prefersLiveRecording: prefersLiveRecording
                ) == .liveRecording {
                    LiveRecordingView()
                } else {
                    selectedDestination
                }
            }
        }
        .task {
            guard !hasPreparedApplication else { return }
            hasPreparedApplication = true
            await recordingManager.prepareApplication(modelContext: modelContext)
        }
        .onChange(of: recordingManager.isRecording) { _, isRecording in
            if isRecording { prefersLiveRecording = true }
        }
    }

    @ViewBuilder
    private var selectedDestination: some View {
        if showSettings {
            settingsPane
        } else if showDashboard {
            DashboardView(
                selectedMeeting: $selectedMeeting,
                showDashboard: $showDashboard
            )
        } else if let meeting = selectedMeeting {
            // .id forces a fresh view identity per meeting: @State (title/name
            // drafts, audio players, tab) must not leak from one meeting to the
            // next, and onAppear/onDisappear must re-fire to stop playback.
            MeetingDetailView(
                meeting: meeting,
                onDelete: {
                    selectedMeeting = nil
                    showDashboard = true
                    Task { await recordingManager.delete(meeting) }
                },
                onRename: { draft in
                    recordingManager.rename(meeting, to: draft)
                }
            )
            .id(meeting.id)
        } else {
            EmptyStateView()
        }
    }

    /// Settings in the main pane — the old sheet was a cramped 520pt popup.
    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Theme.Typography.title(24))
                .foregroundStyle(Theme.Colors.ink)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)

            // Full bleed — no width cap, no centering. A wider window means a
            // wider editor, period. Base font raised to the legend scale;
            // controls without an explicit font inherit it.
            SettingsView(isEmbedded: true)
                .font(Theme.Typography.body)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.canvas)
    }
}

private struct ActiveRecordingBanner: View {
    @Environment(RecordingManager.self) private var recordingManager
    let returnToRecording: () -> Void

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("Recording · \(formattedElapsed)")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                Text("Recording continues while you browse Parrot")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.trailing, 196)
            .frame(width: geometry.size.width, height: 44, alignment: .leading)
            .overlay(alignment: .trailing) {
                HStack(spacing: 8) {
                    Button("Back", action: returnToRecording)
                        .buttonStyle(.borderless)
                    Button(recordingManager.isStopping ? "Finalizing…" : "Stop") {
                        Task { await recordingManager.stopRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(recordingManager.isStopping)
                }
                .padding(.trailing, 16)
                .padding(.leading, 10)
                .frame(height: 44)
                .background(Theme.Colors.panel)
            }
            .clipped()
        }
        .frame(height: 44)
        .background(Theme.Colors.panel)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording continues")
    }

    private var formattedElapsed: String {
        let total = max(0, Int(recordingManager.elapsedTime))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a meeting or start recording")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
