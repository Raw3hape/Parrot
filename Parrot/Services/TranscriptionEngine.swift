import AVFoundation
import FluidAudio
import Foundation
import os

/// Which capture stream a piece of audio came from.
enum AudioSource: CaseIterable, Sendable {
    /// Microphone — the user.
    case me
    /// System audio — everyone else on the call.
    case them

    var label: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        }
    }
}

/// Fully on-device, call-oriented transcription. The microphone and system
/// streams have independent VAD/utterance state, so every finalized segment is
/// already attributed without a diarization model.
@Observable
final class TranscriptionEngine {
    private let parakeetService = ParakeetModelService()
    private let whisperService = WhisperModelService()
    private var recognitionRouter: LocalRecognitionRouter?
    private var vadManager: VadManager?
    private var streamProcessors: [AudioSource: CallStreamProcessor] = [:]
    private var fallbackPreparationTask: Task<Void, Never>?
    private var whisperIsReady = false

    private var audioBuffers: [AudioSource: [Float]] = [.me: [], .them: []]
    private let bufferLock = OSAllocatedUnfairLock()
    private var transcriptionTask: Task<Void, Never>?
    private var sessionGeneration = 0

    private(set) var isReady = false
    private(set) var isTranscribing = false
    private(set) var currentText = ""
    private(set) var modelState: ModelState = .notLoaded
    /// Retained for the existing live status bar. It now reports only local
    /// degradation (for example, Whisper unavailable), never a cloud fallback.
    private(set) var cloudNotice: String?

    /// Called when a finalized transcript segment is ready.
    var onSegment: ((TranscriptionResult) -> Void)?

    enum ModelState {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case error(String)
    }

    struct TranscriptionResult {
        let text: String
        let source: AudioSource
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float?
    }

    // MARK: - Model Management

    /// Prepare the local Parakeet primary model, local Whisper fallback, and
    /// Silero VAD. The argument remains for source compatibility with the old
    /// settings UI; this personal build intentionally pins its tested models.
    func loadModel(_ ignoredModelName: String = WhisperModelService.fallbackModel) async {
        guard !isTranscribing else { return }
        modelState = .loading
        isReady = false
        cloudNotice = nil

        var parakeetError: Error?
        var vadNotice: String?

        do {
            try await parakeetService.prepare()
        } catch {
            parakeetError = error
            NSLog("Parrot: local Parakeet model unavailable — \(error.localizedDescription)")
        }

        do {
            vadManager = try await VadManager(
                config: VadConfig(defaultThreshold: 0.55)
            )
        } catch {
            vadManager = nil
            vadNotice = "Silero VAD unavailable — local energy detection active"
            NSLog("Parrot: Silero VAD unavailable, using local energy VAD — \(error.localizedDescription)")
        }

        if parakeetError == nil {
            recognitionRouter = LocalRecognitionRouter(
                primary: parakeetService,
                fallback: whisperService
            )
            modelState = .ready
            isReady = true

            if whisperIsReady {
                cloudNotice = vadNotice
            } else {
                cloudNotice = Self.combinedNotice(
                    "Local Whisper fallback is warming up — Parakeet is ready",
                    vadNotice
                )
                prepareWhisperFallbackInBackground(vadNotice: vadNotice)
            }
            return
        }

        // Parakeet is the fast path. If it cannot load at all, wait for the
        // already-local Whisper model so the app still has a working engine.
        if let fallbackPreparationTask {
            await fallbackPreparationTask.value
        } else if !whisperIsReady {
            do {
                try await whisperService.prepare()
                whisperIsReady = true
            } catch {
                recognitionRouter = nil
                let message = [
                    "Parakeet: \(parakeetError?.localizedDescription ?? "unavailable")",
                    "Whisper: \(error.localizedDescription)",
                ].joined(separator: " | ")
                modelState = .error(message)
                return
            }
        }

        recognitionRouter = LocalRecognitionRouter(
            primary: whisperService,
            fallback: whisperService
        )
        cloudNotice = Self.combinedNotice(
            "Parakeet unavailable — using local Whisper",
            vadNotice
        )
        modelState = .ready
        isReady = true
    }

