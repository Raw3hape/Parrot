import SwiftUI

struct MenuBarView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var modelContext

    let openMainWindow: () -> Void
    let closePopover: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if recordingManager.isRecording {
                // Recording state
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.headline)
                    Spacer()
                    Text(recordingManager.formattedElapsedTime)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Button(recordingManager.isStopping ? "Finalizing…" : "Stop Recording") {
                    closePopover()
                    Task { await recordingManager.stopRecording() }
                }
                .disabled(recordingManager.isStopping)
                .keyboardShortcut("s")
            } else {
                // Idle state
                Text("Parrot")
                    .font(.headline)

                Text(recordingManager.transcriptionEngine.isReady ? "Ready to record" : "Model loads when recording starts")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(profileStore.activeProfile?.name ?? "Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Start Recording") {
                    closePopover()
                    Task {
                        do {
                            // Same preflight as the dashboard button — without it
                            // this path silently failed when Screen Recording
                            // permission was missing.
                            try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
                        } catch {
                            NSApp.activate(ignoringOtherApps: true)
                            let alert = NSAlert()
                            alert.messageText = "Couldn't start recording"
                            alert.informativeText = error.localizedDescription
                            alert.runModal()
                        }
                    }
                }
                .disabled(
                    recordingManager.isStarting
                        || recordingManager.isRecording
                        || recordingManager.isStopping
                )
                .keyboardShortcut("r")
            }

            Divider()

            Button("Open Parrot") {
                openMainWindow()
            }

            Button("Quit") {
                closePopover()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 240)
    }
}
