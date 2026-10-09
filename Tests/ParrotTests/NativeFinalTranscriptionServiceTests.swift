import AVFoundation
import Darwin
import XCTest
@testable import Parrot

@MainActor
final class NativeFinalTranscriptionServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ParrotNativeASRTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testRequestAndRealWAVPreserveSourceWithoutInventingAlignment() async throws {
        let worker = FakeNativeASRTransport()
        let service = makeService(worker)
        let result = try await service.transcribeWindow(
            samples: samples, speaker: .me, absoluteWindowStart: 35,
            vocabulary: "Nikita, Parrot\nWarsaw"
        )
        let observed = await worker.observed()
        XCTAssertEqual(observed.starts, 1)
        XCTAssertEqual(observed.vocabulary, "Nikita, Parrot\nWarsaw")
        XCTAssertTrue(observed.languageWasNull)
        XCTAssertEqual(observed.maxTokens, 2048)
        XCTAssertEqual(observed.sampleRate, 16_000)
        XCTAssertEqual(observed.channels, 1)
        XCTAssertEqual(observed.frames, 16_000)
        XCTAssertEqual(result.map(\.speaker), [.me])
        XCTAssertEqual(result.map(\.startTime), [35])
        XCTAssertEqual(result.map(\.endTime), [36])
        XCTAssertTrue(result.allSatisfy { $0.words.isEmpty && $0.confidence == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(observed.paths.first)))
        XCTAssertEqual(service.modelIdentity, "qwen-test-revision-q4")
        XCTAssertEqual(service.preferredWindowBatchSize, 1)
        XCTAssertEqual(service.windowOverlapSeconds, 0)
        XCTAssertFalse(service.hasWordAlignment)
        try await service.shutdown()
        let running = await service.hasRunningWorker
        XCTAssertFalse(running)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testPreparationReusesOneWorkerAndWindowsRemainSerial() async throws {
        let worker = FakeNativeASRTransport()
        let service = makeService(worker)
        try await service.prepareLocalOnly(modelName: "catalog-identity")
        let result = try await service.transcribeWindows(
            [
                .init(samples: samples, speaker: .them, absoluteWindowStart: 0),
                .init(samples: samples, speaker: .me, absoluteWindowStart: 30),
            ], vocabulary: ""
        )
        XCTAssertEqual(result.map { $0.map(\.startTime) }, [[0], [30]])
        XCTAssertEqual(result.map { $0.map(\.speaker) }, [[.them], [.me]])
        let observed = await worker.observed()
        XCTAssertEqual(observed.starts, 1)
        XCTAssertEqual(observed.requests, 2)
        XCTAssertEqual(observed.maximumRequests, 1)
        try await service.shutdown()
    }

