import Darwin
import Foundation

/// Owns the native ASR child independently from live Parakeet/Whisper. Every
/// request is local, bounded, and cancellable by terminating this exact child.
actor NativeFinalTranscriptionService: BestWhisperRecognizing {
    enum Engine: String, Sendable {
        case qwen
        case moss
    }

    nonisolated let preferredWindowBatchSize = 1
    nonisolated let windowOverlapSeconds: TimeInterval = 0
    nonisolated let hasWordAlignment = false
    nonisolated let modelIdentity: String
    nonisolated let modelDisplayName: String

    private let engine: Engine
    private let modelDirectoryURL: URL
    private let executableURL: URL
    private let language: String?
    private let maxTokens: Int
    private let startupTimeout: Duration
    private let inferenceTimeout: Duration
    private let idleShutdownDelay: Duration
    private let temporaryDirectoryURL: URL
    private let transportFactory: @Sendable () -> any NativeASRWorkerTransport
    private let startupAdmission: @Sendable () -> Bool
    private let operationGate = NativeASROperationGate()

    private struct WorkerSession {
        let id: UUID
        let transport: any NativeASRWorkerTransport
        var ready = false
    }

    private var session: WorkerSession?
    private var stopping: (id: UUID, attemptID: UUID, task: Task<Void, Error>)?
    private var idleShutdown: Task<Void, Never>?
    private var isPaused = false

    var hasRunningWorker: Bool { session != nil || stopping != nil }
    private(set) var lastDetectedLanguages: [String] = []

    init(
        engine: Engine,
        modelDirectoryURL: URL,
        executableURL: URL,
        modelIdentity: String? = nil,
        modelDisplayName: String? = nil,
        language: String? = nil,
        maxTokens: Int = 2048,
        startupTimeout: Duration = .seconds(60),
        inferenceTimeout: Duration = .seconds(90),
        idleShutdownDelay: Duration = .seconds(2),
        temporaryRootURL: URL = FileManager.default.temporaryDirectory,
        startupAdmission: @escaping @Sendable () -> Bool = { true },
        transportFactory: @escaping @Sendable () -> any NativeASRWorkerTransport = {
            NativeASRProcessTransport()
        }
    ) {
        self.engine = engine
        self.modelDirectoryURL = modelDirectoryURL.standardizedFileURL
        self.executableURL = executableURL.standardizedFileURL
        self.modelIdentity = modelIdentity ?? "\(engine.rawValue)-native-asr-local-v1"
        self.modelDisplayName = modelDisplayName
            ?? (engine == .qwen ? "Qwen3-ASR 1.7B" : "MOSS Transcribe Diarize 0.9B")
        self.language = language
        self.maxTokens = maxTokens
        self.startupTimeout = startupTimeout
        self.inferenceTimeout = inferenceTimeout
        self.idleShutdownDelay = idleShutdownDelay
        self.temporaryDirectoryURL = temporaryRootURL.appendingPathComponent(
            "ParrotNativeASR-\(UUID().uuidString)", isDirectory: true
        )
        self.transportFactory = transportFactory
        self.startupAdmission = startupAdmission
    }

    func prepareLocalOnly(modelName: String) async throws {
        try await operationGate.acquire()
        defer { Task { await operationGate.release() } }
        try checkAvailableForWork()
        cancelIdleShutdown()
        try await ensurePrepared()
        scheduleIdleShutdown()
    }

    func transcribeWindow(
        samples: [Float],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        vocabulary: String
    ) async throws -> [BestTranscriptSegment] {
        try await operationGate.acquire()
        defer { Task { await operationGate.release() } }
        try checkAvailableForWork()
        cancelIdleShutdown()
        guard !samples.isEmpty else { return [] }
        guard samples.count <= 120 * 16_000,
              samples.allSatisfy(\.isFinite),
              absoluteWindowStart.isFinite, absoluteWindowStart >= 0,
              vocabulary.utf8.count <= 8192,
              (32...8192).contains(maxTokens) else { throw NativeFinalASRError.invalidInput }
        try await ensurePrepared()
        guard let current = session, current.ready else { throw CancellationError() }
        let requestID = UUID().uuidString
        let audioURL = temporaryDirectoryURL.appendingPathComponent("\(requestID).wav")
        defer { removeOwnedAudio(audioURL) }

        do {
            let mapped = try await withTaskCancellationHandler {
                // This bounded write is owned until it completes, including if
                // cancellation arrives while the WAV is being written.
                let directory = temporaryDirectoryURL
                let writing = Task.detached(priority: .utility) {
                    try NativeFinalWAV.write(samples, to: audioURL, directory: directory)
                }
                try await writing.value
                try checkSession(current.id)
                let request = NativeASRWireRequest(
                    id: requestID,
                    audioPath: audioURL.path,
                    vocabulary: vocabulary,
                    language: language,
                    maxTokens: maxTokens
                )
                let requestData = try JSONEncoder().encode(request)
                let responseData = try await Self.withDeadline(
                    inferenceTimeout, error: .inferenceTimeout
                ) {
                    try await current.transport.sendLine(requestData)
                    return try await current.transport.readLine()
                }
                try checkSession(current.id)
                let response = try NativeFinalWorkerProtocol.result(responseData, requestID: requestID)
                self.lastDetectedLanguages = response.languages ?? [response.language].compactMap { $0 }
                return try NativeFinalTranscriptMapper.map(
                    response,
                    speaker: speaker,
                    absoluteWindowStart: absoluteWindowStart,
                    duration: Double(samples.count) / 16_000
                )
            } onCancel: {
                Task { try? await self.stopWorker(expectedID: current.id) }
            }
            scheduleIdleShutdown()
            return mapped
        } catch {
            let cancelled = Task.isCancelled || isPaused || session?.id != current.id
            try await stopWorker(expectedID: current.id)
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    func transcribeWindows(
        _ windows: [BestWhisperWindowInput],
        vocabulary: String
    ) async throws -> [[BestTranscriptSegment]] {
        var results: [[BestTranscriptSegment]] = []
        for window in windows {
            try checkAvailableForWork()
            results.append(try await transcribeWindow(
                samples: window.samples,
                speaker: window.speaker,
                absoluteWindowStart: window.absoluteWindowStart,
                vocabulary: vocabulary
            ))
        }
        return results
    }

    func pauseForRecording() async throws {
        isPaused = true
        cancelIdleShutdown()
        try await stopWorker()
    }

    func resumeAfterRecording() {
        isPaused = false
    }

    func shutdown() async throws {
        cancelIdleShutdown()
        try await stopWorker()
    }

    private func ensurePrepared() async throws {
        try checkAvailableForWork()
        if let stopping { try await finishStopping(stopping) }
        try checkAvailableForWork()
        if session?.ready == true { return }
        // A failed termination remains owned and must be retried before a new
        // process can be launched.
        if session != nil { try await stopWorker() }
        try checkAvailableForWork()
        guard startupAdmission() else { throw NativeFinalASRError.memoryUnavailable }
        let current = WorkerSession(id: UUID(), transport: transportFactory())
        session = current
        let engine = self.engine
        let modelDirectory = modelDirectoryURL
        let executable = executableURL
        do {
            let readyData = try await withTaskCancellationHandler {
                try await Self.withDeadline(startupTimeout, error: .startupTimeout) {
                    try await current.transport.start(
                        engine: engine,
                        modelDirectoryURL: modelDirectory,
                        executableURL: executable
                    )
                    return try await current.transport.readLine()
                }
            } onCancel: {
                Task { try? await self.stopWorker(expectedID: current.id) }
            }
            try checkSession(current.id)
            try NativeFinalWorkerProtocol.ready(readyData, engine: engine)
            session?.ready = true
        } catch {
            let cancelled = Task.isCancelled || isPaused || session?.id != current.id
            try await stopWorker(expectedID: current.id)
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    private func checkAvailableForWork() throws {
        try Task.checkCancellation()
        guard !isPaused else { throw CancellationError() }
    }

    private func checkSession(_ id: UUID) throws {
        try checkAvailableForWork()
        guard session?.id == id, stopping == nil else { throw CancellationError() }
    }

    private func stopWorker(expectedID: UUID? = nil) async throws {
        if let expectedID,
           session?.id != expectedID, stopping?.id != expectedID { return }
        cancelIdleShutdown()
        if let stopping {
            if expectedID == nil || expectedID == stopping.id {
                try await finishStopping(stopping)
            }
            return
        }
        guard let current = session,
              expectedID == nil || current.id == expectedID else { return }
        session?.ready = false
        let stop = (id: current.id, attemptID: UUID(), task: Task { try await current.transport.stop() })
        stopping = stop
        try await finishStopping(stop)
    }

    private func finishStopping(
        _ stop: (id: UUID, attemptID: UUID, task: Task<Void, Error>)
    ) async throws {
        do {
            try await stop.task.value
            if session?.id == stop.id { session = nil }
            if stopping?.attemptID == stop.attemptID { stopping = nil }
        } catch {
            if stopping?.attemptID == stop.attemptID { stopping = nil }
            // Keep session on failure: this actor still owns a possibly live
            // exact child, and cannot silently replace it.
            throw error
        }
    }

    private func cancelIdleShutdown() {
        idleShutdown?.cancel()
        idleShutdown = nil
    }

    private func scheduleIdleShutdown() {
        cancelIdleShutdown()
        guard let id = session?.id else { return }
        let delay = idleShutdownDelay
        idleShutdown = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            try? await self.stopWorker(expectedID: id)
        }
    }

    private func removeOwnedAudio(_ audioURL: URL) {
        try? FileManager.default.removeItem(at: audioURL)
        if (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectoryURL.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    private nonisolated static func withDeadline<Value: Sendable>(
        _ duration: Duration,
        error: NativeFinalASRError,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: duration)
                throw error
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}

enum NativeFinalASRError: LocalizedError, Equatable {
    case invalidInput
    case modelUnavailable
    case memoryUnavailable
    case workerUnavailable
    case invalidResponse
    case workerExited
    case workerFailed
    case startupTimeout
    case inferenceTimeout
    case terminationFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput: "The local transcription input is invalid or exceeds its safe window limit."
        case .modelUnavailable: "The selected local speech model is unavailable."
        case .memoryUnavailable: "The local speech model is waiting for enough available memory."
        case .workerUnavailable: "The bundled local speech worker is unavailable."
        case .invalidResponse: "The local speech worker returned an invalid result."
        case .workerExited: "The local speech worker stopped before completing this request."
        case .workerFailed: "The local speech worker could not complete this audio window."
        case .startupTimeout: "The local speech model took too long to start and was stopped."
        case .inferenceTimeout: "The local speech model took too long to process this window and was stopped."
        case .terminationFailed: "The local speech worker could not be stopped. Starting another worker was blocked."
        }
    }
}

struct NativeASRWireRequest: Encodable, Sendable {
    let id: String
    let audioPath: String
    let vocabulary: String
    let language: String?
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case id, audioPath, vocabulary, language, maxTokens
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(audioPath, forKey: .audioPath)
        try container.encode(vocabulary, forKey: .vocabulary)
        // Explicit null is part of the IPC contract for automatic language.
        try container.encode(language, forKey: .language)
        try container.encode(maxTokens, forKey: .maxTokens)
    }
}

struct NativeASRWireSegment: Decodable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
}

struct NativeASRWireResult: Decodable, Sendable {
    let id: String
    let text: String
    let language: String?
    let segments: [NativeASRWireSegment]
    let decodeSeconds: Double
    var truncated: Bool? = nil
    var languages: [String]? = nil
}

enum NativeFinalWorkerProtocol {
    private struct Ready: Decodable {
        let event: String
        let engine: String
        let loadSeconds: Double
    }
    private struct Failure: Decodable {
        let id: String
        let error: String
    }

    static func ready(_ data: Data, engine: NativeFinalTranscriptionService.Engine) throws {
        guard let ready = try? JSONDecoder().decode(Ready.self, from: data),
              ready.event == "ready", ready.engine == engine.rawValue,
              ready.loadSeconds.isFinite, ready.loadSeconds >= 0 else {
            throw NativeFinalASRError.invalidResponse
        }
    }

    static func result(_ data: Data, requestID: String) throws -> NativeASRWireResult {
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            guard failure.id == requestID else { throw NativeFinalASRError.invalidResponse }
            // Do not surface arbitrary worker text; it may contain transcript
            // excerpts or paths. The user gets a bounded generic explanation.
            throw NativeFinalASRError.workerFailed
        }
        guard let result = try? JSONDecoder().decode(NativeASRWireResult.self, from: data),
              result.id == requestID,
              result.decodeSeconds.isFinite, result.decodeSeconds >= 0,
              result.truncated != true else {
            throw NativeFinalASRError.invalidResponse
        }
        return result
    }
}

