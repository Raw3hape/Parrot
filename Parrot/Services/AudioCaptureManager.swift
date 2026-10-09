@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreAudio
import Combine
import os

/// Monotonic, value-only admission gate for capture callbacks. A token belongs
/// to exactly one capture session; ending or replacing that session makes every
/// delayed callback carrying the old token harmless.
struct CaptureSessionGate: Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?

    mutating func begin() -> Token {
        generation &+= 1
        // Wrapped zero is still safe: it can only collide after 2^64 sessions,
        // and keeping zero out makes debugger output less ambiguous.
        if generation == 0 { generation = 1 }
        activeGeneration = generation
        return Token(generation: generation)
    }

    func accepts(_ token: Token) -> Bool {
        activeGeneration == token.generation
    }

    mutating func end(_ token: Token) {
        if accepts(token) {
            activeGeneration = nil
        }
    }
}

/// Stable identity carried by the session-owned ScreenCaptureKit output object.
/// ScreenCaptureKit may hand callbacks a different Swift wrapper for the same
/// underlying `SCStream`, so routing must use our capture generation instead of
/// `ObjectIdentifier(stream)`.
struct SystemAudioCallbackRoute: Sendable {
    let token: CaptureSessionGate.Token

    func isAccepted(by gate: CaptureSessionGate) -> Bool {
        gate.accepts(token)
    }
}

/// Captures system audio via ScreenCaptureKit and microphone via AVAudioEngine.
/// Provides mixed PCM audio for transcription and saves separate tracks to disk.
@Observable
final class AudioCaptureManager: NSObject, @unchecked Sendable {
    // Write uncompressed PCM (.caf) via AVAudioFile rather than AAC/.m4a via
    // AVAssetWriter: on recent macOS the AAC encoder fails to initialize
    // (AudioCodecInitialize failed / -12651), producing silent 0-byte files.
    // PCM has no codec to fail. Each file is written only from its own serial
    // queue, off the audio render thread.
    private let systemWriteQueue = DispatchQueue(label: "com.uygar.parrot.audio.system")
    private let micWriteQueue = DispatchQueue(label: "com.uygar.parrot.audio.mic")
    private let systemCaptureQueue = DispatchQueue(
        label: "com.uygar.parrot.capture.system",
        qos: .userInteractive
    )

    /// All objects that may outlive a capture callback are owned by one immutable
    /// session identity. File handles are queue-confined; the remaining mutable
    /// handles are touched only by the async start/stop lifecycle for this session.
    private final class CaptureSession: @unchecked Sendable {
        let token: CaptureSessionGate.Token
        let systemAudioURL: URL
        let micAudioURL: URL
        let echoCanceller: EchoCanceller?
        let startedUptime: TimeInterval
        var timeline: AudioTimelineAccumulator
        var systemStream: SCStream?
        var systemOutput: SystemAudioOutput?
        var audioEngine: AVAudioEngine?
        var audioEngineConfigurationObserver: NSObjectProtocol?
        var microphoneGate = MicrophoneCaptureGenerationGate()
        var microphoneToken: MicrophoneCaptureGenerationGate.Token?
        var audioRoute = DefaultAudioDeviceMonitor.currentSnapshot()
        var microphoneRestartWorkItem: DispatchWorkItem?
        var isRestartingMicrophone = false
        var lastMicrophoneBufferUptime: TimeInterval?
        var microphoneGapPending = false
        var systemCallbackCount = 0
        var systemConversionFailureCount = 0
        var starvationReported = false
        var stopping = false
        var callbackAdmissionOpen = true
        var inFlightCallbacks = 0
        var callbackWaiters: [CheckedContinuation<Void, Never>] = []
        var systemAudioFile: AVAudioFile?
        var micAudioFile: AVAudioFile?
        var lastSystemLevelUptime = -Double.infinity
        var lastMicLevelUptime = -Double.infinity

        init(
            token: CaptureSessionGate.Token,
            systemAudioURL: URL,
            micAudioURL: URL,
            echoCanceller: EchoCanceller?
        ) {
            self.token = token
            self.systemAudioURL = systemAudioURL
            self.micAudioURL = micAudioURL
            self.echoCanceller = echoCanceller
            startedUptime = ProcessInfo.processInfo.systemUptime
            timeline = AudioTimelineAccumulator(capturedAt: .now)
        }
    }

    /// Function values are immutable reference-counted objects. The wrapper's
    /// unchecked conformance only permits moving that immutable handle through
    /// the lock; reading/writing the handle itself remains lock-protected.
    private struct LockedAudioHandler: @unchecked Sendable {
        let body: (AVAudioPCMBuffer, AudioSource) -> Void
    }

    private struct LockedCaptureState: Sendable {
        var gate = CaptureSessionGate()
        var session: CaptureSession?
        var audioHandler: LockedAudioHandler?
    }

