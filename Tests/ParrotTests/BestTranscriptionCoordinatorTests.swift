import AVFoundation
import XCTest
@testable import Parrot

@MainActor
final class BestTranscriptionCoordinatorTests: XCTestCase {
    private var root: URL!
    private var store: BestTranscriptionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParrotBestCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BestTranscriptionStore(rootDirectory: root.appendingPathComponent("store"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        store = nil
        root = nil
    }

    func testValidCacheReturnsWithoutLoadingOrRunningWhisper() async throws {
        let audio = try makeCAF(name: "system", seconds: 1)
        let request = makeRequest(system: audio)
        let fingerprint = try BestTranscriptionFingerprintBuilder.make(
            tracks: [(.them, audio)],
            modelID: WhisperModelService.fallbackModel,
            pipelineVersion: BestTranscriptionCoordinator.pipelineVersion,
            vocabulary: request.vocabulary
        )
        let cached = BestTranscriptArtifact(
            meetingID: request.meetingID,
            generatedAt: .now,
            modelID: fingerprint.modelID,
            pipelineVersion: fingerprint.pipelineVersion,
            fingerprint: fingerprint,
            alignmentQuality: .estimated,
            warnings: [],
            segments: []
        )
        try await store.saveCompletedArtifact(cached)
        let recognizer = FakeBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )

        let result = try await coordinator.process(request, forceReprocess: false)

        XCTAssertEqual(result, cached)
        let counts = await recognizer.counts()
        XCTAssertEqual(counts.prepare, 0)
        XCTAssertEqual(counts.transcribe, 0)
    }

    func testTwoTracksAreRecognizedSeparatelyAndMergedInTimeOrder() async throws {
        let system = try makeCAF(name: "system", seconds: 1)
        let mic = try makeCAF(name: "mic", seconds: 1)
        let request = makeRequest(system: system, mic: mic)
        let recognizer = FakeBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )

        let result = try await coordinator.process(request, forceReprocess: false)

