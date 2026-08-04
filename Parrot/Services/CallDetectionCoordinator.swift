import Foundation
import Observation

@MainActor
@Observable
final class CallDetectionCoordinator {
    var onSuggestionChanged: ((CallCandidate?) -> Void)?

    private(set) var suggestion: CallCandidate?
    private(set) var isEnabled: Bool
    private(set) var isRunning = false

    private let monitor: AudioProcessMonitoring
    private let windowProvider: CallWindowProviding
    private let classifier: CallCandidateClassifier
    private var stateMachine: CallSuggestionStateMachine
    private var lastActivities: [AudioProcessActivity] = []
    private var currentCandidate: CallCandidate?
    private var isRecording = false
    private var evaluationTask: Task<Void, Never>?

    init(
        monitor: AudioProcessMonitoring,
        windowProvider: CallWindowProviding,
        classifier: CallCandidateClassifier = CallCandidateClassifier(),
        debounceInterval: TimeInterval = 4,
        idleResetInterval: TimeInterval = 12,
        isEnabled: Bool = true
    ) {
        self.monitor = monitor
        self.windowProvider = windowProvider
        self.classifier = classifier
        self.stateMachine = CallSuggestionStateMachine(
            debounceInterval: debounceInterval,
            idleResetInterval: idleResetInterval
        )
        self.isEnabled = isEnabled
    }

    convenience init(
        debounceInterval: TimeInterval = 4,
        idleResetInterval: TimeInterval = 12,
        isEnabled: Bool = true
    ) {
        self.init(
            monitor: CoreAudioProcessMonitor(),
            windowProvider: CoreGraphicsCallWindowProvider(),
            debounceInterval: debounceInterval,
            idleResetInterval: idleResetInterval,
            isEnabled: isEnabled
        )
    }

    var suppressedSessionKey: String? {
        stateMachine.suppressedSessionKey
    }

    func start() {
        guard isEnabled, !isRunning else { return }
        isRunning = true
        monitor.onActivitiesChanged = { [weak self] activities in
            self?.receive(activities)
        }
        monitor.start()
    }

    func stop() {
        evaluationTask?.cancel()
        evaluationTask = nil
        monitor.stop()
        monitor.onActivitiesChanged = nil
        isRunning = false
        lastActivities = []
        currentCandidate = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
            stateMachine.reset()
            publishIfChanged(nil)
        }
    }

    func setRecordingActive(_ active: Bool) {
        guard isRecording != active else { return }
        isRecording = active
        evaluate(at: .now, refreshWindows: false)
    }

    func dismissSuggestion() {
        stateMachine.dismiss(now: .now)
        syncPublishedSuggestion()
        scheduleNextEvaluation()
    }

    func acceptSuggestion() {
        stateMachine.accept(now: .now)
        syncPublishedSuggestion()
        scheduleNextEvaluation()
    }

    private func receive(_ activities: [AudioProcessActivity]) {
        guard isEnabled, isRunning else { return }
        lastActivities = activities
        evaluate(at: .now, refreshWindows: true)
    }

    private func evaluate(
        at date: Date,
        refreshWindows: Bool
    ) {
        let hasActiveAudio = lastActivities.contains {
            $0.isInputActive || $0.isOutputActive
        }
        let windows = refreshWindows && hasActiveAudio
            ? windowProvider.currentWindows()
            : []
        if refreshWindows || !hasActiveAudio {
            currentCandidate = classifier.bestCandidate(
                activities: lastActivities,
                windows: windows
            )
        }
        stateMachine.update(
            candidate: currentCandidate,
            now: date,
            isRecording: isRecording
        )
        syncPublishedSuggestion()
        scheduleNextEvaluation()
    }

    private func syncPublishedSuggestion() {
        publishIfChanged(stateMachine.suggestion)
    }

    private func publishIfChanged(_ candidate: CallCandidate?) {
        guard suggestion != candidate else { return }
        suggestion = candidate
        onSuggestionChanged?(candidate)
    }

    private func scheduleNextEvaluation() {
        evaluationTask?.cancel()
        evaluationTask = nil
        guard let transitionDate = stateMachine.nextTransitionDate else {
            return
        }
        let delay = max(0, transitionDate.timeIntervalSinceNow)
        evaluationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.evaluate(at: .now, refreshWindows: true)
        }
    }
}