    @ObservationIgnored
    private let captureState = OSAllocatedUnfairLock(initialState: LockedCaptureState())
    @ObservationIgnored
    private let audioDeviceMonitor = DefaultAudioDeviceMonitor()

    // Observation invokes SwiftUI synchronously on the publishing executor.
    // Keep every observed value on MainActor; callbacks and file writes continue
    // on their existing queues through the independent locked capture state.
    @MainActor private(set) var isCapturing = false
    @MainActor private(set) var systemAudioURL: URL?
    @MainActor private(set) var micAudioURL: URL?
    @MainActor private(set) var audioLevel: Float = 0
    /// Live mic input level (separate from system audio) so the UI can show
    /// whether the user's own voice is actually being picked up.
    @MainActor private(set) var micLevel: Float = 0
    /// Whether the mic stream is actually capturing (false = system audio only).
    @MainActor private(set) var micActive = false
    @MainActor private(set) var inputDeviceName = ""
    @MainActor private(set) var outputDeviceName = ""
    @MainActor private(set) var lastTimelineManifest: AudioTimelineManifest?
    /// Capture-start time, or the last moment the mic carried real signal. While the
    /// mic has never been heard it stays at capture start, so it doubles as "how long
    /// the mic has been silent since recording began".
    @MainActor private(set) var lastMicSignalAt = Date.distantPast

    /// True once the mic has produced any real signal this recording. A user who is
    /// merely listening (normal while the other side talks) just hasn't spoken yet —
    /// that is not a dead mic — so once we've heard signal we never warn.
    @MainActor private(set) var micEverHadSignal = false

    /// True when echo cancellation is enabled but the system-audio reference never
    /// arrives in the expected format — the AEC is then a silent no-op and the
    /// far end's voice can transcribe as "Me". Shown in the live device bar.
    @MainActor private(set) var echoCancellerStarved = false

    @ObservationIgnored @MainActor private var stopTask: Task<Void, Never>?

    /// The main waveform represents whichever side is currently audible. Keeping
    /// mic and system levels separate is still useful in the device bar, but a
    /// mic-only speaker must never see a flat primary waveform.
    @MainActor var liveAudioLevel: Float {
        Self.combinedLiveLevel(system: audioLevel, mic: micLevel)
    }

    static func combinedLiveLevel(system: Float, mic: Float) -> Float {
        max(system, mic)
    }

    /// True only when the mic has been on for a while but has never produced any
    /// signal — a genuinely dead, muted, or misrouted mic. We key off "never heard"
    /// rather than recent silence, because in a call the user is routinely silent for
    /// far longer than a few seconds while the other side is speaking.
    @MainActor var micSeemsDead: Bool {
        isCapturing && micActive && !micEverHadSignal
            && Date().timeIntervalSince(lastMicSignalAt) > 15
    }

    /// Called with PCM audio buffers suitable for WhisperKit, tagged with which
    /// stream they came from (mic = the user, system = everyone else).
    @ObservationIgnored
    var onAudioBuffer: ((AVAudioPCMBuffer, AudioSource) -> Void)? {
        get { captureState.withLock { $0.audioHandler?.body } }
        set {
            captureState.withLock {
                $0.audioHandler = newValue.map(LockedAudioHandler.init(body:))
            }
        }
    }

    private let sampleRate: Double = 16000
    private let channels: UInt32 = 1

    // MARK: - Start Capture

    @MainActor func startCapture() async throws {
        let storageDir = Self.storageDirectory()
        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let uniqueSuffix = UUID().uuidString.prefix(8)

        let nextSystemAudioURL = storageDir.appendingPathComponent("system_\(timestamp)-\(uniqueSuffix).caf")
        let nextMicAudioURL = storageDir.appendingPathComponent("mic_\(timestamp)-\(uniqueSuffix).caf")

        // Echo cancellation on by default (defeats speaker bleed without headphones).
        let aecEnabled = UserDefaults.standard.object(forKey: "echoCancellationEnabled") as? Bool ?? true
        let nextEchoCanceller = aecEnabled ? EchoCanceller() : nil

        // Claim the lifecycle before the first await. A second start arriving
        // while ScreenCaptureKit is still preparing cannot create parallel
        // hardware streams or replace the first session's file destinations.
        let session: CaptureSession? = captureState.withLock { state in
            guard state.session == nil else { return nil }
            let token = state.gate.begin()
            let session = CaptureSession(
                token: token,
                systemAudioURL: nextSystemAudioURL,
                micAudioURL: nextMicAudioURL,
                echoCanceller: nextEchoCanceller
            )
            state.session = session
            return session
        }
        guard let session else { throw CaptureError.captureAlreadyInProgress }

        lastTimelineManifest = nil
        inputDeviceName = Self.defaultDeviceName(input: true)
        outputDeviceName = Self.defaultDeviceName(input: false)
        NSLog("Parrot: starting capture — input: \(inputDeviceName), output: \(outputDeviceName)")
        systemAudioURL = nextSystemAudioURL
        micAudioURL = nextMicAudioURL

        do {
            try await startSystemAudioCapture(for: session)
        } catch {
            closeGate(for: session)
            systemWriteQueue.sync { session.systemAudioFile = nil }
            micWriteQueue.sync { session.micAudioFile = nil }
            systemAudioURL = nil
            micAudioURL = nil
            throw error
        }

        // The microphone is optional. System audio ("Them") is the core capture;
        // a missing or denied mic must NOT abort the whole recording. If mic setup
        // fails we just don't get the user's own voice ("Me") and carry on.
        do {
            try startMicCapture(for: session)
            micActive = true
        } catch {
            micActive = false
            NSLog("Parrot: microphone unavailable, recording system audio only — \(error.localizedDescription)")
        }

        guard accepts(session) else { throw CaptureError.captureSuperseded }

        lastMicSignalAt = Date()  // capture start; the "dead mic" warning waits on this
        micEverHadSignal = false
        echoCancellerStarved = false
        isCapturing = true

        audioDeviceMonitor.start { [weak self, weak session] route in
            DispatchQueue.main.async {
                guard let self, let session else { return }
                self.handleAudioRouteChange(route, for: session)
            }
        }
    }