    func testPauseCancelsBlockedInferenceCleansAudioAndResumesFreshWorker() async throws {
        let worker = FakeNativeASRTransport(holdResponses: true)
        let service = makeService(worker)
        let task = Task { try await transcribe(service) }
        let started = await waitUntil { await worker.observed().requests == 1 }
        XCTAssertTrue(started)
        let beforePause = await worker.observed()
        let path = try XCTUnwrap(beforePause.paths.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let start = ContinuousClock.now
        try await service.pauseForRecording()
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .milliseconds(100))
        do { _ = try await task.value; XCTFail("Expected recording interruption") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let stopped = await worker.observed()
        XCTAssertEqual(stopped.stops, 1)
        let running = await service.hasRunningWorker
        XCTAssertFalse(running)
        do { _ = try await transcribe(service); XCTFail("Paused service must not launch work") }
        catch { XCTAssertTrue(error is CancellationError) }
        let paused = await worker.observed()
        XCTAssertEqual(paused.starts, 1)
        await worker.releaseResponses()
        await service.resumeAfterRecording()
        let resumedResult = try await transcribe(service)
        XCTAssertEqual(resumedResult.count, 1)
        let resumed = await worker.observed()
        XCTAssertEqual(resumed.starts, 2)
        try await service.shutdown()
    }

    func testTaskCancellationStopsItsWorkerAndRemovesOwnedAudio() async throws {
        let worker = FakeNativeASRTransport(holdResponses: true)
        let service = makeService(worker)
        let task = Task { try await transcribe(service) }
        let started = await waitUntil { await worker.observed().requests == 1 }
        XCTAssertTrue(started)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let observed = await worker.observed()
        XCTAssertEqual(observed.stops, 1)
        XCTAssertTrue(observed.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        let running = await service.hasRunningWorker
        XCTAssertFalse(running)
    }

    func testRapidResumeWaitsForVerifiedOldShutdownBeforeStartingReplacement() async throws {
        let worker = FakeNativeASRTransport(holdResponses: true, holdStop: true)
        let service = makeService(worker)
        let original = Task { try await transcribe(service) }
        let started = await waitUntil { await worker.observed().requests == 1 }
        XCTAssertTrue(started)
        let pause = Task { try await service.pauseForRecording() }
        let stopping = await waitUntil { await worker.observed().stops == 1 }
        XCTAssertTrue(stopping)
        await service.resumeAfterRecording()
        await worker.releaseResponses()
        let replacement = Task { try await transcribe(service) }
        await Task.yield()
        let beforeExit = await worker.observed()
        XCTAssertEqual(beforeExit.starts, 1)
        let owned = await service.hasRunningWorker
        XCTAssertTrue(owned)
        await worker.releaseStop()
        try await pause.value
        do { _ = try await original.value; XCTFail("Old generation must stay cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let fresh = try await replacement.value
        XCTAssertEqual(fresh.count, 1)
        let afterExit = await worker.observed()
        XCTAssertEqual(afterExit.starts, 2)
        try await service.shutdown()
    }

    func testMemoryAdmissionBlocksOnlyColdWorkerLaunch() async throws {
        let worker = FakeNativeASRTransport()
        let admission = NativeTestAdmission(false)
        let service = makeService(worker, startupAdmission: { admission.allowed })
        do { try await service.prepareLocalOnly(modelName: "test"); XCTFail("Cold launch must be blocked") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .memoryUnavailable) }
        let denied = await worker.observed()
        XCTAssertEqual(denied.starts, 0)
        admission.set(true)
        try await service.prepareLocalOnly(modelName: "test")
        admission.set(false)
        let warm = try await transcribe(service)
        XCTAssertEqual(warm.count, 1)
        let reused = await worker.observed()
        XCTAssertEqual(reused.starts, 1)
        try await service.shutdown()
        do { try await service.prepareLocalOnly(modelName: "test"); XCTFail("Next cold launch must also be blocked") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .memoryUnavailable) }
        let stillDenied = await worker.observed()
        XCTAssertEqual(stillDenied.starts, 1)
    }

    func testQueuedCancellationDoesNotStopAnotherActiveRequest() async throws {
        let worker = FakeNativeASRTransport(holdResponses: true)
        let service = makeService(worker)
        let first = Task { try await transcribe(service) }
        let started = await waitUntil { await worker.observed().requests == 1 }
        XCTAssertTrue(started)
        let queued = Task { try await transcribe(service) }
        await Task.yield()
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected queued cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let observed = await worker.observed()
        XCTAssertEqual(observed.stops, 0)
        XCTAssertEqual(observed.requests, 1)
        await worker.releaseResponses()
        let result = try await first.value
        XCTAssertEqual(result.count, 1)
        try await service.shutdown()
    }

    func testTimeoutsStopTransportInsteadOfLeavingModelWorkBehind() async throws {
        let cold = FakeNativeASRTransport(holdReady: true)
        let coldService = makeService(cold, timeout: .milliseconds(40))
        do { try await coldService.prepareLocalOnly(modelName: "test"); XCTFail("Expected startup timeout") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .startupTimeout) }
        let coldObserved = await cold.observed()
        XCTAssertEqual(coldObserved.stops, 1)
        let coldRunning = await coldService.hasRunningWorker
        XCTAssertFalse(coldRunning)
        let stalled = FakeNativeASRTransport(holdResponses: true)
        let stalledService = makeService(stalled, timeout: .milliseconds(40))
        do { _ = try await transcribe(stalledService); XCTFail("Expected inference timeout") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .inferenceTimeout) }
        let stalledObserved = await stalled.observed()
        XCTAssertEqual(stalledObserved.stops, 1)
        XCTAssertTrue(stalledObserved.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        let stalledRunning = await stalledService.hasRunningWorker
        XCTAssertFalse(stalledRunning)
    }

    func testMismatchedIDAndWorkerErrorStopWorkerAndDoNotExposePrivateText() async throws {
        let mismatch = FakeNativeASRTransport(mode: .mismatchedID)
        let mismatchService = makeService(mismatch)
        do { _ = try await transcribe(mismatchService); XCTFail("Expected mismatched request") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .invalidResponse) }
        let mismatched = await mismatch.observed()
        XCTAssertEqual(mismatched.stops, 1)
        let failure = FakeNativeASRTransport(mode: .failure)
        let failedService = makeService(failure)
        do { _ = try await transcribe(failedService); XCTFail("Expected worker failure") }
        catch {
            XCTAssertEqual(error as? NativeFinalASRError, .workerFailed)
            XCTAssertFalse(error.localizedDescription.contains("private transcript"))
        }
        let failed = await failure.observed()
        XCTAssertEqual(failed.stops, 1)
    }