        let counts = await recognizer.counts()
        XCTAssertEqual(counts.prepare, 1)
        XCTAssertEqual(counts.transcribe, 2)
        XCTAssertEqual(result.segments.map(\.speaker), [.them, .me])
        XCTAssertEqual(result.segments.map(\.text), ["Them window", "Me window"])
        let reloaded = try await store.loadCompletedArtifact(
            meetingID: request.meetingID,
            fingerprint: result.fingerprint
        )
        XCTAssertEqual(reloaded, result)
    }

    func testLongTrackBatchesWindowsAndKeepsSegmentOrder() async throws {
        let audio = try makeCAF(name: "batched-system", seconds: 65)
        let request = makeRequest(system: audio)
        let recognizer = BatchTrackingBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )

        let artifact = try await coordinator.process(request, forceReprocess: false)

        let batchSizes = await recognizer.batchSizes()
        XCTAssertEqual(batchSizes, [3])
        XCTAssertEqual(artifact.segments.count, 3)
        XCTAssertEqual(
            artifact.segments.map(\.startTime),
            [1.1, 29.1, 57.1]
        )
        let reloaded = try await store.loadCompletedArtifact(
            meetingID: request.meetingID,
            fingerprint: artifact.fingerprint
        )
        XCTAssertEqual(reloaded, artifact)
    }

    func testPreciseTimelineOffsetsTracksAndMarksAlignmentExact() async throws {
        let system = try makeCAF(name: "timeline-system", seconds: 1)
        let mic = try makeCAF(name: "timeline-mic", seconds: 1)
        var request = makeRequest(system: system, mic: mic)
        request.timeline = AudioTimelineManifest(
            schemaVersion: AudioTimelineManifest.schemaVersion,
            capturedAt: .now,
            tracks: [
                .init(
                    speaker: .them,
                    startOffset: 0.15,
                    frameCount: 16_000,
                    sampleRate: 16_000,
                    droppedFrameRanges: []
                ),
                .init(
                    speaker: .me,
                    startOffset: 0.55,
                    frameCount: 16_000,
                    sampleRate: 16_000,
                    droppedFrameRanges: []
                ),
            ]
        )
        let coordinator = BestTranscriptionCoordinator(
            recognizer: FakeBestWhisperRecognizer(),
            store: store
        )

        let result = try await coordinator.process(request, forceReprocess: false)

        XCTAssertEqual(result.alignmentQuality, .exact)
        XCTAssertEqual(result.segments[0].startTime, 0.25, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].startTime, 0.65, accuracy: 0.001)
    }

    func testResumeUsesCommittedCheckpointInsteadOfRepeatingWindow() async throws {
        let audio = try makeCAF(name: "long-system", seconds: 35)
        let request = makeRequest(system: audio)
        let fingerprint = try BestTranscriptionFingerprintBuilder.make(
            tracks: [(.them, audio)],
            modelID: WhisperModelService.fallbackModel,
            pipelineVersion: BestTranscriptionCoordinator.pipelineVersion,
            vocabulary: request.vocabulary
        )
        let windows = BestAudioWindowPlanner.plan(
            totalFrames: 35 * 16_000,
            sampleRate: 16_000
        )
        let committed = BestTranscriptSegment(
            id: UUID(),
            speaker: .them,
            startTime: 0.1,
            endTime: 0.8,
            text: "Already committed",
            confidence: 0.9,
            detectedLanguage: "en",
            words: []
        )
        try await store.saveCheckpoint(
            .init(
                meetingID: request.meetingID,
                fingerprint: fingerprint,
                speaker: .them,
                window: windows[0],
                segments: [committed]
            )
        )
        try await store.saveJobManifest(
            .init(
                schemaVersion: BestTranscriptionManifest.schemaVersion,
                meetingID: request.meetingID,
                state: .interrupted,
                fingerprint: fingerprint,
                artifactFilename: nil,
                updatedAt: .now,
                lastError: nil
            )
        )
        let recognizer = FakeBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )

        let result = try await coordinator.process(request, forceReprocess: false)

        let counts = await recognizer.counts()
        XCTAssertEqual(counts.transcribe, 1)
        XCTAssertTrue(result.segments.contains { $0.text == "Already committed" })
        XCTAssertTrue(result.segments.contains { $0.text == "Them window" })
    }

    func testNoUsableAudioFailsWithoutPreparingModel() async {
        let request = makeRequest(system: nil, mic: nil)
        let recognizer = FakeBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )

        do {
            _ = try await coordinator.process(request, forceReprocess: false)
            XCTFail("Expected missing audio to fail")
        } catch {
            XCTAssertEqual(
                (error as? BestTranscriptionError)?.errorDescription,
                "Recording audio is missing."
            )
        }
        let counts = await recognizer.counts()
        XCTAssertEqual(counts.prepare, 0)
    }

    func testCompletedArtifactStillExportsWhenOriginalAudioWasRemoved() async throws {
        let request = makeRequest(system: nil, mic: nil)
        let fingerprint = BestTranscriptionFingerprint(
            modelID: WhisperModelService.fallbackModel,
            pipelineVersion: BestTranscriptionCoordinator.pipelineVersion,
            vocabularyHash: "old",
            tracks: []
        )
        let cached = BestTranscriptArtifact(
            meetingID: request.meetingID,
            generatedAt: .now,
            modelID: fingerprint.modelID,
            pipelineVersion: fingerprint.pipelineVersion,
            fingerprint: fingerprint,
            alignmentQuality: .estimated,
            warnings: ["Original audio is no longer available."],
            segments: []
        )
        try await store.saveCompletedArtifact(cached)
        let recognizer = FakeBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )

        let result = try await coordinator.process(request, forceReprocess: false)

        XCTAssertEqual(result, cached)
        let counts = await recognizer.counts()
        XCTAssertEqual(counts.prepare, 0)
    }

    func testDamagedExpectedTrackRequiresExplicitPartialExportConsent() async throws {
        let system = try makeCAF(name: "system-valid", seconds: 1)
        let damagedMic = root.appendingPathComponent("mic-damaged.caf")
        try Data().write(to: damagedMic)
        var request = makeRequest(system: system, mic: damagedMic)
        let recognizer = FakeBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )

        do {
            _ = try await coordinator.process(request, forceReprocess: false)
            XCTFail("Expected explicit consent before partial export")
        } catch {
            XCTAssertEqual(
                error as? BestTranscriptionError,
                .damagedAudioAvailable(["Microphone audio could not be read."])
            )
        }
        var counts = await recognizer.counts()
        XCTAssertEqual(counts.prepare, 0)
        XCTAssertEqual(counts.transcribe, 0)

        request.allowPartialDamagedTracks = true
        let artifact = try await coordinator.process(
            request,
            forceReprocess: false
        )

        counts = await recognizer.counts()
        XCTAssertEqual(counts.transcribe, 1)
        XCTAssertEqual(artifact.segments.map(\.speaker), [.them])
        XCTAssertTrue(
            artifact.warnings.contains("Microphone audio could not be read.")
        )
    }

    func testRecordingPauseFinishesCurrentCheckpointAndResumeDoesNotRepeatIt() async throws {
        let audio = try makeCAF(name: "pause-system", seconds: 35)
        let request = makeRequest(system: audio)
        let recognizer = SlowBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )
        let completion = expectation(description: "resumed job completes")
        var finalResult: Result<BestTranscriptArtifact, Error>?
        coordinator.startOrResume(request) { result in
            finalResult = result
            completion.fulfill()
        }

        let started = await waitUntil { await recognizer.transcribeCalls() > 0 }
        XCTAssertTrue(started)
        await coordinator.pauseForRecording()

        let pausedCalls = await recognizer.transcribeCalls()
        XCTAssertEqual(pausedCalls, 1)
        XCTAssertEqual(coordinator.progress(for: request.meetingID).stage, .interrupted)

        coordinator.resumeAfterRecording()
        await fulfillment(of: [completion], timeout: 3)

        XCTAssertNotNil(try finalResult?.get())
        let completedCalls = await recognizer.transcribeCalls()
        XCTAssertEqual(completedCalls, 2)
    }

    func testRecordingPauseCommitsWholeBatchBeforeResuming() async throws {
        let audio = try makeCAF(name: "batch-pause-system", seconds: 65)
        let request = makeRequest(system: audio)
        let recognizer = BatchTrackingBestWhisperRecognizer(delayMilliseconds: 100)
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )
        let completion = expectation(description: "batched job resumes")
        var finalResult: Result<BestTranscriptArtifact, Error>?
        coordinator.startOrResume(request) { result in
            finalResult = result
            completion.fulfill()
        }

        let started = await waitUntil { !(await recognizer.batchSizes()).isEmpty }
        XCTAssertTrue(started)
        await coordinator.pauseForRecording()
        XCTAssertEqual(coordinator.progress(for: request.meetingID).stage, .interrupted)

        coordinator.resumeAfterRecording()
        await fulfillment(of: [completion], timeout: 3)

        let artifact = try XCTUnwrap(finalResult).get()
        XCTAssertEqual(artifact.segments.count, 3)
        let batchSizes = await recognizer.batchSizes()
        XCTAssertEqual(batchSizes, [3])
    }

    func testDoubleClickSharesOneJobAndNotifiesBothCallers() async throws {
        let audio = try makeCAF(name: "double-click-system", seconds: 1)
        let request = makeRequest(system: audio)
        let recognizer = SlowBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )
        let first = expectation(description: "first caller")
        let second = expectation(description: "second caller")

        coordinator.startOrResume(request) { _ in first.fulfill() }
        coordinator.startOrResume(request) { _ in second.fulfill() }

        await fulfillment(of: [first, second], timeout: 3)
        let calls = await recognizer.transcribeCalls()
        XCTAssertEqual(calls, 1)
    }

    func testDifferentMeetingsNeverRunHeavyWhisperWindowsConcurrently() async throws {
        let firstAudio = try makeCAF(name: "queue-first", seconds: 1)
        let secondAudio = try makeCAF(name: "queue-second", seconds: 1)
        let recognizer = ConcurrencyTrackingBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(
            recognizer: recognizer,
            store: store
        )
        let first = expectation(description: "first meeting")
        let second = expectation(description: "second meeting")

        coordinator.startOrResume(makeRequest(system: firstAudio)) { _ in
            first.fulfill()
        }
        coordinator.startOrResume(makeRequest(system: secondAudio)) { _ in
            second.fulfill()
        }

        await fulfillment(of: [first, second], timeout: 3)
        let maximumConcurrency = await recognizer.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testPauseReturnsBeforeUncooperativeBatchAndPersistsItsCheckpoints() async throws {
        let audio = try makeCAF(name: "controlled-batch", seconds: 65)
        let request = makeRequest(system: audio)
        let recognizer = ControlledBestWhisperRecognizer(batchSize: 3)
        let coordinator = BestTranscriptionCoordinator(recognizer: recognizer, store: store)
        var completionCount = 0
        coordinator.startOrResume(request) { _ in completionCount += 1 }
        let started = await waitUntil { await recognizer.counts().batches == [3] }
        XCTAssertTrue(started)

        let clock = ContinuousClock()
        let start = clock.now
        await coordinator.pauseForRecording()

        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(100))
        XCTAssertTrue(coordinator.hasRunningJobs, "The draining model task must stay owned")
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(coordinator.progress(for: request.meetingID).stage, .interrupted)

        await recognizer.releaseBatch()
        let drained = await waitUntil { !coordinator.hasRunningJobs }
        XCTAssertTrue(drained)
        XCTAssertEqual(completionCount, 0, "Pause must not deliver a late completed artifact")
        XCTAssertEqual(coordinator.progress(for: request.meetingID).stage, .interrupted)
        let savedManifest = await store.loadJobManifest(meetingID: request.meetingID)
        let manifest = try XCTUnwrap(savedManifest)
        let checkpoints = try await store.loadCheckpoints(
            meetingID: request.meetingID,
            fingerprint: manifest.fingerprint
        )
        XCTAssertEqual(manifest.state, .interrupted)
        XCTAssertEqual(checkpoints.map(\.window.index), [0, 1, 2])
        XCTAssertEqual(checkpoints.flatMap(\.segments).count, 3)

        coordinator.resumeAfterRecording()
        let completed = await waitUntil { completionCount == 1 }
        XCTAssertTrue(completed)
        let counts = await recognizer.counts()
        XCTAssertEqual(counts.batches, [3], "Resume must reuse every saved window")
        XCTAssertEqual(coordinator.progress(for: request.meetingID).stage, .ready)
    }

    func testRapidResumeWaitsForOldBatchWithoutLaunchingDuplicateInference() async throws {
        let audio = try makeCAF(name: "rapid-resume", seconds: 35)
        let request = makeRequest(system: audio)
        let recognizer = ControlledBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(recognizer: recognizer, store: store)
        let completion = expectation(description: "rapidly resumed meeting")
        coordinator.startOrResume(request) { result in
            XCTAssertNotNil(try? result.get())
            completion.fulfill()
        }
        let started = await waitUntil { await recognizer.counts().batches == [1] }
        XCTAssertTrue(started)

        for _ in 0..<3 {
            await coordinator.pauseForRecording()
            coordinator.resumeAfterRecording()
        }
        let beforeRelease = await recognizer.counts()
        XCTAssertEqual(beforeRelease.prepare, 1)
        XCTAssertEqual(beforeRelease.batches, [1])
        XCTAssertTrue(coordinator.hasRunningJobs)

        await recognizer.releaseBatch()
        await fulfillment(of: [completion], timeout: 3)
        let afterRelease = await recognizer.counts()
        XCTAssertEqual(afterRelease.starts, [[0], [28]])
        XCTAssertEqual(afterRelease.maximumConcurrency, 1)
        XCTAssertFalse(coordinator.hasRunningJobs)
    }

    func testQueuedAndNewRequestsDoNotPrepareOrTranscribeWhileRecording() async throws {
        let firstAudio = try makeCAF(name: "paused-active", seconds: 1)
        let secondAudio = try makeCAF(name: "paused-queued", seconds: 1)
        let thirdAudio = try makeCAF(name: "paused-new", seconds: 1)
        let recognizer = ControlledBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(recognizer: recognizer, store: store)
        let completed = expectation(description: "all queued meetings")
        completed.expectedFulfillmentCount = 4
        coordinator.startOrResume(makeRequest(system: firstAudio)) { _ in completed.fulfill() }
        let started = await waitUntil { await recognizer.counts().batches == [1] }
        XCTAssertTrue(started)
        coordinator.startOrResume(makeRequest(system: secondAudio)) { _ in completed.fulfill() }

        await coordinator.pauseForRecording()
        let third = makeRequest(system: thirdAudio)
        coordinator.startOrResume(third) { _ in completed.fulfill() }
        coordinator.startOrResume(third) { _ in completed.fulfill() }
        await recognizer.releaseBatch()
        let drained = await waitUntil { !coordinator.hasRunningJobs }
        XCTAssertTrue(drained)
        let pausedCounts = await recognizer.counts()
        XCTAssertEqual(pausedCounts.prepare, 1)
        XCTAssertEqual(pausedCounts.batches, [1])
        XCTAssertEqual(coordinator.progress(for: third.meetingID).stage, .interrupted)

        coordinator.resumeAfterRecording()
        await fulfillment(of: [completed], timeout: 3)
        let resumedCounts = await recognizer.counts()
        XCTAssertEqual(resumedCounts.batches, [1, 1, 1])
        XCTAssertEqual(resumedCounts.maximumConcurrency, 1)
    }

    func testCancellingQueuedRequestDoesNotWaitForUnrelatedUncooperativeBatch() async throws {
        let audio = try makeCAF(name: "cancel-queued", seconds: 1)
        let active = makeRequest(system: audio)
        let queued = makeRequest(system: audio)
        let recognizer = ControlledBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(recognizer: recognizer, store: store)
        let activeCompleted = expectation(description: "active request finishes")
        coordinator.startOrResume(active) { _ in activeCompleted.fulfill() }
        let started = await waitUntil { await recognizer.counts().batches == [1] }
        XCTAssertTrue(started)
        var queuedResult: Result<BestTranscriptArtifact, Error>?
        coordinator.startOrResume(queued) { queuedResult = $0 }
        // Let the queued task enter the cancellation-aware gate.
        await Task.yield()

        coordinator.cancel(meetingID: queued.meetingID)
        let cancelled = await waitUntil { queuedResult != nil }
        XCTAssertTrue(cancelled, "Queued cancellation must not await another model's result")
        if case let .failure(error)? = queuedResult {
            XCTAssertEqual(error as? BestTranscriptionError, .cancelled)
        } else {
            XCTFail("Expected the queued request to be cancelled")
        }
        let counts = await recognizer.counts()
        XCTAssertEqual(counts.prepare, 1)
        await recognizer.releaseBatch()
        await fulfillment(of: [activeCompleted], timeout: 3)
        XCTAssertFalse(coordinator.hasRunningJobs)
    }

    func testPauseDuringPreparationDoesNotLaunchInferenceWhenPreparationReturns() async throws {
        let audio = try makeCAF(name: "pause-prepare", seconds: 1)
        let request = makeRequest(system: audio)
        let recognizer = ControlledBestWhisperRecognizer(holdPreparation: true)
        let coordinator = BestTranscriptionCoordinator(recognizer: recognizer, store: store)
        let completion = expectation(description: "preparation resumes")
        coordinator.startOrResume(request) { _ in completion.fulfill() }
        let started = await waitUntil { await recognizer.counts().prepare == 1 }
        XCTAssertTrue(started)

        await coordinator.pauseForRecording()
        await recognizer.releasePreparation()
        let drained = await waitUntil { !coordinator.hasRunningJobs }
        XCTAssertTrue(drained)
        let paused = await recognizer.counts()
        XCTAssertTrue(paused.batches.isEmpty)
        await recognizer.releaseBatch()
        coordinator.resumeAfterRecording()
        await fulfillment(of: [completion], timeout: 3)
        let resumed = await recognizer.counts()
        XCTAssertEqual(resumed.batches, [1])
    }

    func testForcedReprocessResumesNewCheckpointInsteadOfResettingItAgain() async throws {
        let audio = try makeCAF(name: "force-pause", seconds: 35)
        let request = makeRequest(system: audio)
        let recognizer = ControlledBestWhisperRecognizer()
        let coordinator = BestTranscriptionCoordinator(recognizer: recognizer, store: store)
        let completion = expectation(description: "forced reprocess resumes")
        coordinator.reprocess(request) { _ in completion.fulfill() }
        let started = await waitUntil { await recognizer.counts().batches == [1] }
        XCTAssertTrue(started)

        await coordinator.pauseForRecording()
        await recognizer.releaseBatch()
        let drained = await waitUntil { !coordinator.hasRunningJobs }
        XCTAssertTrue(drained)
        coordinator.resumeAfterRecording()
        await fulfillment(of: [completion], timeout: 3)
        let counts = await recognizer.counts()
        XCTAssertEqual(counts.starts, [[0], [28]], "Reprocess checkpoints must be retained")
    }

    private func waitUntil(
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func makeRequest(
        system: URL?,
        mic: URL? = nil
    ) -> BestTranscriptionRequest {
        .init(
            meetingID: UUID(),
            title: "Test meeting",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 35,
            systemAudioURL: system,
            micAudioURL: mic,
            vocabulary: "Parrot",
            timeline: nil
        )
    }

    private func makeCAF(name: String, seconds: Int) throws -> URL {
        let url = root.appendingPathComponent("\(name).caf")
        let count = seconds * 16_000
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(count)
        )!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.03) * 0.1)
        }
        try file.write(from: buffer)
        return url
    }
}