    // MARK: - Stop Capture

    @MainActor func stopCapture() async {
        // A second Stop/termination request joins the first drain rather than
        // returning while the hardware and CAF handles are still open.
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { @MainActor in
            defer { self.stopTask = nil }
            await self.performStopCapture()
        }
        stopTask = task
        await task.value
    }

    @MainActor private func performStopCapture() async {
        // Snapshot one session. All cleanup below is scoped to this identity, so
        // even a delayed stop can never nil or close a later session's resources.
        guard let session = captureState.withLock({ state -> CaptureSession? in
            guard let session = state.session, !session.stopping else { return nil }
            session.stopping = true
            return session
        }) else {
            isCapturing = false
            micActive = false
            audioLevel = 0
            micLevel = 0
            return
        }

        isCapturing = false
        micActive = false
        micEverHadSignal = false
        audioLevel = 0
        micLevel = 0
        audioDeviceMonitor.stop()

        // Stop hardware first. In-flight callbacks may still finish while the
        // gate is open, which lets their writes land before the barriers below.
        let resources = captureState.withLock { _ in
            (session.systemStream, session.audioEngine)
        }
        if let stream = resources.0 {
            try? await stream.stopCapture()
        }
        // ScreenCaptureKit uses our serial queue. Once stopCapture returns, this
        // barrier drains every callback already submitted before we close
        // callback admission below.
        systemCaptureQueue.sync {}

        stopMicrophone(for: session, expectsResume: false)
        captureState.withLock { _ in
            session.systemStream = nil
            session.systemOutput = nil
        }

        // A mic/SCK callback may already be converting a buffer. Close admission
        // atomically and wait for every admitted callback to enqueue both its CAF
        // write and transcription emit before closing the generation.
        await closeCallbackAdmissionAndWait(for: session)

        // Echo alignment keeps a short look-ahead and a partial DSP frame. Its
        // tail belongs to the recording, even when Stop lands between frames.
        if let tail = session.echoCanceller?.flush(), !tail.isEmpty,
           let format = AVAudioFormat(
               commonFormat: .pcmFormatFloat32,
               sampleRate: sampleRate,
               channels: AVAudioChannelCount(channels),
               interleaved: false
           ), let buffer = Self.makeBuffer(tail, format: format) {
            appendAudio(buffer, to: .mic, session: session)
            emitAudio(buffer, source: .me, session: session)
        }

        // Callback admission is already closed. Flush every queued write while
        // the session identity is still visible so successful frame counts land
        // in the timeline, then close the generation and CAF handles.
        systemWriteQueue.sync { session.systemAudioFile = nil }
        micWriteQueue.sync { session.micAudioFile = nil }
        lastTimelineManifest = session.timeline.manifest(sampleRate: sampleRate)
        closeGate(for: session)

        let attrs = try? FileManager.default.attributesOfItem(atPath: session.systemAudioURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        NSLog("Parrot: system audio file finalized — \(size) bytes, \(session.systemCallbackCount) callbacks, \(session.systemConversionFailureCount) conversion failures")
        if let alignment = session.echoCanceller?.alignmentStatistics {
            NSLog("ParrotMetric event=echo_alignment aligned_frames=%d passthrough_frames=%d",
                  alignment.alignedFrames, alignment.passthroughFrames)
        }
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture(for session: CaptureSession) async throws {
        // Pre-check screen capture permission
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw CaptureError.screenRecordingDenied
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = Int(channels)
        // We only want audio, minimize video overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // The system audio file is created lazily from the first buffer's format
        // (see the SCStreamOutput handler), so it always matches what we write.

        let output = SystemAudioOutput(
            owner: self,
            route: SystemAudioCallbackRoute(token: session.token)
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: systemCaptureQueue)
        let registered = captureState.withLock { state -> Bool in
            guard state.session === session, state.gate.accepts(session.token) else { return false }
            session.systemStream = stream
            session.systemOutput = output
            return true
        }
        guard registered else { throw CaptureError.captureSuperseded }

        do {
            try await stream.startCapture()
        } catch {
            try? await stream.stopCapture()
            captureState.withLock { _ in
                session.systemStream = nil
                session.systemOutput = nil
            }
            throw error
        }

        guard accepts(session) else {
            try? await stream.stopCapture()
            throw CaptureError.captureSuperseded
        }
    }

    // MARK: - Microphone (AVAudioEngine)

    @MainActor private func startMicCapture(for session: CaptureSession) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let microphoneToken = captureState.withLock { _ -> MicrophoneCaptureGenerationGate.Token in
            let token = session.microphoneGate.begin()
            session.microphoneToken = token
            return token
        }

        // NOTE: we previously enabled setVoiceProcessingEnabled(true) for acoustic
        // echo cancellation, but on this hardware it cancelled ALL mic input (the
        // user's own voice was lost — every recording came back with only "Them").
        // Reverted. Echo (mic picking up the speakers) is avoided by using
        // headphones; a safer AEC approach can be revisited and tested later.

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // When mic access is denied/unavailable the input format collapses to 0
        // channels; installing a tap on that would crash. Bail out cleanly so the
        // caller can continue with system audio only.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw CaptureError.noMicrophone
        }

        // The mic file is created lazily from the converted (16 kHz mono) format.

        // Convert mic audio to our target format for WhisperKit
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self, session] buffer, time in
            guard let self,
                  self.acceptsMicrophone(microphoneToken, for: session),
                  self.beginCallback(for: session) else { return }
            defer { self.endCallback(for: session) }