    func testFailedTerminationRemainsOwnedAndBlocksReplacementUntilVerifiedStop() async throws {
        let worker = FakeNativeASRTransport(failedStops: 2)
        let service = makeService(worker)
        try await service.prepareLocalOnly(modelName: "test")
        do { try await service.pauseForRecording(); XCTFail("Expected stop failure") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .terminationFailed) }
        let retained = await service.hasRunningWorker
        XCTAssertTrue(retained)
        await service.resumeAfterRecording()
        do { try await service.prepareLocalOnly(modelName: "test"); XCTFail("Replacement must stay blocked") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .terminationFailed) }
        let beforeRetry = await worker.observed()
        XCTAssertEqual(beforeRetry.starts, 1)
        try await service.shutdown()
        let stopped = await service.hasRunningWorker
        XCTAssertFalse(stopped)
    }

    func testIdleWorkerUnloadsBeforeAnotherRequestStartsFresh() async throws {
        let worker = FakeNativeASRTransport()
        let service = makeService(worker, idle: .milliseconds(30))
        _ = try await transcribe(service)
        let unloaded = await waitUntil { await worker.observed().stops == 1 }
        XCTAssertTrue(unloaded)
        let noWorker = await service.hasRunningWorker
        XCTAssertFalse(noWorker)
        _ = try await transcribe(service)
        let restarted = await worker.observed()
        XCTAssertEqual(restarted.starts, 2)
        try await service.shutdown()
    }

    func testNonfiniteAudioIsRejectedBeforeWorkerLaunch() async throws {
        let worker = FakeNativeASRTransport()
        let service = makeService(worker)
        do {
            _ = try await service.transcribeWindow(
                samples: [.nan], speaker: .me, absoluteWindowStart: 0, vocabulary: ""
            )
            XCTFail("Invalid audio must not enter model")
        } catch { XCTAssertEqual(error as? NativeFinalASRError, .invalidInput) }
        let observed = await worker.observed()
        XCTAssertEqual(observed.starts, 0)
    }

    func testMapperClipsRangesFiltersTokensAndPreservesSourceWithoutWordTimes() throws {
        let response = NativeASRWireResult(
            id: "x", text: "First Second", language: "ru",
            segments: [
                .init(start: 0.8, end: 2, text: "Second<|eos|>", speaker: "speaker_3"),
                .init(start: -0.2, end: 0.5, text: " <s>First</s> ", speaker: "speaker_1"),
                .init(start: 0.4, end: 0.2, text: "invalid", speaker: nil),
                .init(start: .nan, end: 0.8, text: "invalid", speaker: nil),
                .init(start: 1.1, end: 2, text: "outside", speaker: nil),
            ], decodeSeconds: 0.1
        )
        let mapped = try NativeFinalTranscriptMapper.map(
            response, speaker: .them, absoluteWindowStart: 30, duration: 1
        )
        XCTAssertEqual(mapped.map(\.text), ["First", "Second"])
        XCTAssertEqual(mapped.map(\.startTime), [30, 30.8])
        XCTAssertEqual(mapped.map(\.endTime), [30.5, 31])
        XCTAssertTrue(mapped.allSatisfy { $0.speaker == .them && $0.words.isEmpty && $0.confidence == nil })
        XCTAssertEqual(mapped.map(\.detectedLanguage), ["ru", "ru"])
    }

    func testNonemptyTextWithoutValidTimestampRangeIsRejected() throws {
        let response = NativeASRWireResult(
            id: "x", text: "Valid words", language: nil,
            segments: [.init(start: 2, end: 3, text: "Valid words", speaker: nil)], decodeSeconds: 0
        )
        XCTAssertThrowsError(try NativeFinalTranscriptMapper.map(
            response, speaker: .me, absoluteWindowStart: 0, duration: 1
        )) { XCTAssertEqual($0 as? NativeFinalASRError, .invalidResponse) }
    }

    func testReadyParserRejectsWrongEngineAndNegativeTiming() throws {
        XCTAssertNoThrow(try NativeFinalWorkerProtocol.ready(
            Data(#"{"event":"ready","engine":"qwen","loadSeconds":0.1}"#.utf8), engine: .qwen
        ))
        XCTAssertThrowsError(try NativeFinalWorkerProtocol.ready(
            Data(#"{"event":"ready","engine":"moss","loadSeconds":0.1}"#.utf8), engine: .qwen
        ))
        XCTAssertThrowsError(try NativeFinalWorkerProtocol.ready(
            Data(#"{"event":"ready","engine":"qwen","loadSeconds":-1}"#.utf8), engine: .qwen
        ))
    }

    func testTruncatedSuccessResponseCannotBeSavedAsComplete() throws {
        let data = Data(#"{"id":"x","text":"Partial","language":"ru","segments":[{"start":0,"end":1,"text":"Partial","speaker":null}],"decodeSeconds":0.1,"truncated":true}"#.utf8)
        XCTAssertThrowsError(try NativeFinalWorkerProtocol.result(data, requestID: "x")) {
            XCTAssertEqual($0 as? NativeFinalASRError, .invalidResponse)
        }
    }

    func testLineInboxPreservesSplitJSONAndCancelsReaderWithoutDroppingNextLine() async throws {
        let inbox = NativeWorkerLineInbox()
        inbox.append(Data(#"{"first":"#.utf8))
        inbox.append(Data("1}\n{\"second\":2}\n".utf8))
        let first = try await inbox.nextLine()
        let second = try await inbox.nextLine()
        XCTAssertEqual(String(decoding: first, as: UTF8.self), #"{"first":1}"#)
        XCTAssertEqual(String(decoding: second, as: UTF8.self), #"{"second":2}"#)
        let waiting = Task { try await inbox.nextLine() }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Reader should be cancellable") }
        catch { XCTAssertTrue(error is CancellationError) }
        inbox.append(Data("next\n".utf8))
        let next = try await inbox.nextLine()
        XCTAssertEqual(String(decoding: next, as: UTF8.self), "next")
    }

    func testLineInboxRejectsOversizedOutputAndQueueOverflow() async throws {
        let oversized = NativeWorkerLineInbox()
        oversized.append(Data(repeating: 65, count: 2 * 1024 * 1024 + 1))
        do { _ = try await oversized.nextLine(); XCTFail("Expected output rejection") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .invalidResponse) }
        let flooded = NativeWorkerLineInbox()
        flooded.append(Data(String(repeating: "line\n", count: 9).utf8))
        do { _ = try await flooded.nextLine(); XCTFail("Expected queue rejection") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .invalidResponse) }
    }

    func testOpenPipeDeliversShortReadyLineAndLeavesCancellationResponsive() async throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try NativeFinalPipeRead.makeNonblocking(pipe.fileHandleForReading)
        let inbox = NativeWorkerLineInbox()
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        inbox.readAvailable(pipe.fileHandleForReading)
        let ready = try await inbox.nextLine()
        XCTAssertEqual(String(decoding: ready, as: UTF8.self), "ready")
        // No EOF: the worker's write end deliberately remains open.
        inbox.readAvailable(pipe.fileHandleForReading)
        let pending = Task { try await inbox.nextLine() }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Pipe reader must remain cancellable") }
        catch { XCTAssertTrue(error is CancellationError) }
        try pipe.fileHandleForWriting.write(contentsOf: Data("response\n".utf8))
        inbox.readAvailable(pipe.fileHandleForReading)
        let response = try await inbox.nextLine()
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "response")
        try pipe.fileHandleForWriting.close()
        inbox.readAvailable(pipe.fileHandleForReading)
        do { _ = try await inbox.nextLine(); XCTFail("EOF must end the inbox") }
        catch { XCTAssertEqual(error as? NativeFinalASRError, .workerExited) }
    }

    func testRealOpenWorkerPipeCancelsReaderAndStopsExactChild() async throws {
        let executable = root.appendingPathComponent("pipe-worker")
        try Data("#!/bin/sh\nprintf 'ready\\n'\nexec /bin/cat\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let transport = NativeASRProcessTransport()
        try await transport.start(engine: .qwen, modelDirectoryURL: root, executableURL: executable)
        let ready = try await transport.readLine()
        XCTAssertEqual(String(decoding: ready, as: UTF8.self), "ready")
        let child = await transport.ownedProcessIdentifier
        let pending = Task { try await transport.readLine() }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Open child pipe must permit cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await transport.sendLine(Data("next".utf8))
        let response = try await transport.readLine()
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "next")
        try await transport.stop()
        let remaining = await transport.ownedProcessIdentifier
        XCTAssertNil(remaining)
        if let child {
            XCTAssertEqual(kill(child, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        } else { XCTFail("Expected an owned worker process") }
    }

    private var samples: [Float] { Array(repeating: 0.05, count: 16_000) }

    private func transcribe(_ service: NativeFinalTranscriptionService) async throws -> [BestTranscriptSegment] {
        try await service.transcribeWindow(
            samples: samples, speaker: .me, absoluteWindowStart: 0, vocabulary: ""
        )
    }

    private func makeService(
        _ worker: FakeNativeASRTransport,
        timeout: Duration = .seconds(2),
        idle: Duration = .seconds(30),
        startupAdmission: @escaping @Sendable () -> Bool = { true }
    ) -> NativeFinalTranscriptionService {
        NativeFinalTranscriptionService(
            engine: .qwen, modelDirectoryURL: root, executableURL: root.appendingPathComponent("fake-worker"),
            modelIdentity: "qwen-test-revision-q4", startupTimeout: timeout, inferenceTimeout: timeout,
            idleShutdownDelay: idle, temporaryRootURL: root,
            startupAdmission: startupAdmission, transportFactory: { worker }
        )
    }

    private func waitUntil(condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private actor FakeNativeASRTransport: NativeASRWorkerTransport {
    enum Mode: Equatable, Sendable { case success, mismatchedID, failure }
    struct Observed: Sendable {
        var starts = 0
        var stops = 0
        var requests = 0
        var maximumRequests = 0
        var vocabulary: String?
        var languageWasNull = false
        var maxTokens: Int?
        var paths: [String] = []
        var sampleRate: Double?
        var channels: UInt32?
        var frames: Int64?
    }
    private var inbox = NativeWorkerLineInbox()
    private var state = Observed()
    private let holdsReady: Bool
    private var holdsResponses: Bool
    private var pendingResponses: [Data] = []
    private var activeRequests = 0
    private var holdsStop: Bool
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var failedStops: Int
    private let mode: Mode

    init(
        holdReady: Bool = false, holdResponses: Bool = false, holdStop: Bool = false,
        failedStops: Int = 0, mode: Mode = .success
    ) {
        holdsReady = holdReady
        holdsResponses = holdResponses
        self.failedStops = failedStops
        self.mode = mode
        holdsStop = holdStop
    }

    func start(
        engine: NativeFinalTranscriptionService.Engine,
        modelDirectoryURL: URL,
        executableURL: URL
    ) async throws {
        inbox = NativeWorkerLineInbox()
        state.starts += 1
        if !holdsReady {
            inbox.append(Data("{\"event\":\"ready\",\"engine\":\"\(engine.rawValue)\",\"loadSeconds\":0.01}\n".utf8))
        }
    }

    func readLine() async throws -> Data {
        let data = try await inbox.nextLine()
        if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["id"] != nil {
            activeRequests -= 1
        }
        return data
    }

    func sendLine(_ data: Data) async throws {
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try XCTUnwrap(request["id"] as? String)
        let path = try XCTUnwrap(request["audioPath"] as? String)
        state.requests += 1
        state.vocabulary = request["vocabulary"] as? String
        state.languageWasNull = request["language"] is NSNull
        state.maxTokens = request["maxTokens"] as? Int
        state.paths.append(path)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        state.sampleRate = file.processingFormat.sampleRate
        state.channels = file.processingFormat.channelCount
        state.frames = file.length
        activeRequests += 1
        state.maximumRequests = max(activeRequests, state.maximumRequests)
        let response: [String: Any]
        switch mode {
        case .success, .mismatchedID:
            response = [
                "id": mode == .success ? id : "incorrect-id", "text": "Local transcript", "language": "ru",
                "segments": [["start": 0, "end": 1, "text": "Local transcript", "speaker": NSNull()]],
                "decodeSeconds": 0.01,
            ]
        case .failure:
            response = ["id": id, "error": "private transcript should never appear in UI"]
        }
        let encoded = try JSONSerialization.data(withJSONObject: response) + Data([10])
        if holdsResponses { pendingResponses.append(encoded) }
        else { inbox.append(encoded) }
    }

    func stop() async throws {
        state.stops += 1
        if failedStops > 0 {
            failedStops -= 1
            throw NativeFinalASRError.terminationFailed
        }
        pendingResponses.removeAll()
        activeRequests = 0
        inbox.finish(CancellationError(), discardBuffered: true)
        if holdsStop { await withCheckedContinuation { stopContinuation = $0 } }
    }

    func releaseResponses() {
        holdsResponses = false
        pendingResponses.forEach { inbox.append($0) }
        pendingResponses.removeAll()
    }

    func observed() -> Observed { state }

    func releaseStop() {
        holdsStop = false
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private final class NativeTestAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var allowed: Bool { lock.withLock { value } }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
}