enum NativeFinalTranscriptMapper {
    static func map(
        _ result: NativeASRWireResult,
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval,
        duration: TimeInterval
    ) throws -> [BestTranscriptSegment] {
        guard absoluteWindowStart.isFinite, absoluteWindowStart >= 0,
              duration.isFinite, duration > 0 else { throw NativeFinalASRError.invalidInput }
        let mapped = result.segments.compactMap { raw -> BestTranscriptSegment? in
            guard raw.start.isFinite, raw.end.isFinite, raw.end > raw.start else { return nil }
            let start = max(0, raw.start)
            let end = min(duration, raw.end)
            let text = cleaned(raw.text)
            guard end > start, !text.isEmpty else { return nil }
            return BestTranscriptSegment(
                id: UUID(), speaker: speaker,
                startTime: absoluteWindowStart + start,
                endTime: absoluteWindowStart + end,
                text: text, confidence: nil,
                detectedLanguage: result.language?.trimmingCharacters(in: .whitespacesAndNewlines),
                words: []
            )
        }
        if mapped.isEmpty, !cleaned(result.text).isEmpty {
            throw NativeFinalASRError.invalidResponse
        }
        return mapped.enumerated().sorted {
            if $0.element.startTime == $1.element.startTime { return $0.offset < $1.offset }
            return $0.element.startTime < $1.element.startTime
        }.map(\.element)
    }

