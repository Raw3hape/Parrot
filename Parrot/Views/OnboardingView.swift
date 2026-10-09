import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Binding var isPresented: Bool
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: modelStep
                default: welcomeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Step indicators
                HStack(spacing: 6) {
                    ForEach(0..<3) { step in
                        Circle()
                            .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep < 2 {
                    Button("Continue") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Open Parrot. Local models can load now or when recording starts.")
                }
            }
            .padding()
        }
        .frame(width: 500, height: 540)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bird")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("Meet Parrot")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your private, on-device meeting recorder.\nParrot listens, transcribes, and remembers — all locally on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Spacer()
        }
        .padding()
    }

    // MARK: - Step 2: Permissions

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted = false

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Permissions Needed")
                .font(.title)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    description: "Required to capture system audio from meetings. Parrot only records audio — never your screen content.",
                    isGranted: screenGranted,
                    action: {
                        // Single official prompt if never asked; if previously
                        // denied macOS won't re-prompt, so open Settings instead.
                        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
                            screenGranted = true
                        } else {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                )

                PermissionRow(
                    icon: "mic",
                    title: "Microphone",
                    description: "Captures your voice for better speaker identification. Your audio stays on this Mac.",
                    isGranted: micGranted,
                    action: {
                        // Trigger system permission dialog
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Task { @MainActor in
                                micGranted = granted
                                if !granted {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                                }
                            }
                        }
                    }
                )
            }
            .frame(maxWidth: 380)

            Text("All processing happens locally. Nothing leaves your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .onAppear {
            // Check current permission status. CGPreflight is side-effect-free —
            // querying SCShareableContent here triggered the macOS permission
            // prompt the moment the step appeared, before the user hit Grant.
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }

    // MARK: - Step 3: Model Download

    private var modelStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Private Local Models")
                .font(.title)
                .fontWeight(.semibold)

            Text("Parrot uses the fastest accurate stack for Polish, Russian, and English calls. You can load it now or automatically on your first recording.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 8) {
                LocalModelRow(
                    icon: "bolt.fill",
                    title: ParakeetModelService.modelDisplayName,
                    detail: "Primary model — fast multilingual transcription"
                )
                LocalModelRow(
                    icon: "checkmark.shield.fill",
                    title: "Whisper Large V3 Turbo",
                    detail: "Automatic fallback for uncertain phrases"
                )
                LocalModelRow(
                    icon: "waveform.badge.mic",
                    title: "Silero VAD",
                    detail: "Finds natural phrase boundaries during calls"
                )
            }
            .frame(maxWidth: 380)

            // Model loading status
            modelLoadingStatus

            Spacer()
        }
        .padding()
    }

    private func downloadModels() {
        Task {
            await recordingManager.transcriptionEngine.loadModel()
        }
    }

    @ViewBuilder
    private var modelLoadingStatus: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading and loading model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Model ready!", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .error(let msg):
            VStack(spacing: 8) {
                Label(msg, systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                    .font(.caption)
                Button("Retry Local Models") {
                    downloadModels()
                }
                .buttonStyle(.bordered)
            }
        default:
            Button("Download Local Models") {
                downloadModels()
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    var isGranted: Bool = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Local Model Row

struct LocalModelRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
