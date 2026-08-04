import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selectedMeeting: Meeting?
    @Binding var showDashboard: Bool
    /// Settings render in the main detail pane (the old sheet was a cramped
    /// 520pt popup that made the Profiles editor unusable).
    @Binding var showSettings: Bool
    @Binding var searchText: String
    @Binding var prefersLiveRecording: Bool

    @Environment(RecordingManager.self) private var recordingManager
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @State private var deleteTarget: Meeting?
    @State private var pendingDeletionIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.ink3)
                TextField("Search meetings", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // Primary nav
            VStack(spacing: 2) {
                NavRow(title: "Dashboard", icon: "house", selected: showDashboard && !showSettings) {
                    showDashboard = true
                    selectedMeeting = nil
                    showSettings = false
                    prefersLiveRecording = false
                }
                if let recordingSessionPhase {
                    ActiveRecordingNavRow(
                        phase: recordingSessionPhase,
                        elapsedTime: recordingManager.formattedElapsedTime,
                        selected: prefersLiveRecording
                    ) {
                        showDashboard = true
                        selectedMeeting = nil
                        showSettings = false
                        prefersLiveRecording = true
                    }
                } else {
                    NavRow(title: "New recording", icon: "mic.circle", selected: false) {
                        showDashboard = true
                        selectedMeeting = nil
                        showSettings = false
                        prefersLiveRecording = false
                    }
                }
            }
            .padding(.horizontal, 8)

            // Meetings, grouped by day
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    Text("Meetings")
                        .font(Theme.Typography.cap)
                        .foregroundStyle(Theme.Colors.ink3)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 2)

                    if visibleMeetings.isEmpty {
                        Text(hasSearchQuery ? "No matching meetings" : "No meetings yet")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 12)
                            .padding(.top, 24)
                    } else {
                        ForEach(orderedGroups, id: \.0) { key, group in
                            Text(key)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.ink3)
                                .padding(.horizontal, 10)
                                .padding(.top, 9)
                                .padding(.bottom, 2)
                            ForEach(group) { meeting in
                                // `isDeleted` is SwiftData lifecycle metadata and
                                // remains safe to read after invalidation. Never
                                // fault persisted fields for an outgoing row.
                                if !meeting.isDeleted {
                                    let row = MeetingRowSnapshot(meeting: meeting)
                                    Button {
                                        selectedMeeting = meeting
                                        showDashboard = false
                                        showSettings = false
                                        prefersLiveRecording = false
                                    } label: {
                                        MeetingRow(
                                            row: row,
                                            selected: selectedMeeting?.id == row.id
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        "\(row.title), \(row.formattedDuration)"
                                    )
                                    .accessibilityValue(accessibilityStatus(for: row.status))
                                    .contextMenu {
                                        Button("Delete Meeting", role: .destructive) {
                                            deleteTarget = meeting
                                        }
                                        .disabled(recordingManager.isRecording
                                            && recordingManager.currentMeeting?.id == meeting.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            // Footer: in-app Settings + account
            VStack(spacing: 2) {
                Divider().padding(.horizontal, 8).padding(.bottom, 4)
                NavRow(title: "Settings", icon: "gearshape", selected: showSettings) {
                    showSettings = true
                    showDashboard = false
                    selectedMeeting = nil
                    prefersLiveRecording = false
                }
                AccountChip()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Theme.Colors.panel)
        .confirmationDialog(
            "Delete \"\(deleteTarget?.title ?? "meeting")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let meeting = deleteTarget else { return }
                let meetingID = meeting.id
                if selectedMeeting?.id == meetingID {
                    selectedMeeting = nil
                    showDashboard = true
                }
                // Remove every live SwiftUI reference first. The actual
                // SwiftData deletion runs on the next main-actor turn so a
                // cached row/detail cannot fault properties after invalidation.
                pendingDeletionIDs.insert(meetingID)
                deleteTarget = nil
                Task {
                    await Task.yield()
                    await recordingManager.delete(meeting)
                }
            }
        } message: {
            Text("The recording, transcript, and insights will be permanently removed.")
        }
    }

    // Group by day label, ordered most-recent-first (meetings already sorted desc).
    private var orderedGroups: [(String, [Meeting])] {
        let groups = Dictionary(grouping: visibleMeetings) { dateGroupLabel(for: $0.date) }
        return groups.sorted {
            ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast)
        }
    }

    private var visibleMeetings: [Meeting] {
        meetings.filter { meeting in
            !meeting.isDeleted && MeetingPresentationPolicy.shouldPresentMeeting(
                id: meeting.id,
                pendingDeletionIDs: pendingDeletionIDs
            ) && MeetingPresentationPolicy.matchesSearch(
                query: searchText,
                title: meeting.title,
                transcript: meeting.segments.lazy.map(\.text)
            )
        }
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recordingSessionPhase: RecordingSessionPhase? {
        RecordingNavigationPolicy.sessionPhase(
            isStarting: recordingManager.isStarting,
            isRecording: recordingManager.isRecording,
            isStopping: recordingManager.isStopping
        )
    }

    private func accessibilityStatus(for status: MeetingStatus) -> String {
        switch status {
        case .recording: "Recording"
        case .processing: "Processing"
        case .done: "Transcript ready"
        case .failed: "Transcription failed; saved content is preserved"
        }
    }

    private func dateGroupLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now), date > weekAgo {
            return "This Week"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Nav row

private struct ActiveRecordingNavRow: View {
    let phase: RecordingSessionPhase
    let elapsedTime: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                statusIndicator
                    .frame(width: 16, height: 16)

                Text("Active recording")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)

                Spacer(minLength: 6)

                Text(trailingLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(phase == .recording ? Color.red : Theme.Colors.ink2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                selected ? Theme.Colors.selection : Color.red.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help("Return to the live recording and transcript")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if phase == .starting || phase == .stopping {
            ProgressView()
                .controlSize(.mini)
        } else {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.red.opacity(0.2), lineWidth: 5))
        }
    }

    private var trailingLabel: String {
        switch phase {
        case .starting: "Starting"
        case .recording: elapsedTime
        case .stopping: "Saving"
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .starting: "Recording is starting. Open live recording."
        case .recording: "Active recording, \(elapsedTime). Open live recording."
        case .stopping: "Recording is finalizing. Open live recording."
        }
    }
}

private struct NavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink2)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(selected ? Theme.Colors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meeting row

/// Immutable display data keeps a cached SwiftUI row independent from the
/// lifetime of its SwiftData model. This matters during deletion: SwiftUI may
/// render the outgoing row once after the model context invalidates it.
struct MeetingRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let title: String
    let date: Date
    let formattedDuration: String
    let speakerLabel: String
    let status: MeetingStatus

    init(meeting: Meeting) {
        id = meeting.id
        title = meeting.title
        date = meeting.date
        formattedDuration = meeting.formattedDuration
        speakerLabel = meeting.themName?.nilIfEmpty
            ?? (meeting.speakerCount > 1 ? "\(meeting.speakerCount) people" : "Them")
        status = meeting.status
    }
}

private struct MeetingRow: View {
    let row: MeetingRowSnapshot
    let selected: Bool

    private static let dots: [Color] = [
        Color(lightHex: 0x6A8CAF, darkHex: 0x7FA4C6),
        Color(lightHex: 0xB08A6A, darkHex: 0xC9A380),
        Color(lightHex: 0x7A9A7A, darkHex: 0x93B593),
        Color(lightHex: 0x9A7AA0, darkHex: 0xB694BC),
        Color(lightHex: 0xC4806A, darkHex: 0xD79A85),
    ]

    var body: some View {
        HStack(spacing: 9) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(row.date, style: .time)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.ink3)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(selected ? Theme.Colors.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        "\(row.speakerLabel) · \(row.formattedDuration)"
    }

    @ViewBuilder private var statusDot: some View {
        switch row.status {
        case .recording:
            Circle().fill(.red).frame(width: 7, height: 7)
        case .processing:
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .frame(width: 10, height: 10)
        default:
            Circle()
                .fill(Self.dots[row.id.uuidString.stableHash % Self.dots.count])
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - Account chip

private struct AccountChip: View {
    var body: some View {
        HStack(spacing: 9) {
            Text(initials)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.Colors.accent, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text("On-device · Private")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
    }

    private var name: String {
        NSFullUserName().nilIfEmpty ?? "You"
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "Y"
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        return (first + last).uppercased()
    }
}
