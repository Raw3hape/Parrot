import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var modelContext

    let callDetection: CallDetectionCoordinator
    let openMainWindow: () -> Void
    let closePopover: () -> Void

    var body: some View {
        switch MenuBarPresentationPolicy.presentation(
            isRecording: recordingManager.isRecording,
            isStarting: recordingManager.isStarting,
            suggestion: callDetection.suggestion
        ) {
        case .suggestion:
            suggestionView
        case .starting:
            startingView
        case .manual, .recording:
            MenuBarView(
                openMainWindow: openMainWindow,
                closePopover: closePopover
            )
        }
    }

    private var suggestionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Record this call?")
                        .font(.headline)
                    Text(callDetection.suggestion?.promptDetail ?? "Call detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                Button {
                    callDetection.dismissSuggestion()
                    closePopover()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Don't ask again for this call")
            }

            HStack {
                Label("On-device · Private", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Recording") {
                    callDetection.acceptSuggestion()
                    closePopover()
                    Task {
                        await startRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(
                    recordingManager.isStarting
                        || recordingManager.isRecording
                        || recordingManager.isStopping
                )
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var startingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing local transcription…")
                .font(.headline)
            Text("Audio recording starts after the local model and permissions are ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .frame(width: 300)
    }

    @MainActor
    private func startRecording() async {
        do {
            try await recordingManager.preflightPermissionsAndStart(
                modelContext: modelContext
            )
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't start recording"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
