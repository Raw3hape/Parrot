import SwiftUI
import SwiftData

@MainActor
final class ParrotRuntime {
    static let shared = ParrotRuntime()

    let recordingManager: RecordingManager
    let modelContainer: ModelContainer

    private init() {
        recordingManager = RecordingManager()
        let schema = Schema([
            Meeting.self,
            TranscriptSegment.self,
            CallInsight.self,
            CallProfile.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}

@MainActor
enum ParrotStartupPreparation {
    static func run(
        recordingManager: RecordingManager,
        modelContainer: ModelContainer
    ) async {
        await recordingManager.prepareApplication(modelContext: modelContainer.mainContext)
    }
}

@MainActor
final class ParrotApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var recordingManager: RecordingManager?
    private var terminationPending = false
    private var hasConfiguredApplication = false
    private var startupPreparationTask: Task<Void, Never>?
    private let menuBarController = MenuBarController()
    private let launchBootstrap: ((ParrotApplicationDelegate) -> Void)?

    override init() {
        launchBootstrap = nil
        super.init()
    }

    init(launchBootstrap: @escaping (ParrotApplicationDelegate) -> Void) {
        self.launchBootstrap = launchBootstrap
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        ApplicationPresentationController.applyDockVisibility(
            showInDock: DockVisibilityPreference.isEnabled()
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let launchBootstrap {
            launchBootstrap(self)
            return
        }
        guard ParrotInstanceCoordinator.enforceSingleInstalledInstance() else {
            return
        }

        // A login-item launch may never construct or reveal the main window.
        // Bootstrap the menu bar and lightweight app state directly from the
        // application lifecycle so the top-right icon is always functional.
        let runtime = ParrotRuntime.shared
        configure(
            recordingManager: runtime.recordingManager,
            callDetection: runtime.recordingManager.callDetection,
            modelContainer: runtime.modelContainer
        )
        // SwiftUI may reset activation policy while building its scenes.
        ApplicationPresentationController.applyDockVisibility(
            showInDock: DockVisibilityPreference.isEnabled()
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recordingManager else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor [weak self] in
            await recordingManager.prepareForTermination()
            self?.terminationPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        recordingManager?.callDetection.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        menuBarController.showMainWindow()
        return true
    }

    func configure(
        recordingManager: RecordingManager,
        callDetection: CallDetectionCoordinator,
        modelContainer: ModelContainer
    ) {
        guard !hasConfiguredApplication else { return }
        hasConfiguredApplication = true
        self.recordingManager = recordingManager
        LaunchAtLoginController.shared.synchronizeAtStartup()
        menuBarController.configure(
            recordingManager: recordingManager,
            callDetection: callDetection,
            modelContainer: modelContainer
        )
        let shouldHideInitialWindow = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        // A hidden SwiftUI window cancels its view task. Prepare the lightweight
        // application services from the delegate first, so menu-bar-only startup
        // still restores recording state and queues local meeting details. This
        // does not load either speech model; those remain on-demand.
        startupPreparationTask = Task { @MainActor [weak self, weak recordingManager] in
            guard let self, let recordingManager else { return }
            await ParrotStartupPreparation.run(
                recordingManager: recordingManager,
                modelContainer: modelContainer
            )
            guard !Task.isCancelled else { return }
            if shouldHideInitialWindow {
                self.menuBarController.hideMainWindow()
            }
            self.startupPreparationTask = nil
        }
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
        if let i = args.firstIndex(of: "--best-transcription-test"),
           i + 1 < args.count {
            let workerCount = i + 2 < args.count ? Int(args[i + 2]) : nil
            BestTranscriptionIntegrationTest.run(
                audioPath: args[i + 1],
                workerCount: workerCount,
                exportPath: i + 3 < args.count ? args[i + 3] : nil
            )
            return
        }
        if let i = args.firstIndex(of: "--final-transcription-test"), i + 3 < args.count {
            let workers = i + 4 < args.count ? Int(args[i + 4]) ?? 1 : 1
            FinalTranscriptionIntegrationTest.run(
                audioPath: args[i + 1], engine: args[i + 2],
                modelRoot: args[i + 3], workers: workers
            )
            return
        }
        if let i = args.firstIndex(of: "--promote-final-model"), i + 3 < args.count {
            FinalModelPromotion.run(engine: args[i + 1], sourceRoot: args[i + 2], evidenceSHA256: args[i + 3])
            return
        }
        if args.contains("--capture-test") {
            CaptureIntegrationTest.run()
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
    @State private var recordingManager: RecordingManager
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    let sharedModelContainer: ModelContainer

    init() {
        let runtime = ParrotRuntime.shared
        _recordingManager = State(initialValue: runtime.recordingManager)
        sharedModelContainer = runtime.modelContainer
    }

    var body: some Scene {
        Window("Parrot", id: "main") {
            ContentView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
                .fontDesign(.default)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environment(recordingManager)
                        .interactiveDismissDisabled()
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
                .fontDesign(.default)
        }
        .modelContainer(sharedModelContainer)
    }
}