    private static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"<\|[^|>]*\|>|</?(?:s|pad|eos|bos|unk)>"#,
                with: "", options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol NativeASRWorkerTransport: Sendable {
    func start(
        engine: NativeFinalTranscriptionService.Engine,
        modelDirectoryURL: URL,
        executableURL: URL
    ) async throws
    func readLine() async throws -> Data
    func sendLine(_ data: Data) async throws
    func stop() async throws
}

/// Reads pipes on Foundation's readiness callback, never on the main actor.
/// Stdout buffering is capped; stderr is drained and discarded in small chunks.
actor NativeASRProcessTransport: NativeASRWorkerTransport {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private let inbox = NativeWorkerLineInbox()

    var ownedProcessIdentifier: Int32? { process?.processIdentifier }

    func start(
        engine: NativeFinalTranscriptionService.Engine,
        modelDirectoryURL: URL,
        executableURL: URL
    ) async throws {
        try Task.checkCancellation()
        guard process == nil else { throw NativeFinalASRError.workerUnavailable }
        var isDirectory: ObjCBool = false
        guard modelDirectoryURL.isFileURL,
              FileManager.default.fileExists(atPath: modelDirectoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw NativeFinalASRError.modelUnavailable }
        guard executableURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NativeFinalASRError.workerUnavailable
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = executableURL
        child.currentDirectoryURL = executableURL.deletingLastPathComponent()
        child.arguments = ["--engine", engine.rawValue, "--model-dir", modelDirectoryURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        try NativeFinalPipeRead.makeNonblocking(stdout.fileHandleForReading)
        try NativeFinalPipeRead.makeNonblocking(stderr.fileHandleForReading)
        let inbox = self.inbox
        stdout.fileHandleForReading.readabilityHandler = { handle in inbox.readAvailable(handle) }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            do {
                if try NativeFinalPipeRead.availableData(handle)?.isEmpty == true {
                    handle.readabilityHandler = nil
                }
            } catch { handle.readabilityHandler = nil }
        }
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        do {
            try child.run()
            process = child
            // Parent copies of the child's pipe ends must close so a genuine
            // child exit delivers EOF after all complete stdout lines.
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            let descriptor = stdin.fileHandleForWriting.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw NativeFinalASRError.workerUnavailable
            }
        } catch {
            if process == nil { closePipes() }
            throw error
        }
    }