private actor FakeBestWhisperRecognizer: BestWhisperRecognizing {
    private(set) var prepareCount = 0
    private(set) var transcribeCount = 0

    func prepareLocalOnly(modelName: String) async throws {
        prepareCount += 1
    }

    func transcribeWindow(
        samples: [Float],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        vocabulary: String
    ) async throws -> [BestTranscriptSegment] {
        transcribeCount += 1
        let localStart: TimeInterval = absoluteWindowStart > 0 ? 1.1 : 0.1
        return [
            BestTranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: absoluteWindowStart + localStart,
                endTime: absoluteWindowStart + localStart + 0.7,
                text: "\(speaker.rawValue) window",
                confidence: 0.9,
                detectedLanguage: "en",
                words: []
            ),
        ]
    }

    func counts() -> (prepare: Int, transcribe: Int) {
        (prepareCount, transcribeCount)
    }
}

private actor SlowBestWhisperRecognizer: BestWhisperRecognizing {
    private var callCount = 0

    func prepareLocalOnly(modelName: String) async throws {}

    func transcribeWindow(
        samples: [Float],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        vocabulary: String
    ) async throws -> [BestTranscriptSegment] {
        callCount += 1
        try await Task.sleep(for: .milliseconds(100))
        return [
            BestTranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: absoluteWindowStart + 0.1,
                endTime: absoluteWindowStart + 0.8,
                text: "checkpoint \(callCount)",
                confidence: 0.9,
                detectedLanguage: "en",
                words: []
            ),
        ]
    }

    func transcribeCalls() -> Int {
        callCount
    }
}

