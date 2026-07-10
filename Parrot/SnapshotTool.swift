import SwiftUI
import AppKit
import FluidAudio
import WhisperKit

/// Integration harness for the exact production Parakeet service. It converts
/// any supported audio file to 16 kHz mono, prepares the cached/downloaded V3
/// model, then reports text and real-time factor.
enum ParakeetIntegrationTest {
    static func run(audioPath: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let hasText = try await execute(audioPath: audioPath)
                if !hasText { exit(2) }
            } catch {
                FileHandle.standardError.write(
                    Data("diagnostic=parakeet status=failed error_type=\(String(reflecting: type(of: error)))\n".utf8)
                )
                exit(1)
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func execute(audioPath: String) async throws -> Bool {
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(path: audioPath)
        let service = ParakeetModelService()

        let loadStart = Date()
        async let firstPreparation: Void = service.prepare()
        async let secondPreparation: Void = service.prepare()
        _ = try await (firstPreparation, secondPreparation)
        let loadSeconds = Date.now.timeIntervalSince(loadStart)
        let preparationLaunches = await service.preparationLaunchCount

        let decodeStart = Date()
        let result = try await service.transcribe(samples: samples, language: nil)
        let decodeSeconds = Date.now.timeIntervalSince(decodeStart)
        let audioSeconds = Double(samples.count) / 16_000.0
        let realTimeFactor = decodeSeconds / max(audioSeconds, 0.001)
        let confidenceIsValid = result.confidence?.isFinite ?? true

        print("diagnostic: parakeet")
        print(String(format: "audio_seconds: %.3f", audioSeconds))
        print(String(format: "load_seconds: %.3f", loadSeconds))
        print("preparation_launches: \(preparationLaunches)")
        print(String(format: "decode_seconds: %.3f", decodeSeconds))
        print(String(format: "real_time_factor: %.4f", realTimeFactor))
        print("transcript_characters: \(result.text.count)")
        print("confidence_is_finite: \(confidenceIsValid ? 1 : 0)")
        return !result.text.isEmpty && confidenceIsValid && preparationLaunches == 1
    }
}

/// Regression harness for the exact WhisperKit repository identifier that the
/// previous build reported as "Model not found".
enum WhisperFallbackIntegrationTest {
    static func run(audioPath: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let hasText = try await execute(audioPath: audioPath)
                if !hasText { exit(2) }
            } catch {
                FileHandle.standardError.write(
                    Data("diagnostic=whisper status=failed error_type=\(String(reflecting: type(of: error)))\n".utf8)
                )
                exit(1)
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func execute(audioPath: String) async throws -> Bool {
        let samples = try AudioConverter().resampleAudioFile(path: audioPath)
        let service = WhisperModelService()

        let loadStart = Date()
        async let firstPreparation: Void = service.prepare()
        async let secondPreparation: Void = service.prepare()
        _ = try await (firstPreparation, secondPreparation)
        let loadSeconds = Date.now.timeIntervalSince(loadStart)
        let preparationLaunches = await service.preparationLaunchCount

        let decodeStart = Date()
        let result = try await service.transcribe(samples: samples, language: nil)
        let decodeSeconds = Date.now.timeIntervalSince(decodeStart)
        let audioSeconds = Double(samples.count) / 16_000.0

        let confidenceIsValid = result.confidence?.isFinite ?? true
        print("diagnostic: whisper")
        print("model: \(WhisperModelService.fallbackModel)")
        print(String(format: "audio_seconds: %.3f", audioSeconds))
        print(String(format: "load_seconds: %.3f", loadSeconds))
        print("preparation_launches: \(preparationLaunches)")
        print(String(format: "decode_seconds: %.3f", decodeSeconds))
        print("transcript_characters: \(result.text.count)")
        print("confidence_is_finite: \(confidenceIsValid ? 1 : 0)")
        return !result.text.isEmpty && confidenceIsValid && preparationLaunches == 1
    }
}

/// End-to-end replay through the production Silero VAD, utterance assembler,
/// Parakeet router, preview gate, and finalized-segment callback.
enum CallPipelineIntegrationTest {
    private actor Sink {
        struct Final: Sendable {
            let textCharacters: Int
            let startSample: Int
            let endSample: Int
        }

        private var previewCount = 0
        private var finals: [Final] = []

        func addPreview() { previewCount += 1 }
        func addFinal(_ text: String, _ start: Int, _ end: Int) {
            finals.append(Final(textCharacters: text.count, startSample: start, endSample: end))
        }
        func snapshot() -> (Int, [Final]) { (previewCount, finals) }
    }