    func readLine() async throws -> Data {
        try await inbox.nextLine()
    }

    func sendLine(_ data: Data) async throws {
        guard data.count <= 65_536 else { throw NativeFinalASRError.invalidInput }
        var line = data
        line.append(10)
        var written = 0
        while written < line.count {
            try Task.checkCancellation()
            guard let process, process.isRunning, let input else {
                throw NativeFinalASRError.workerExited
            }
            let descriptor = input.fileDescriptor
            let result = line.withUnsafeBytes { bytes in
                NativeFinalSafePipeWrite.write(
                    descriptor, bytes.baseAddress!.advanced(by: written), line.count - written
                )
            }
            if result.count > 0 {
                written += result.count
            } else if result.error == EINTR {
                continue
            } else if result.error == EAGAIN || result.error == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(5))
            } else {
                throw NativeFinalASRError.workerExited
            }
        }
    }

    func stop() async throws {
        inbox.finish(CancellationError(), discardBuffered: true)
        guard let child = process else { closePipes(); return }
        if child.isRunning {
            child.terminate()
            await waitForExit(child, until: ContinuousClock.now + .milliseconds(250))
            if child.isRunning, kill(child.processIdentifier, 0) == 0 {
                // This exact NSTask is still alive after graceful termination;
                // only this verified owned child may receive SIGKILL.
                kill(child.processIdentifier, SIGKILL)
                await waitForExit(child, until: ContinuousClock.now + .milliseconds(500))
            }
        }
        guard !child.isRunning else { throw NativeFinalASRError.terminationFailed }
        process = nil
        closePipes()
    }

    private func waitForExit(_ child: Process, until deadline: ContinuousClock.Instant) async {
        while child.isRunning, ContinuousClock.now < deadline {
            // Shutdown itself must finish even when its caller was cancelled.
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
    }

    private func closePipes() {
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil
        output = nil
        errors = nil
    }
}