    private func prepareWhisperFallbackInBackground(vadNotice: String?) {
        guard fallbackPreparationTask == nil, !whisperIsReady else { return }
        fallbackPreparationTask = Task { [weak self, whisperService] in
            do {
                try await whisperService.prepare()
                await MainActor.run {
                    guard let self else { return }
                    self.whisperIsReady = true
                    self.cloudNotice = vadNotice
                    self.fallbackPreparationTask = nil
                }
            } catch {
                NSLog("Parrot: local Whisper fallback unavailable — \(error.localizedDescription)")
                await MainActor.run {
                    guard let self else { return }
                    self.cloudNotice = Self.combinedNotice(
                        "Local Whisper fallback unavailable — Parakeet remains active",
                        vadNotice
                    )
                    self.fallbackPreparationTask = nil
                }
            }
        }
    }

    private static func combinedNotice(_ first: String, _ second: String?) -> String {
        second.map { first + ". " + $0 } ?? first
    }

    // MARK: - Audio Input

    /// Feed 16 kHz mono audio from AudioCaptureManager, tagged by capture stream.
    func appendAudio(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard isTranscribing,
              let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(
            UnsafeBufferPointer(start: channelData, count: frameCount)
        )

        bufferLock.withLock {
            audioBuffers[source, default: []].append(contentsOf: samples)
        }
    }

    // MARK: - Transcription Loop

    func startTranscribing(meetingStartTime: Date) {
        guard isReady, let recognitionRouter else { return }

        transcriptionTask?.cancel()
        transcriptionTask = nil
        bufferLock.withLock { audioBuffers = [.me: [], .them: []] }
        currentText = ""
        isTranscribing = true
        sessionGeneration += 1
        let session = sessionGeneration

        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        let language = (setting == nil || setting == "auto") ? nil : setting
        let vadManager = self.vadManager

        var processors: [AudioSource: CallStreamProcessor] = [:]
        for source in AudioSource.allCases {
            processors[source] = CallStreamProcessor(
                source: source,
                vad: vadManager,
                router: recognitionRouter,
                language: language,
                onPreview: { [weak self] text, _ in
                    await MainActor.run {
                        guard let self,
                              self.sessionGeneration == session,
                              self.isTranscribing else { return }
                        self.currentText = text
                    }
                },
                onFinal: { [weak self] result, startSample, endSample in
                    await MainActor.run {
                        guard let self,
                              self.sessionGeneration == session else { return }
                        self.currentText = result.text
                        self.onSegment?(TranscriptionResult(
                            text: result.text,
                            source: source,
                            startTime: Double(startSample) / 16_000.0,
                            endTime: Double(endSample) / 16_000.0,
                            confidence: result.confidence
                        ))
                    }
                }
            )
        }
        streamProcessors = processors

        transcriptionTask = Task { [weak self, processors] in
            guard let self else { return }

            while !Task.isCancelled {
                let draining = !self.isTranscribing
                var didWork = false

                for source in AudioSource.allCases {
                    let chunk: [Float] = self.bufferLock.withLock {
                        guard let buffered = self.audioBuffers[source],
                              !buffered.isEmpty else { return [] }
                        if !draining, buffered.count < VadManager.chunkSize {
                            return []
                        }
                        let count = min(buffered.count, VadManager.chunkSize)
                        self.audioBuffers[source] = Array(buffered.dropFirst(count))
                        return Array(buffered.prefix(count))
                    }
                    guard !chunk.isEmpty, let processor = processors[source] else { continue }
                    didWork = true
                    await processor.append(chunk)
                }

                if !didWork {
                    if draining {
                        for source in AudioSource.allCases {
                            await processors[source]?.finish()
                        }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    /// Drain both streams and finalize any short tail that remained below one
    /// VAD frame. Capture must already be stopped before calling this method.
    func stopTranscribing() async {
        isTranscribing = false
        await transcriptionTask?.value
        transcriptionTask = nil
        streamProcessors = [:]
        bufferLock.withLock { audioBuffers = [.me: [], .them: []] }
        currentText = ""
    }

    /// The classic Whisper silence hallucinations — phrases the model invents
    /// verbatim on near-silent chunks. Applied to both local recognizers.
    static let hallucinationPhrases: Set<String> = [
        "you", "okay", "ok", "thank you", "thanks", "bye", "bye-bye",
        "thank you for watching", "thanks for watching", "hmm", "mm-hmm",
        "uh", "um", "the end", "subtitles by", "1", "2",
    ]

    static func isLikelyHallucination(_ text: String, energy: Float) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…-—"))
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return true }
        guard energy < 0.006 else { return false }
        return hallucinationPhrases.contains(normalized)
    }

    static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"<\|[^|>]*\|>"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