    static func run(audioPath: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let hasSegments = try await execute(audioPath: audioPath)
                if !hasSegments { exit(2) }
            } catch {
                FileHandle.standardError.write(
                    Data("diagnostic=call_pipeline status=failed error_type=\(String(reflecting: type(of: error)))\n".utf8)
                )
                exit(1)
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func execute(audioPath: String) async throws -> Bool {
        let edgeChecks = energyFallbackEdgeChecks()
        let backlogCheck = finalBacklogEdgeCheck()
        let samples = try AudioConverter().resampleAudioFile(path: audioPath)
        let service = ParakeetModelService()
        try await service.prepare()
        let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.55))
        let router = LocalRecognitionRouter(primary: service, fallback: service)
        let sink = Sink()
        let processor = CallStreamProcessor(
            source: .them,
            vad: vad,
            router: router,
            language: nil,
            onPreview: { _, _ in await sink.addPreview() },
            onFinal: { result, start, end in
                await sink.addFinal(result.text, start, end)
            }
        )

        for start in stride(from: 0, to: samples.count, by: VadManager.chunkSize) {
            let end = min(samples.count, start + VadManager.chunkSize)
            await processor.append(Array(samples[start..<end]))
        }
        await processor.finish()

        let (previews, finals) = await sink.snapshot()
        print("diagnostic: call_pipeline")
        print("previews: \(previews)")
        print("final_segments: \(finals.count)")
        print("final_audio_samples: \(finals.reduce(0) { $0 + max(0, $1.endSample - $1.startSample) })")
        print("transcript_characters: \(finals.reduce(0) { $0 + $1.textCharacters })")
        print("energy_noise_rejection: \(edgeChecks.noiseRejected ? 1 : 0)")
        print("energy_short_speech_start: \(edgeChecks.shortSpeechStarted ? 1 : 0)")
        print("vad_handoff_closure: \(edgeChecks.seededStateClosed ? 1 : 0)")
        print("final_backlog_order_and_bound: \(backlogCheck ? 1 : 0)")
        return !finals.isEmpty
            && finals.allSatisfy { $0.textCharacters > 0 }
            && edgeChecks.noiseRejected
            && edgeChecks.shortSpeechStarted
            && edgeChecks.seededStateClosed
            && backlogCheck
    }

    private static func finalBacklogEdgeCheck() -> Bool {
        func audio(samples: Int, generation: Int) -> UtteranceAudio {
            UtteranceAudio(
                samples: Array(repeating: 0.1, count: samples),
                startSample: generation * 100,
                endSample: generation * 100 + samples,
                generation: generation,
                forcedSplit: false
            )
        }

        var backlog = FinalRecognitionBacklog(maximumRetainedSamples: 10)
        guard backlog.enqueue(audio(samples: 6, generation: 1)),
              !backlog.enqueue(audio(samples: 5, generation: 2)),
              backlog.retainedSampleCount == 6,
              backlog.dequeue()?.generation == 1,
              backlog.retainedSampleCount == 6 else { return false }
        backlog.complete(sampleCount: 6)
        guard backlog.retainedSampleCount == 0,
              backlog.enqueue(audio(samples: 4, generation: 3)),
              backlog.enqueue(audio(samples: 6, generation: 4)),
              backlog.dequeue()?.generation == 3,
              backlog.dequeue()?.generation == 4 else { return false }
        backlog.complete(sampleCount: 4)
        backlog.complete(sampleCount: 6)
        return backlog.retainedSampleCount == 0 && backlog.isEmpty
    }