private actor ConcurrencyTrackingBestWhisperRecognizer: BestWhisperRecognizing {
    private var active = 0
    private var maximum = 0

    func prepareLocalOnly(modelName: String) async throws {}

    func transcribeWindow(
        samples: [Float],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        vocabulary: String
    ) async throws -> [BestTranscriptSegment] {
        active += 1
        maximum = max(maximum, active)
        try await Task.sleep(for: .milliseconds(100))
        active -= 1
        return [
            BestTranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: absoluteWindowStart + 0.1,
                endTime: absoluteWindowStart + 0.8,
                text: "queued",
                confidence: 0.9,
                detectedLanguage: "en",
                words: []
            ),
        ]
    }

    func maximumConcurrency() -> Int {
        maximum
    }
}

private actor BatchTrackingBestWhisperRecognizer: BestWhisperRecognizing {
    nonisolated var preferredWindowBatchSize: Int { 3 }
    private let delayMilliseconds: Int
    private var recordedBatchSizes: [Int] = []

    init(delayMilliseconds: Int = 0) {
        self.delayMilliseconds = delayMilliseconds
    }

    func prepareLocalOnly(modelName: String) async throws {}

    func transcribeWindow(
        samples: [Float],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        vocabulary: String
    ) async throws -> [BestTranscriptSegment] {
        XCTFail("Coordinator should use the batch entry point")
        return []
    }

    func transcribeWindows(
        _ windows: [BestWhisperWindowInput],
        vocabulary: String
    ) async throws -> [[BestTranscriptSegment]] {
        recordedBatchSizes.append(windows.count)
        if delayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        return windows.map { window in
            [BestTranscriptSegment(
                id: UUID(),
                speaker: window.speaker,
                startTime: window.absoluteWindowStart + 1.1,
                endTime: window.absoluteWindowStart + 1.8,
                text: "Window \(window.absoluteWindowStart)",
                confidence: 0.9,
                detectedLanguage: "en",
                words: []
            )]
        }
    }

    func batchSizes() -> [Int] {
        recordedBatchSizes
    }
}

