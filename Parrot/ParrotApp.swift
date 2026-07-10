import SwiftUI
import SwiftData

@MainActor
final class ParrotApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var recordingManager: RecordingManager?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recordingManager,
              recordingManager.isStarting || recordingManager.isRecording || recordingManager.isStopping else {
            return .terminateNow
        }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor [weak self] in
            await recordingManager.prepareForTermination()
            self?.terminationPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ParrotMain {
    /// Entry point. `--snapshot <path>` renders the report offscreen to a PNG for
    /// design verification (see SnapshotTool.swift); otherwise the normal app runs.
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { ReportSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--copilot-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { CopilotSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--transcribe-test"), i + 1 < args.count {
            let modelFolder = (i + 2 < args.count) ? args[i + 2] : ""
            TranscribeTest.run(audioPath: args[i + 1], modelFolder: modelFolder)
            return
        }
        if let i = args.firstIndex(of: "--parakeet-test"), i + 1 < args.count {
            ParakeetIntegrationTest.run(audioPath: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--whisper-fallback-test"), i + 1 < args.count {
            WhisperFallbackIntegrationTest.run(audioPath: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--call-pipeline-test"), i + 1 < args.count {
            CallPipelineIntegrationTest.run(audioPath: args[i + 1])
            return
        }
        if args.contains("--profile-test") {
            MainActor.assumeIsolated { ProfileTest.run() }
            return
        }
        PersonalBuildPolicy.apply()
        ParrotApp.main()
    }
}

struct ParrotApp: App {
    @NSApplicationDelegateAdaptor(ParrotApplicationDelegate.self) private var appDelegate
    @State private var recordingManager = RecordingManager()
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
                .onAppear {
                    appDelegate.recordingManager = recordingManager
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environment(recordingManager)
                        .interactiveDismissDisabled()
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 900, height: 600)

        MenuBarExtra {
            MenuBarView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
                .modelContainer(sharedModelContainer)
        } label: {
            Image(systemName: recordingManager.isRecording ? "waveform.circle.fill" : "waveform")
        }

        Settings {
            SettingsView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
        }
        .modelContainer(sharedModelContainer)
    }
}