    private static func energyFallbackEdgeChecks() -> (
        noiseRejected: Bool,
        shortSpeechStarted: Bool,
        seededStateClosed: Bool
    ) {
        var noiseDetector = EnergyBoundaryDetector()
        let alternatingNoise: [Float] = (0..<VadManager.chunkSize).map {
            $0.isMultiple(of: 2) ? 0.2 : -0.2
        }
        let noiseBoundary = noiseDetector.process(
            alternatingNoise,
            absoluteStartSample: 0
        )
        let noiseRejected = noiseBoundary == nil
            && noiseDetector.consumeNoiseRejection()

        var speechDetector = EnergyBoundaryDetector()
        let shortBoundary = speechDetector.process(
            Array(repeating: 0.2, count: 2_400),
            absoluteStartSample: 0
        )
        let shortSpeechStarted: Bool
        if case .started = shortBoundary {
            shortSpeechStarted = true
        } else {
            shortSpeechStarted = false
        }

        var seededDetector = EnergyBoundaryDetector()
        seededDetector.seedActive()
        var seededStateClosed = false
        for start in stride(from: 0, through: 8_192, by: 4_096) {
            let boundary = seededDetector.process(
                Array(repeating: 0, count: 4_096),
                absoluteStartSample: start
            )
            if case .ended = boundary {
                seededStateClosed = true
            }
        }
        return (noiseRejected, shortSpeechStarted, seededStateClosed)
    }
}

/// Dev-only: transcribes a real audio file with the production decoding options to
/// verify the output is clean (no "<|...|>" tokens, no repetition loops) without
/// having to record live. Run with:
///   Parrot --transcribe-test <audio.caf> <modelFolder>
enum TranscribeTest {
    static func run(audioPath: String, modelFolder: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let passed = try await execute(audioPath: audioPath, modelFolder: modelFolder)
                if !passed { exit(2) }
            } catch {
                FileHandle.standardError.write(
                    Data("diagnostic=transcribe status=failed error_type=\(String(reflecting: type(of: error)))\n".utf8)
                )
                exit(1)
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func execute(audioPath: String, modelFolder: String) async throws -> Bool {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.isEmpty ? nil : modelFolder,
            verbose: false,
            logLevel: .none,
            load: true,
            download: modelFolder.isEmpty
        )
        let whisperKit = try await WhisperKit(config)

        var options = DecodingOptions(task: .transcribe, language: "en")
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.noSpeechThreshold = 0.6
        options.temperatureFallbackCount = 3

        let decodeStart = Date()
        let results = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: options
        )
        let decodeSeconds = Date.now.timeIntervalSince(decodeStart)
        let text = results.map(\.text).joined(separator: " ")
        let containsSpecialTokens = text.contains("<|")

        print("diagnostic: transcribe")
        print(String(format: "decode_seconds: %.3f", decodeSeconds))
        print("transcript_characters: \(text.count)")
        print("contains_special_tokens: \(containsSpecialTokens ? 1 : 0)")
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !containsSpecialTokens
    }
}