            // Convert to target format
            guard let converter else { return }
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return
            }

            var error: NSError?
            var consumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                // Contract: the converter may call this more than once per
                // convert() during rate conversion — handing it the same buffer
                // again duplicates ~20 ms of mic audio (stutter in "Me").
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                let bufferUptime = ProcessInfo.processInfo.systemUptime
                let captureTime: TimeInterval? = time.isHostTimeValid
                    ? Self.validHostClockTime(AVAudioTime.seconds(forHostTime: time.hostTime)) : nil
                // The saved track starts at its first captured sample, not at
                // the later callback that releases the AEC look-ahead.
                self.captureState.withLock { state in
                    guard state.session === session,
                          state.gate.accepts(session.token),
                          session.microphoneGate.accepts(microphoneToken) else { return }
                    session.timeline.noteFirstBuffer(
                        for: .me,
                        offset: (captureTime ?? bufferUptime) - session.startedUptime
                    )
                }
                // Echo-cancel the mic using the system audio as reference. With AEC
                // off, this returns the mic unchanged. With it on, it returns cleaned
                // 10 ms frames (possibly empty until a frame fills) — fail-safe.
                let micFloats = Self.floats(from: convertedBuffer)
                let cleaned = session.echoCanceller?.process(
                    mic: micFloats, at: captureTime
                ) ?? micFloats
                guard !cleaned.isEmpty,
                      let cleanedBuffer = Self.makeBuffer(cleaned, format: targetFormat) else { return }

                let missingFrames = self.captureState.withLock { state -> Int64 in
                    guard state.session === session,
                          state.gate.accepts(session.token),
                          session.microphoneGate.accepts(microphoneToken) else { return 0 }
                    defer {
                        session.lastMicrophoneBufferUptime = bufferUptime
                        session.microphoneGapPending = false
                    }
                    guard session.microphoneGapPending,
                          let previous = session.lastMicrophoneBufferUptime else { return 0 }
                    return MicrophoneGapCompensation.missingFrames(
                        previousBufferUptime: previous,
                        currentBufferUptime: bufferUptime,
                        currentBufferFrames: Int(cleanedBuffer.frameLength),
                        sampleRate: self.sampleRate
                    )
                }

                // Persist the user's voice ("Me") as 16 kHz mono PCM.
                if missingFrames > 0 {
                    self.appendSilence(
                        frameCount: missingFrames,
                        format: targetFormat,
                        session: session
                    )
                }
                self.appendAudio(cleanedBuffer, to: .mic, session: session)

                // Update the mic level so the UI can show the user's voice landing.
                self.updateAudioLevel(buffer: cleanedBuffer, isMic: true, session: session)

                // Send the user's speech to transcription as "Me"
                self.emitAudio(cleanedBuffer, source: .me, session: session)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            captureState.withLock { _ in
                session.microphoneGate.end(microphoneToken)
                if session.microphoneToken == microphoneToken {
                    session.microphoneToken = nil
                }
            }
            throw error
        }
        guard accepts(session) else {
            engine.stop()
            inputNode.removeTap(onBus: 0)
            captureState.withLock { _ in
                session.microphoneGate.end(microphoneToken)
                session.microphoneToken = nil
            }
            throw CaptureError.captureSuperseded
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, weak session] _ in
            Task { @MainActor in
                guard let self, let session else { return }
                self.handleAudioEngineConfigurationChange(
                    for: session,
                    microphoneToken: microphoneToken
                )
            }
        }
        captureState.withLock { _ in
            session.audioEngine = engine
            session.audioEngineConfigurationObserver = observer
        }
    }

    private func acceptsMicrophone(
        _ microphoneToken: MicrophoneCaptureGenerationGate.Token,
        for session: CaptureSession
    ) -> Bool {
        captureState.withLock { state in
            state.session === session
                && state.gate.accepts(session.token)
                && session.microphoneGate.accepts(microphoneToken)
        }
    }

    @MainActor private func handleAudioRouteChange(
        _ route: AudioRouteSnapshot,
        for session: CaptureSession
    ) {
        guard accepts(session), !session.stopping else { return }
        let previous = captureState.withLock { _ -> AudioRouteSnapshot in
            let previous = session.audioRoute
            session.audioRoute = route
            return previous
        }
        applyAudioRouteActions(
            AudioRouteChangePolicy.actions(previous: previous, current: route),
            for: session
        )
    }

    @MainActor private func handleAudioEngineConfigurationChange(
        for session: CaptureSession,
        microphoneToken: MicrophoneCaptureGenerationGate.Token
    ) {
        guard acceptsMicrophone(microphoneToken, for: session),
              !session.isRestartingMicrophone else { return }
        let route = DefaultAudioDeviceMonitor.currentSnapshot()
        let previous = captureState.withLock { _ -> AudioRouteSnapshot in
            let previous = session.audioRoute
            session.audioRoute = route
            return previous
        }
        applyAudioRouteActions(
            AudioRouteChangePolicy.actions(
                previous: previous,
                current: route,
                engineConfigurationChanged: true
            ),
            for: session
        )
    }

    @MainActor private func applyAudioRouteActions(
        _ actions: [AudioRouteChangeAction],
        for session: CaptureSession
    ) {
        guard !actions.isEmpty, accepts(session), !session.stopping else { return }

        if actions.contains(.refreshDeviceNames) {
            inputDeviceName = Self.defaultDeviceName(input: true)
            outputDeviceName = Self.defaultDeviceName(input: false)
        }
        guard actions.contains(.restartMicrophone) else { return }

        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.restartMicrophone(for: session)
        }
        let previous = captureState.withLock { _ -> DispatchWorkItem? in
            let previous = session.microphoneRestartWorkItem
            session.microphoneRestartWorkItem = work
            return previous
        }
        previous?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @MainActor private func restartMicrophone(for session: CaptureSession) {
        guard accepts(session), !session.stopping, !session.isRestartingMicrophone else {
            return
        }
        session.isRestartingMicrophone = true
        session.microphoneRestartWorkItem = nil
        stopMicrophone(for: session, expectsResume: true)

        do {
            try startMicCapture(for: session)
            micActive = true
            inputDeviceName = Self.defaultDeviceName(input: true)
            NSLog("Parrot: microphone followed the new default input — \(inputDeviceName)")
        } catch {
            // Keep system audio and the meeting alive. A later CoreAudio route
            // notification will retry when a usable microphone appears.
            micActive = false
            micLevel = 0
            NSLog("Parrot: microphone route unavailable; system recording continues — \(error.localizedDescription)")
        }
        session.isRestartingMicrophone = false
    }

    @MainActor private func stopMicrophone(
        for session: CaptureSession,
        expectsResume: Bool
    ) {
        let resources = captureState.withLock { _ -> (AVAudioEngine?, NSObjectProtocol?) in
            session.microphoneRestartWorkItem?.cancel()
            session.microphoneRestartWorkItem = nil
            if let token = session.microphoneToken {
                session.microphoneGate.end(token)
                session.microphoneToken = nil
            }
            let result = (session.audioEngine, session.audioEngineConfigurationObserver)
            session.audioEngine = nil
            session.audioEngineConfigurationObserver = nil
            session.microphoneGapPending = expectsResume
                && session.lastMicrophoneBufferUptime != nil
            return result
        }
        if let observer = resources.1 {
            NotificationCenter.default.removeObserver(observer)
        }
        resources.0?.stop()
        resources.0?.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Audio File Writing

    private enum AudioStream { case system, mic }

    /// Keep the saved microphone timeline aligned with system audio when a
    /// device transition briefly interrupts AVAudioEngine. Silence is written
    /// in bounded one-second chunks, so even a long unplugged interval cannot
    /// create a large temporary allocation.
    private func appendSilence(
        frameCount: Int64,
        format: AVAudioFormat,
        session: CaptureSession
    ) {
        guard frameCount > 0 else { return }
        let stateLock = captureState
        let framesPerChunk = AVAudioFrameCount(sampleRate)
        captureState.withLock { state in
            guard state.session === session,
                  state.gate.accepts(session.token) else { return }
            micWriteQueue.async { [session, stateLock] in
                var remaining = frameCount
                do {
                    if session.micAudioFile == nil {
                        session.micAudioFile = try AVAudioFile(
                            forWriting: session.micAudioURL,
                            settings: format.settings
                        )
                    }
                    guard let file = session.micAudioFile else { return }
                    while remaining > 0 {
                        let count = AVAudioFrameCount(
                            min(Int64(framesPerChunk), remaining)
                        )
                        guard let buffer = AVAudioPCMBuffer(
                            pcmFormat: format,
                            frameCapacity: count
                        ), let channels = buffer.floatChannelData else { return }
                        buffer.frameLength = count
                        for channel in 0..<Int(format.channelCount) {
                            channels[channel].initialize(
                                repeating: 0,
                                count: Int(count)
                            )
                        }
                        try file.write(from: buffer)
                        stateLock.withLock { state in
                            guard state.session === session else { return }
                            session.timeline.addFrames(Int(count), for: .me)
                        }
                        remaining -= Int64(count)
                    }
                } catch {
                    NSLog("Parrot: microphone gap compensation failed — \(error.localizedDescription)")
                }
            }
        }
    }

    /// Appends a PCM buffer to a stream's .caf file off the capture/render thread.
    /// The file is created lazily from the first buffer's own format, so writes can
    /// never fail on a format mismatch and there is no codec to initialize. The
    /// buffer is deep-copied because the audio system reuses it after we return.
    private func appendAudio(
        _ buffer: AVAudioPCMBuffer,
        to stream: AudioStream,
        session: CaptureSession
    ) {
        guard let copy = buffer.deepCopy() else { return }
        let queue = stream == .system ? systemWriteQueue : micWriteQueue
        let url = stream == .system ? session.systemAudioURL : session.micAudioURL
        let stateLock = captureState

        // Admission and enqueue are one atomic lifecycle operation. Once a
        // block is admitted it must write even if stop closes the gate a moment
        // later; stop's sync barrier will then finalize every admitted sample.
        captureState.withLock { state in
            guard state.session === session, state.gate.accepts(session.token) else { return }
            queue.async { [session, stateLock] in
                do {
                    let file: AVAudioFile
                    if stream == .system {
                        if session.systemAudioFile == nil {
                            session.systemAudioFile = try AVAudioFile(forWriting: url, settings: copy.format.settings)
                        }
                        file = session.systemAudioFile!
                    } else {
                        if session.micAudioFile == nil {
                            session.micAudioFile = try AVAudioFile(forWriting: url, settings: copy.format.settings)
                        }
                        file = session.micAudioFile!
                    }
                    try file.write(from: copy)
                    stateLock.withLock { state in
                        guard state.session === session else { return }
                        session.timeline.addFrames(
                            Int(copy.frameLength),
                            for: stream == .system ? .them : .me
                        )
                    }
                } catch {
                    NSLog("Parrot: \(stream) audio write failed — \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateAudioLevel(
        buffer: AVAudioPCMBuffer,
        isMic: Bool = false,
        session: CaptureSession
    ) {
        guard accepts(session) else { return }
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            sum += abs(channelData[i])
        }
        let avg = sum / Float(max(frames, 1))

        // Throttle the main-thread hop per stream: the waveform only needs ~10
        // updates/sec, and dispatching every ~20 ms buffer (×2 streams) thrashed
        // SwiftUI. Sampling at 10 Hz still detects a live mic well within the
        // 15 s dead-mic window.
        let now = ProcessInfo.processInfo.systemUptime
        let shouldPublish = captureState.withLock { state -> Bool in
            guard state.session === session, !session.stopping else { return false }
            if isMic {
                guard now - session.lastMicLevelUptime >= 0.1 else { return false }
                session.lastMicLevelUptime = now
            } else {
                guard now - session.lastSystemLevelUptime >= 0.1 else { return false }
                session.lastSystemLevelUptime = now
            }
            return true
        }
        guard shouldPublish else { return }

        DispatchQueue.main.async { [weak self, session] in
            guard let self, self.acceptsUIPublication(for: session) else { return }
            if isMic {
                self.micLevel = avg
                // Speech sits well above room noise; treat this as "mic is alive".
                if avg > 0.004 {
                    self.lastMicSignalAt = Date()
                    self.micEverHadSignal = true
                }
            } else {
                self.audioLevel = avg
            }
        }
    }

    /// Validate a callback and snapshot the handler under the same lock. The
    /// handler runs outside the lock so transcription can never block lifecycle
    /// transitions or recursively deadlock while unwiring itself.
    private func emitAudio(
        _ buffer: AVAudioPCMBuffer,
        source: AudioSource,
        session: CaptureSession
    ) {
        let handler = captureState.withLock { state -> ((AVAudioPCMBuffer, AudioSource) -> Void)? in
            guard state.session === session, state.gate.accepts(session.token) else { return nil }
            return state.audioHandler?.body
        }
        handler?(buffer, source)
    }

    private func accepts(_ session: CaptureSession) -> Bool {
        captureState.withLock { state in
            state.session === session && state.gate.accepts(session.token)
        }
    }

    private func acceptsUIPublication(for session: CaptureSession) -> Bool {
        captureState.withLock { state in
            state.session === session && state.gate.accepts(session.token)
                && !session.stopping
        }
    }

    private func beginCallback(for session: CaptureSession) -> Bool {
        captureState.withLock { state in
            guard state.session === session,
                  state.gate.accepts(session.token),
                  session.callbackAdmissionOpen else { return false }
            session.inFlightCallbacks += 1
            return true
        }
    }

    private func endCallback(for session: CaptureSession) {
        let waiters: [CheckedContinuation<Void, Never>] = captureState.withLock { _ in
            session.inFlightCallbacks = max(0, session.inFlightCallbacks - 1)
            guard session.inFlightCallbacks == 0,
                  !session.callbackWaiters.isEmpty else { return [] }
            let waiters = session.callbackWaiters
            session.callbackWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func closeCallbackAdmissionAndWait(for session: CaptureSession) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = captureState.withLock { state -> Bool in
                guard state.session === session else { return true }
                session.callbackAdmissionOpen = false
                if session.inFlightCallbacks == 0 { return true }
                session.callbackWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private func closeGate(for session: CaptureSession) {
        captureState.withLock { state in
            state.gate.end(session.token)
            if state.session === session {
                state.session = nil
            }
        }
    }

    /// Name of the current system default input or output device (CoreAudio).
    static func defaultDeviceName(input: Bool) -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return "Unknown" }

        // The property is a CFString reference; fetch it through an Unmanaged
        // slot rather than &CFString (which the compiler rightly flags — taking
        // a raw pointer to an object reference is UB territory).
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard status == noErr, let name = nameRef?.takeRetainedValue() else {
            return "Unknown"
        }
        return name as String
    }

    // MARK: - Buffer helpers

    /// Mono float samples from a PCM buffer.
    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }

    /// SCK PTS and AVAudioTime hostTime use the host clock. If an OS/device
    /// delivers another time domain or an invalid value, bypass AEC safely.
    private static func validHostClockTime(_ timestamp: TimeInterval) -> TimeInterval? {
        guard timestamp.isFinite, timestamp >= 0,
              abs(timestamp - ProcessInfo.processInfo.systemUptime) < 5 else { return nil }
        return timestamp
    }

    /// Mono PCM buffer from float samples in the given format.
    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            ch[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // MARK: - Storage

    static func storageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Parrot/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - SCStreamOutput

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var owner: AudioCaptureManager?
    let route: SystemAudioCallbackRoute

    init(owner: AudioCaptureManager, route: SystemAudioCallbackRoute) {
        self.owner = owner
        self.route = route
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        owner?.handleSystemAudio(sampleBuffer, type: type, route: route)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        NSLog("Parrot: ScreenCaptureKit stream stopped — \(error.localizedDescription)")
    }
}

extension AudioCaptureManager {
    fileprivate func handleSystemAudio(
        _ sampleBuffer: CMSampleBuffer,
        type: SCStreamOutputType,
        route: SystemAudioCallbackRoute
    ) {
        guard type == .audio else { return }
        let captureTime = Self.validHostClockTime(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        )
        let session = captureState.withLock { state -> CaptureSession? in
            guard let session = state.session,
                  session.token == route.token,
                  route.isAccepted(by: state.gate) else { return nil }
            session.systemCallbackCount += 1
            session.timeline.noteFirstBuffer(
                for: .them,
                offset: (captureTime ?? ProcessInfo.processInfo.systemUptime) - session.startedUptime
            )
            return session
        }
        guard let session, beginCallback(for: session) else { return }
        defer { endCallback(for: session) }

        // Convert CMSampleBuffer to AVAudioPCMBuffer for WhisperKit
        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer(sampleRate: sampleRate, channels: channels) else {
            let failures = captureState.withLock { _ -> Int in
                session.systemConversionFailureCount += 1
                return session.systemConversionFailureCount
            }
            if failures <= 3 {
                let frames = CMSampleBufferGetNumSamples(sampleBuffer)
                let format = CMSampleBufferGetFormatDescription(sampleBuffer)
                    .flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)
                    .map { "\($0.pointee.mSampleRate) Hz ×\($0.pointee.mChannelsPerFrame)ch, flags=\($0.pointee.mFormatFlags)" }
                    ?? "unknown format"
                NSLog("Parrot: system audio conversion failed — \(frames) frames, \(format)")
            }
            return
        }

        // Persist everyone else's voice ("Them") as PCM.
        appendAudio(pcmBuffer, to: .system, session: session)

        // Feed the same audio to the echo canceller as the far-end reference, so it
        // can subtract this from the mic. Only when it's the expected 16 kHz mono.
        if pcmBuffer.format.sampleRate == sampleRate, pcmBuffer.format.channelCount == channels {
            if let captureTime {
                session.echoCanceller?.pushReference(
                    Self.floats(from: pcmBuffer), at: captureTime
                )
            }
        } else if session.echoCanceller != nil {
            let shouldReport = captureState.withLock { state -> Bool in
                guard state.session === session,
                      state.gate.accepts(session.token),
                      !session.starvationReported else { return false }
                session.starvationReported = true
                return true
            }
            if shouldReport {
                // Without a reference the AEC is silently a no-op and speaker bleed
                // transcribes as "Me" — surface it once instead of hiding it.
                NSLog("Parrot: echo canceller starved — system audio is \(pcmBuffer.format.sampleRate) Hz ×\(pcmBuffer.format.channelCount)ch, expected \(sampleRate) Hz mono")
                DispatchQueue.main.async { [weak self, session] in
                    guard let self, self.acceptsUIPublication(for: session) else { return }
                    self.echoCancellerStarved = true
                }
            }
        }

        // Update audio level
        updateAudioLevel(buffer: pcmBuffer, session: session)

        // Send everyone else's speech to transcription as "Them"
        emitAudio(pcmBuffer, source: .them, session: session)
    }
}

// MARK: - Capture Error

enum CaptureError: LocalizedError {
    case noDisplay
    case noMicrophone
    case screenRecordingDenied
    case captureAlreadyInProgress
    case captureSuperseded

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display found for audio capture"
        case .noMicrophone: "No microphone available"
        case .screenRecordingDenied: "Screen Recording permission is required. Please grant it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Parrot."
        case .captureAlreadyInProgress: "Audio capture is already starting or running"
        case .captureSuperseded: "Audio capture was stopped before startup completed"
        }
    }
}

// MARK: - Buffer Conversion Extensions

extension CMSampleBuffer {
    func toAVAudioPCMBuffer(sampleRate: Double, channels: UInt32) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let sourceFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }
        // AVAudioPCMBuffer exposes zero writable bytes while frameLength is zero.
        // Set the intended length before asking CoreMedia to copy into its ABL.
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        if copyStatus != noErr {
            // ScreenCaptureKit's 16 kHz mono buffers on recent macOS are valid
            // contiguous PCM, but `CMSampleBufferCopyPCMDataIntoAudioBufferList`
            // can reject them because their sample-size table is omitted. Copy
            // the underlying block directly for a single-plane destination.
            // Interleaved audio is also one plane; non-interleaved multichannel
            // still uses the stricter AudioBufferList path above.
            guard sourceFormat.channelCount == 1 || sourceFormat.isInterleaved,
                  let block = CMSampleBufferGetDataBuffer(self),
                  let destination = sourceBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
                return nil
            }
            let availableBytes = CMBlockBufferGetDataLength(block)
            let destinationBytes = Int(sourceBuffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize)
            let bytesToCopy = min(availableBytes, destinationBytes)
            guard bytesToCopy > 0,
                  CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: bytesToCopy,
                    destination: destination
                  ) == noErr else {
                return nil
            }
        }
        let targetChannels = AVAudioChannelCount(channels)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: targetChannels,
            interleaved: false
        ) else { return nil }

        // ScreenCaptureKit normally honors the requested 16 kHz mono format.
        // Preserve that zero-conversion fast path, but correctly downmix and
        // resample when a device/OS returns 44.1/48 kHz or multiple channels.
        if sourceFormat.commonFormat == .pcmFormatFloat32,
           !sourceFormat.isInterleaved,
           sourceFormat.sampleRate == sampleRate,
           sourceFormat.channelCount == targetChannels {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        let ratio = sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(outputCapacity, 1)
        ) else { return nil }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard conversionError == nil,
              status != .error,
              output.frameLength > 0 else { return nil }
        return output
    }
}

extension AVAudioPCMBuffer {
    /// Independent copy of the samples. Tap/conversion buffers are owned by the
    /// audio system and reused on the next callback, so we must copy before
    /// handing the data to an async writer.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        let channelCount = Int(format.channelCount)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size)
            }
        }
        return copy
    }

    func toCMSampleBuffer(presentationTime: AVAudioTime) -> CMSampleBuffer? {
        let format = self.format
        guard let formatDesc = format.formatDescription as CMFormatDescription? else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameLength), timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: Double(presentationTime.sampleTime) / format.sampleRate, preferredTimescale: CMTimeScale(format.sampleRate)),
            decodeTimeStamp: .invalid
        )

        guard let data = floatChannelData?[0] else { return nil }
        let dataSize = Int(frameLength) * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard let block = blockBuffer else { return nil }
        CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize)

        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}