/// Deliberately ignores cancellation while its first operation is held. Tests
/// release it explicitly, proving that recording pause never waits for it or
/// drops ownership of its lifetime.
private actor ControlledBestWhisperRecognizer: BestWhisperRecognizing {
    nonisolated let preferredWindowBatchSize: Int
    private var holdsPreparation: Bool
    private var holdsBatch = true
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private var batchContinuation: CheckedContinuation<Void, Never>?
    private var prepareCount = 0
    private var starts: [[TimeInterval]] = []
    private var active = 0
    private var maximum = 0

    init(batchSize: Int = 1, holdPreparation: Bool = false) {
        preferredWindowBatchSize = batchSize
        holdsPreparation = holdPreparation
    }

    func prepareLocalOnly(modelName: String) async throws {
        prepareCount += 1
        if holdsPreparation {
            await withCheckedContinuation { preparationContinuation = $0 }
        }
    }

    func transcribeWindow(
        samples: [Float],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        vocabulary: String
    ) async throws -> [BestTranscriptSegment] {
        try await transcribeWindows(
            [.init(samples: samples, speaker: speaker, absoluteWindowStart: absoluteWindowStart)],
            vocabulary: vocabulary
        )[0]
    }

    func transcribeWindows(
        _ windows: [BestWhisperWindowInput],
        vocabulary: String
    ) async throws -> [[BestTranscriptSegment]] {
        starts.append(windows.map(\.absoluteWindowStart))
        active += 1
        maximum = max(maximum, active)
        if holdsBatch {
            await withCheckedContinuation { batchContinuation = $0 }
        }
        active -= 1
        return windows.map { window in
            let offset = window.absoluteWindowStart > 0 ? 1.1 : 0.1
            return [BestTranscriptSegment(
                id: UUID(),
                speaker: window.speaker,
                startTime: window.absoluteWindowStart + offset,
                endTime: window.absoluteWindowStart + offset + 0.7,
                text: "controlled \(window.absoluteWindowStart)",
                confidence: 0.9,
                detectedLanguage: "en",
                words: []
            )]
        }
    }

    func releasePreparation() {
        holdsPreparation = false
        preparationContinuation?.resume()
        preparationContinuation = nil
    }

    func releaseBatch() {
        holdsBatch = false
        batchContinuation?.resume()
        batchContinuation = nil
    }

    func counts() -> (
        prepare: Int,
        batches: [Int],
        starts: [[TimeInterval]],
        maximumConcurrency: Int
    ) {
        (prepareCount, starts.map(\.count), starts, maximum)
    }
}