/// A cancellation-aware bounded line queue. Callback reads and buffer mutation
/// share the lock so JSON chunks cannot be reordered by independent async Tasks.
final class NativeWorkerLineInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []
    private var waiters: [(UUID, CheckedContinuation<Data, Error>)] = []
    private var terminalError: Error?
    private static let maximumLineBytes = 2 * 1024 * 1024
    private static let maximumBufferedLines = 8

    func readAvailable(_ handle: FileHandle) {
        lock.withLock {
            do {
                guard let data = try NativeFinalPipeRead.availableData(handle) else { return }
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    finishLocked(NativeFinalASRError.workerExited, discardBuffered: false)
                    return
                }
                appendLocked(data)
            } catch {
                handle.readabilityHandler = nil
                finishLocked(NativeFinalASRError.workerExited, discardBuffered: false)
            }
        }
    }

    func append(_ data: Data) {
        lock.withLock { appendLocked(data) }
    }

    func nextLine() async throws -> Data {
        let id = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if !lines.isEmpty {
                        continuation.resume(returning: lines.removeFirst())
                    } else if let terminalError {
                        continuation.resume(throwing: terminalError)
                    } else {
                        waiters.append((id, continuation))
                    }
                }
            }
        } onCancel: {
            self.lock.withLock {
                guard let index = self.waiters.firstIndex(where: { $0.0 == id }) else { return }
                self.waiters.remove(at: index).1.resume(throwing: CancellationError())
            }
        }
    }

    func finish(_ error: Error, discardBuffered: Bool = false) {
        lock.withLock { finishLocked(error, discardBuffered: discardBuffered) }
    }

    private func appendLocked(_ data: Data) {
        guard terminalError == nil else { return }
        guard buffer.count + data.count <= Self.maximumLineBytes else {
            finishLocked(NativeFinalASRError.invalidResponse, discardBuffered: true)
            return
        }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            if !waiters.isEmpty {
                waiters.removeFirst().1.resume(returning: line)
            } else if lines.count < Self.maximumBufferedLines {
                lines.append(line)
            } else {
                finishLocked(NativeFinalASRError.invalidResponse, discardBuffered: true)
                return
            }
        }
    }

    private func finishLocked(_ error: Error, discardBuffered: Bool) {
        if discardBuffered { lines.removeAll(); buffer.removeAll() }
        if terminalError == nil || discardBuffered { terminalError = error }
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.1.resume(throwing: terminalError ?? error) }
    }
}

/// Foundation's counted read may wait for the entire requested length on a
/// still-open pipe. A worker keeps stdout open between short JSON lines, so one
/// nonblocking read must consume only bytes that are currently available.
enum NativeFinalPipeRead {
    static func makeNonblocking(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw NativeFinalASRError.workerUnavailable
        }
    }

    static func availableData(_ handle: FileHandle) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count >= 0 { return Data(bytes.prefix(count)) }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
        throw NativeFinalASRError.workerExited
    }
}

private actor NativeASROperationGate {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !held { held = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().1.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}

private enum NativeFinalWAV {
    static func write(_ samples: [Float], to url: URL, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        data.reserveCapacity(44 + samples.count * 4)
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count * 4), to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(3), to: &data) // IEEE float PCM; one real sample per frame.
        append(UInt16(1), to: &data)
        append(UInt32(16_000), to: &data)
        append(UInt32(64_000), to: &data)
        append(UInt16(4), to: &data)
        append(UInt16(32), to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples.count * 4), to: &data)
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }
        try data.write(to: url, options: .atomic)
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private enum NativeFinalSafePipeWrite {
    static func write(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> (count: Int, error: Int32) {
        // Protect only this write's thread from a closed-pipe SIGPIPE. Preserve
        // the app's existing signal policy and any previously pending signal.
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        var pending = sigset_t()
        sigpending(&pending)
        let alreadyPending = sigismember(&pending, SIGPIPE) == 1
        let written = Darwin.write(descriptor, bytes, count)
        let savedError = errno
        if written < 0, savedError == EPIPE, !alreadyPending {
            sigpending(&pending)
            if sigismember(&pending, SIGPIPE) == 1 {
                var received: Int32 = 0
                sigwait(&blocked, &received)
            }
        }
        pthread_sigmask(SIG_SETMASK, &previous, nil)
        return (written, savedError)
    }
}