/// Offscreen renderer for the live copilot panel. Run with:
///   Parrot --copilot-snapshot /tmp/copilot.png
/// Renders the redesigned "glanceable" panel with seeded fake state (hero
/// suggestion, pinned blocker, history rows, sentiment chips) in light AND dark
/// (second file gets a "-dark" suffix), so the design can be eyeballed without
/// a live call. Dev-only; never reached in normal launches.
@MainActor
enum CopilotSnapshot {
    static func write(to path: String) {
        let rm = RecordingManager()
        let profile = ProfilePresets.all().first { $0.name == "Sales discovery" }

        // Newest first — index 0 becomes the hero. The unhandled objection is
        // filtered into the pinned zone regardless of position.
        let insights: [Insight] = [
            Insight(kindKey: "suggestion", title: "Answer the security question",
                    detail: "“All audio stays on your Mac — only transcript text goes to the API, and we can sign a DPA this week if that helps.”",
                    callTime: 754, source: "security-faq.pdf"),
            Insight(kindKey: "buying_signal", title: "Asked about onboarding timeline",
                    detail: "They want to know how fast the team could start — a strong intent signal.",
                    callTime: 698, source: nil),
            Insight(kindKey: "next_step", title: "Propose a pilot with the sales pod",
                    detail: "Offer a two-week pilot with the 5-person sales pod they mentioned.",
                    callTime: 645, source: nil),
            Insight(kindKey: "discovery_gap", title: "Budget owner still unknown",
                    detail: "Nobody has said who signs off — worth asking directly.",
                    callTime: 590, source: nil),
            Insight(kindKey: "objection", title: "Worried about switching costs",
                    detail: "They brought up migration effort from their current tool twice.",
                    callTime: 512, source: "onboarding-guide.pdf",
                    reply: "Our team handles the full migration in under a week — the onboarding guide has the exact checklist."),
        ]

        rm.callAnalysisEngine.seedForSnapshot(
            profile: profile,
            insights: insights,
            sentiment: ["buying_temperature": 62, "my_dominance": 55, "score": 68],
            read: "warming",
            coach: "Going well — stop listing features and ask who signs off on budget.",
            meCharacters: 1300, themCharacters: 900
        )

        let panel = CopilotPanelView(transcriptJumpTarget: .constant(nil))
            .environment(rm)
            .frame(width: 420, height: 700)

        let light = render(panel, dark: false, to: path)
        let dark = render(panel, dark: true, to: (path as NSString).deletingPathExtension + "-dark.png")

        // ImageRenderer can't lay out ScrollView contents, so the panel render
        // shows an empty history area — render the rows separately (one
        // expanded) so their design is still verifiable offscreen.
        func kindStyle(_ insight: Insight) -> KindStyle {
            KindResolver.style(forKey: insight.kindKey, profile: profile, snapshot: [])
        }
        let history = VStack(spacing: 6) {
            PinnedBlockerRow(insight: insights[4], startExpanded: true, onHandled: {}, onJump: {})
            InsightCard(insight: insights[1], kindStyle: kindStyle(insights[1]),
                        isCollapsed: true, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[2], kindStyle: kindStyle(insights[2]),
                        isCollapsed: false, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[3], kindStyle: kindStyle(insights[3]),
                        isCollapsed: true, onToggleCollapse: {}, onJump: {}, onDismiss: {})
        }
        .padding(12)
        .frame(width: 420)
        .background(Theme.Colors.panel)
        let rows = render(history, dark: false, to: (path as NSString).deletingPathExtension + "-history.png")

        let legendURL = render(legend(profile: profile), dark: false,
                               to: (path as NSString).deletingPathExtension + "-legend.png")

        // Chat-bubble transcript strip: two speaker groups + the typing bubble.
        let seg: (TimeInterval, String, String) -> TranscriptSegment = { start, speaker, text in
            TranscriptSegment(startTime: start, endTime: start + 4, text: text,
                              speakerLabel: speaker, confidence: nil)
        }
        let bubbleSegments = [
            seg(120, "Them", "So how would the migration from our current tool actually work?"),
            seg(124, "Them", "We have about two years of call history in there."),
            seg(129, "Me", "Great question — we handle the full export and import for you."),
            seg(134, "Me", "Usually it's done within a week, including the archive."),
        ]
        let bubbles = VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(bubbleSegments.enumerated()), id: \.offset) { index, segment in
                ChatBubbleRow(
                    segment: segment,
                    isFirstOfGroup: index == 0
                        || bubbleSegments[index - 1].speakerLabel != segment.speakerLabel
                )
            }
            TypingBubble(text: "That sounds reasonable, and what about")
                .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 380)
        .background(Theme.Colors.panel)
        let bubblesURL = render(bubbles, dark: false,
                                to: (path as NSString).deletingPathExtension + "-bubbles.png")

        FileHandle.standardError.write(Data("copilot-snapshot: wrote \(light.path) + \(dark.path) + \(rows.path) + \(legendURL.path) + \(bubblesURL.path)\n".utf8))
        exit(0)
    }

    // MARK: - Card-system legend

    /// A one-image guide to the live panel: the four zones plus every card kind
    /// of the given profile, drawn with the app's real colors and icons.
    private static func legend(profile: CallProfile?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Parrot Copilot — what each card means")
                .font(Theme.Typography.title(20))
                .foregroundStyle(Theme.Colors.ink)

            Text("PANEL ZONES (top to bottom)")
                .font(Theme.Typography.cap)
                .foregroundStyle(Theme.Colors.ink3)

            legendRow(Theme.Colors.accent, "gauge.with.needle",
                      "Coach card — always on top",
                      "Live verdict: 0–100 call score, one sentence of what to do right now, mood chips, and how many blockers are open.")
            legendRow(Theme.Colors.subtle, "rectangle.inset.filled.top",
                      "Hero card — the big tinted one",
                      "The newest insight, at full size. Glows briefly when it lands. This is the one to glance at.")
            legendRow(.orange, "exclamationmark.triangle.fill",
                      "Orange cards — unresolved",
                      "Objections and questions you haven't dealt with yet. Click to read all of it; ✓ marks it handled — or it clears itself when the call actually resolves it.")
            legendRow(Theme.Colors.ink3, "list.bullet",
                      "EARLIER — the quiet history",
                      "Everything older, one line each. Click any row to expand it.")

            Divider().overlay(Theme.Colors.line)

            Text("CARD KINDS IN THIS PROFILE (\(profile?.name ?? "Default"))")
                .font(Theme.Typography.cap)
                .foregroundStyle(Theme.Colors.ink3)

            ForEach(profile?.kinds ?? [], id: \.id) { kind in
                legendRow(KindResolver.adaptiveColor(forHex: kind.colorHex),
                          kind.iconSystemName, kind.label,
                          legendBlurb(for: kind.key))
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.Colors.canvas)
    }

    private static func legendRow(_ color: Color, _ icon: String,
                                  _ title: String, _ blurb: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(color.opacity(0.16))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                Text(blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Plain-language one-liner per sales-profile kind key (falls back to the
    /// kind's own trigger text for custom kinds).
    private static func legendBlurb(for key: String) -> String {
        switch key {
        case "suggestion": "A line you can literally say, right now. The Copy button puts it on your clipboard."
        case "objection": "They pushed back (price, timing, competitor) and it isn't settled yet. Stays orange until handled."
        case "unanswered_question": "They asked you something and the conversation moved on — circle back to it."
        case "opportunity": "They revealed a pain or goal your offer can solve — how to position it."
        case "buying_signal": "A sign they're interested — the moment to advance the deal."
        case "next_step": "A concrete step to propose or confirm (pilot, follow-up call, intro)."
        case "discovery_gap": "Something important you don't know yet — the card is the question to ask next."
        default: "Custom card defined in this profile's settings."
        }
    }

    private static func render(_ view: some View, dark: Bool, to path: String) -> URL {
        let renderer = ImageRenderer(
            content: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        renderer.scale = 2
        // Theme colors resolve through NSColor(name:) providers, which follow the
        // current *drawing* appearance — set it explicitly per render.
        var cg: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            cg = renderer.cgImage
        }
        guard let cg else {
            FileHandle.standardError.write(Data("copilot-snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        return SnapshotIO.write(data, to: path)
    }
}

/// Shared PNG writer for the snapshot harnesses. The app is sandboxed, so an
/// arbitrary path like /tmp fails — silently, when written with try?. Write,
/// and on denial fall back to the container's temp dir, always returning the
/// URL that actually holds the file.
enum SnapshotIO {
    static func write(_ data: Data, to path: String) -> URL {
        let requested = URL(fileURLWithPath: path)
        do {
            try data.write(to: requested)
            return requested
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(requested.lastPathComponent)
            do {
                try data.write(to: fallback)
                return fallback
            } catch {
                FileHandle.standardError.write(Data("snapshot: write failed — \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}

/// Offscreen renderer for design verification. Run with:
///   Parrot --snapshot /tmp/report.png
/// It renders the post-meeting report exactly as the app does (same views + theme)
/// to a PNG, so the SwiftUI output can be checked against the design mockup without
/// driving the GUI. Dev-only; never reached in normal launches.
@MainActor
enum ReportSnapshot {
    static func write(to path: String) {
        // A faithful slice of the report screen: serif title + meta + the styled
        // report content (the part that was previously a raw-text dump).
        let view = VStack(alignment: .leading, spacing: 0) {
            Text("Parenting coaching session")
                .font(Theme.Typography.title(27))
                .foregroundStyle(Theme.Colors.ink)
            HStack(spacing: 8) {
                metaPill("calendar", "Jun 19, 2026")
                metaPill("clock", "49 min")
                metaPill("person", "NHS Advisor")
            }
            .padding(.top, 12)

            Divider().overlay(Theme.Colors.line).padding(.vertical, 18)

            ReportContentView(summary: sampleSummary, coaching: sampleCoaching, talkPercentMe: 29)
        }
        .frame(width: 600, alignment: .leading)
        .padding(28)
        .background(Theme.Colors.canvas)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        let written = SnapshotIO.write(data, to: path)
        FileHandle.standardError.write(Data("snapshot: wrote \(written.path)\n".utf8))
        exit(0)
    }

    private static func metaPill(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.ink2)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: 7))
    }

    static let sampleSummary = """
    # Post-Call Report

    This was a one-on-one session between a parent and a clinician focused on Alex's ADHD management — emotion recognition, a 12-minute "regulation corner", and selectively ignoring attention-seeking behaviour. The call was productive; the parent committed to several new strategies before the next session on July 10th.

    Key points:
    - Alex's week was generally positive with mild arguments; morning routine improved despite late-night World Cup watching
    - Timeout reframed as a 12-minute "regulation corner" (not punishment)
    - Parent struggles with emotion-naming; clinician modelled how to validate Alex's feelings during disappointment
    - Selective ignoring introduced for attention-seeking behaviours like monster sounds (10–15 minutes max)

    Next steps:
    - Review handouts 20–23 and create a calm-down menu with Alex
    - Practise emotion-naming in calm, positive moments first
    - Confirm online vs in-person for next week before end of workday
    """

    static let sampleCoaching = """
    Call snapshot: Parenting coaching session on managing a child's behaviour — Me spoke 29%, Them 71%. Heavy teaching call with good engagement.

    What went well:
    - Acknowledged gaps in his own skills directly and asked for examples instead of deflecting
    - Strong vulnerability at 19:15 when sharing guilt over raising his voice, which built trust
    - Took notes on handouts and committed to specific follow-ups

    What to improve:
    - Didn't fully grasp praising effort vs naming emotion — could have asked a clarifying question earlier
    - Drifted into a 3-minute tech tangent near the end when time was tight

    Commitments & follow-ups:
    - Read handouts 20, 21, 22, 23 before the next meeting
    - Create a calm-down menu and report back on which skills Alex likes
    """
}
