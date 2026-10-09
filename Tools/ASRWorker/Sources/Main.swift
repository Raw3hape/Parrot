import AVFoundation
import Darwin
import Foundation
import MLX
import MLXAudioSTT

private enum WorkerError: Error, LocalizedError {
    case invalid(String)
    case truncated(Int)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .truncated(let count):
            return "Decoder reached the output-token limit (\(count)); split the audio window or increase maxTokens."
        }
    }
}

private enum Engine: String {
    case qwen, moss
}

private struct Startup {
    let engine: Engine
    let modelDirectory: URL

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard ["--engine", "--model-dir"].contains(key), index + 1 < arguments.count,
                  values[key] == nil else {
                throw WorkerError.invalid("Usage: ParrotASRWorker --engine qwen|moss --model-dir ABSOLUTE_DIRECTORY")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let name = values["--engine"], let engine = Engine(rawValue: name),
              let path = values["--model-dir"], path.hasPrefix("/") else {
            throw WorkerError.invalid("An engine and absolute local model directory are required.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkerError.invalid("The local model directory does not exist.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw WorkerError.invalid("The local model folder is missing config.json.")
        }
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard contents.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw WorkerError.invalid("The local model folder has no safetensors weights.")
        }
        self.engine = engine
        self.modelDirectory = directory
    }
}

