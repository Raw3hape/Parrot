import AppKit
import Observation
import SwiftData
import SwiftUI

@MainActor
protocol MainWindowPresenting: AnyObject {
    var isReleasedWhenClosed: Bool { get set }
    func orderFrontRegardless()
    func makeKeyAndOrderFront(_ sender: Any?)
}

extension NSWindow: MainWindowPresenting {}

/// Keeps the window-opening decision testable and, importantly, does not rely
/// on the private `showMainWindow:` responder-chain selector. A SwiftUI scene
/// is not guaranteed to have constructed a window for a menu-bar-only launch.
@MainActor
final class MainWindowPresentationCoordinator {
    typealias WindowProvider = () -> MainWindowPresenting?

    private let existingWindow: WindowProvider
    private let createWindow: WindowProvider
    private let activateApplication: () -> Void

    init(
        existingWindow: @escaping WindowProvider,
        createWindow: @escaping WindowProvider,
        activateApplication: @escaping () -> Void
    ) {
        self.existingWindow = existingWindow
        self.createWindow = createWindow
        self.activateApplication = activateApplication
    }

    @discardableResult
    func present() -> Bool {
        guard let window = existingWindow() ?? createWindow() else {
            return false
        }
        window.isReleasedWhenClosed = false
        activateApplication()
        // Accessory apps can be active without putting a normal window above
        // the current app. Ordering first makes the menu-bar flow deterministic.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.squareLength
    )
    private let popover = NSPopover()
    private weak var recordingManager: RecordingManager?
    private weak var callDetection: CallDetectionCoordinator?
    private var modelContainer: ModelContainer?
    private var fallbackMainWindowController: NSWindowController?
    private var isConfigured = false
    private var openedForSuggestion = false

    override init() {
        super.init()
        let button = statusItem.button
        button?.target = self
        button?.action = #selector(togglePopover)
        button?.toolTip = "Parrot"
        popover.behavior = .applicationDefined
        popover.animates = true
        updateStatusIcon(isRecording: false)
    }

    func configure(
        recordingManager: RecordingManager,
        callDetection: CallDetectionCoordinator,
        modelContainer: ModelContainer
    ) {
        guard !isConfigured else { return }
        isConfigured = true
        self.recordingManager = recordingManager
        self.callDetection = callDetection
        self.modelContainer = modelContainer

        let root = MenuBarPopoverView(
            callDetection: callDetection,
            openMainWindow: { [weak self] in
                self?.showMainWindow()
            },
            closePopover: { [weak self] in
                self?.closePopover()
            }
        )
        .environment(recordingManager)
        .environment(recordingManager.profileStore)
        .fontDesign(.default)
        .modelContainer(modelContainer)
        popover.contentViewController = NSHostingController(rootView: root)
        popover.contentSize = NSSize(width: 320, height: 210)

        callDetection.onSuggestionChanged = { [weak self] candidate in
            guard let self else { return }
            if candidate != nil {
                self.openedForSuggestion = true
                self.showPopover()
            } else if self.openedForSuggestion {
                self.closePopover()
            }
        }
        callDetection.start()
        observeRecordingState()

        for window in mainWindows() {
            window.isReleasedWhenClosed = false
        }
    }

    @objc
    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openedForSuggestion = callDetection?.suggestion != nil
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        openedForSuggestion = false
    }

    func showMainWindow() {
        closePopover()
        // Let NSPopover finish its close event before ordering the main window.
        // Otherwise AppKit can immediately resign/order out the window we just
        // showed, which makes the button appear to do nothing.
        DispatchQueue.main.async { [weak self] in
            self?.presentMainWindow()
        }
    }

    func hideMainWindow() {
        for window in mainWindows() {
            window.orderOut(nil)
        }
    }

    private func mainWindow() -> NSWindow? {
        mainWindows().first
    }

    private func presentMainWindow() {
        let presenter = MainWindowPresentationCoordinator(
            existingWindow: { [weak self] in self?.mainWindow() },
            createWindow: { [weak self] in self?.makeFallbackMainWindow() },
            activateApplication: {
                NSApp.activate(ignoringOtherApps: true)
            }
        )
        presenter.present()
    }

    private func makeFallbackMainWindow() -> NSWindow? {
        if let window = fallbackMainWindowController?.window {
            return window
        }
        guard let recordingManager, let modelContainer else { return nil }

        let rootView = ContentView()
            .environment(recordingManager)
            .environment(recordingManager.profileStore)
            .fontDesign(.default)
            .modelContainer(modelContainer)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Parrot"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ParrotMainWindow")
        window.center()

        let controller = NSWindowController(window: window)
        fallbackMainWindowController = controller
        return window
    }

    private func mainWindows() -> [NSWindow] {
        NSApp.windows.filter {
            $0.title == "Parrot" && !($0 is NSPanel)
        }
    }

    private func observeRecordingState() {
        guard let recordingManager else { return }
        withObservationTracking {
            _ = recordingManager.isRecording
            _ = recordingManager.isStarting
            _ = recordingManager.isStopping
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let manager = self.recordingManager else {
                    return
                }
                self.updateStatusIcon(isRecording: manager.isRecording)
                self.callDetection?.setRecordingActive(
                    manager.isStarting
                        || manager.isRecording
                        || manager.isStopping
                )
                self.observeRecordingState()
            }
        }
    }

    private func updateStatusIcon(isRecording: Bool) {
        guard let button = statusItem.button else { return }
        if isRecording {
            let image = NSImage(
                systemSymbolName: "waveform.circle.fill",
                accessibilityDescription: "Parrot is recording"
            )
            image?.isTemplate = true
            button.image = image
        } else {
            let image = NSImage(named: "ParrotMenuBarIcon")
            image?.isTemplate = true
            button.image = image
            button.imageScaling = .scaleProportionallyDown
        }
    }
}