private struct Request: Decodable {
    let id: String
    let audioPath: String
    let vocabulary: [String]
    let language: String?
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case id, audioPath, vocabulary, language, maxTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        audioPath = try container.decode(String.self, forKey: .audioPath)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 2_048
        if let words = try? container.decode([String].self, forKey: .vocabulary) {
            vocabulary = words
        } else if let hint = try? container.decode(String.self, forKey: .vocabulary) {
            vocabulary = hint.isEmpty ? [] : [hint]
        } else if !container.contains(.vocabulary) {
            vocabulary = []
        } else if try container.decodeNil(forKey: .vocabulary) {
            vocabulary = []
        } else {
            throw WorkerError.invalid("vocabulary must be a string array, a string, or null.")
        }
        guard !id.isEmpty, id.utf8.count <= 256 else {
            throw WorkerError.invalid("Request id must contain 1–256 bytes.")
        }
        guard audioPath.hasPrefix("/"), audioPath.utf8.count <= 4_096 else {
            throw WorkerError.invalid("audioPath must be an absolute local file path.")
        }
        guard (32...8_192).contains(maxTokens) else {
            throw WorkerError.invalid("maxTokens must be between 32 and 8192.")
        }
        guard vocabulary.count <= 256, vocabulary.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else {
            throw WorkerError.invalid("Vocabulary hint is too large.")
        }
        if let language, language.utf8.count > 64 {
            throw WorkerError.invalid("language is too long.")
        }
    }

    var vocabularyHint: String {
        vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private final class JSONOutput {
    // Model dependencies may print during loading. Preserve the protocol pipe
    // on a separate descriptor, then route all ordinary stdout logging to stderr.
    private let handle: FileHandle

    init() throws {
        fflush(nil)
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw WorkerError.invalid("Could not initialize the JSON output pipe.")
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func emit(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

private struct AudioWindow {
    let audio: MLXArray
    let samples: [Float]
    let duration: Double

    init(path: String) throws {
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "wav" else {
            throw WorkerError.invalid("Audio requests must be local WAV files.")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.fileFormat.channelCount == 1, file.fileFormat.sampleRate == 16_000 else {
            throw WorkerError.invalid("Audio must be 16000 Hz mono WAV; the parent performs resampling.")
        }
        let duration = Double(file.length) / 16_000
        guard duration.isFinite, duration > 0, duration <= 120 else {
            throw WorkerError.invalid("Audio windows must be longer than zero and no longer than 120 seconds.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw WorkerError.invalid("Could not allocate the bounded audio window.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            throw WorkerError.invalid("The audio window contains no PCM samples.")
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard samples.allSatisfy(\.isFinite) else {
            throw WorkerError.invalid("The audio window contains invalid PCM samples.")
        }
        self.audio = MLXArray(samples)
        self.samples = samples
        self.duration = Double(buffer.frameLength) / 16_000
    }
}

private struct DecodedWindow: Sendable {
    let output: STTOutput
    let timestampMode: String
    let timestampsAdjusted: Bool
    let timestampWarning: String?
    let languages: [String]
    let speechRegionCount: Int
}

private enum LoadedModel {
    case qwen(Qwen3ASRModel)
    case moss(MossTranscribeDiarizeModel)

    func transcribe(_ request: Request, window: AudioWindow) async throws -> DecodedWindow {
        switch self {
        case .qwen(let model):
            let regions = SpeechRegionDetector.regions(samples: window.samples)
            var segments: [[String: Any]] = []
            var languages: [String] = []
            var generationTokens = 0
            var peakMemory = Double(Memory.peakMemory) / 1e9
            for region in regions {
                try Task.checkCancellation()
                let piece = MLXArray(Array(window.samples[region.startSample..<region.endSample]))
                let stream = model.generateStream(
                    audio: piece, maxTokens: request.maxTokens,
                    temperature: 0, context: request.vocabularyHint, language: nil,
                    chunkDuration: 120, minChunkDuration: 0,
                    repetitionPenalty: 1, repetitionContextSize: 32
                )
                let output = try await Self.consume(stream, maxTokens: request.maxTokens)
                generationTokens += output.generationTokens
                peakMemory = max(peakMemory, output.peakMemoryUsage)
                if let language = output.language, !language.isEmpty, !languages.contains(language) {
                    languages.append(language)
                }
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append([
                        "start": Double(region.startSample) / 16_000,
                        "end": Double(region.endSample) / 16_000,
                        "text": text, "speaker": NSNull()
                    ])
                }
                Memory.clearCache()
            }
            let output = STTOutput(
                text: segments.compactMap { $0["text"] as? String }.joined(separator: " "),
                segments: segments, language: languages.count == 1 ? languages[0] : nil,
                generationTokens: generationTokens, peakMemoryUsage: peakMemory
            )
            return DecodedWindow(output: output, timestampMode: "speechRegions", timestampsAdjusted: false,
                                 timestampWarning: nil, languages: languages, speechRegionCount: regions.count)
        case .moss(let model):
            guard request.vocabularyHint.isEmpty else {
                throw WorkerError.invalid("The native MOSS streaming API has no vocabulary parameter; use an empty hint or Qwen.")
            }
            let stream = model.generateStream(
                audio: window.audio,
                generationParameters: STTGenerateParameters(
                    maxTokens: request.maxTokens, temperature: 0,
                    language: nil,
                    chunkDuration: 120, minChunkDuration: 0,
                    repetitionPenalty: 1, repetitionContextSize: 100
                )
            )
            let original = try await Self.consume(stream, maxTokens: request.maxTokens)
            let rawSegments = (original.segments ?? []).map { raw in
                TimedTranscript(
                    start: (raw["start"] as? NSNumber)?.doubleValue ?? .nan,
                    end: (raw["end"] as? NSNumber)?.doubleValue ?? .nan,
                    text: raw["text"] as? String ?? "",
                    speaker: raw["speaker_id"] as? String
                )
            }
            let timing = MossTimingNormalizer.normalize(generated: original.text, segments: rawSegments, duration: window.duration)
            let segments: [[String: Any]] = timing.segments.map {
                ["start": $0.start, "end": $0.end, "text": $0.text, "speaker": $0.speaker as Any? ?? NSNull()]
            }
            let output = STTOutput(text: timing.text, segments: segments, language: original.language,
                                   generationTokens: original.generationTokens, peakMemoryUsage: original.peakMemoryUsage)
            return DecodedWindow(output: output, timestampMode: timing.mode, timestampsAdjusted: timing.adjusted,
                                 timestampWarning: timing.warning, languages: original.language.map { [$0] } ?? [], speechRegionCount: 1)
        }
    }

    private static func consume(_ stream: AsyncThrowingStream<STTGeneration, Error>, maxTokens: Int) async throws -> STTOutput {
        var final: STTOutput?
        for try await event in stream {
            try Task.checkCancellation()
            if case .result(let result) = event { final = result }
        }
        guard let output = final else {
            throw WorkerError.invalid("The decoder ended without a final result.")
        }
        guard output.generationTokens < maxTokens else {
            throw WorkerError.truncated(output.generationTokens)
        }
        return output
    }
}

private func resultObject(request: Request, decoded: DecodedWindow, duration: Double, decodeSeconds: Double) -> [String: Any] {
    let output = decoded.output
    var segments = output.segments ?? []
    let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if segments.isEmpty, !text.isEmpty {
        segments = [["start": 0.0, "end": duration, "text": text, "speaker": NSNull()]]
    }
    return [
        "id": request.id, "text": text,
        "language": output.language as Any? ?? NSNull(),
        "segments": segments, "decodeSeconds": decodeSeconds,
        "generationTokens": output.generationTokens, "truncated": false,
        "peakMemoryGB": output.peakMemoryUsage,
        "timestampMode": decoded.timestampMode, "timestampsAdjusted": decoded.timestampsAdjusted,
        "timestampWarning": decoded.timestampWarning as Any? ?? NSNull(),
        "languages": decoded.languages, "speechRegionCount": decoded.speechRegionCount,
        "tokenLimitPerRegion": request.maxTokens
    ]
}

@main
private struct ParrotASRWorker {
    static func main() async {
        let protocolOutput: JSONOutput
        do {
            protocolOutput = try JSONOutput()
        } catch {
            FileHandle.standardError.write(Data("ASR worker output initialization failed: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
        do {
            let startup = try Startup(arguments: CommandLine.arguments)
            // A nested signed .app keeps data in Contents/Resources. Supply the
            // exact shader URL before MLX initializes its first GPU library.
            if let bundledShader = Bundle.main.resourceURL?.appendingPathComponent("mlx.metallib"),
               FileManager.default.fileExists(atPath: bundledShader.path) {
                GPU.metallib = bundledShader
            }
            let loadStarted = ContinuousClock.now
            var model: LoadedModel?
            switch startup.engine {
            case .qwen:
                model = .qwen(try await Qwen3ASRModel.fromModelDirectory(startup.modelDirectory))
            case .moss:
                model = .moss(try await MossTranscribeDiarizeModel.fromModelDirectory(startup.modelDirectory))
            }
            let loadSeconds = seconds(loadStarted.duration(to: .now))
            try protocolOutput.emit(["event": "ready", "engine": startup.engine.rawValue, "loadSeconds": loadSeconds])
            while let line = readLine() {
                var requestID = ""
                do {
                    guard line.utf8.count <= 65_536 else {
                        throw WorkerError.invalid("Request JSON exceeds 64 KiB.")
                    }
                    let data = Data(line.utf8)
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String {
                        requestID = id
                    }
                    let request = try JSONDecoder().decode(Request.self, from: data)
                    requestID = request.id
                    let window = try AudioWindow(path: request.audioPath)
                    guard let model else { throw WorkerError.invalid("The model is unloaded.") }
                    let decodeStarted = ContinuousClock.now
                    let decoded = try await model.transcribe(request, window: window)
                    let response = resultObject(
                        request: request, decoded: decoded, duration: window.duration,
                        decodeSeconds: seconds(decodeStarted.duration(to: .now))
                    )
                    try protocolOutput.emit(response)
                } catch {
                    var response: [String: Any] = ["id": requestID, "error": error.localizedDescription]
                    if case WorkerError.truncated(let count) = error {
                        response["truncated"] = true
                        response["generationTokens"] = count
                    }
                    try protocolOutput.emit(response)
                }
                Memory.clearCache()
            }
            // No request remains in flight on EOF. Release weights, then scratch
            // buffers, and let process exit reclaim the Metal context.
            model = nil
            Memory.clearCache()
        } catch {
            try? protocolOutput.emit(["event": "error", "error": error.localizedDescription])
            exit(1)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
