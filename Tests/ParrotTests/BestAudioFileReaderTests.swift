import AVFoundation
import XCTest
@testable import Parrot

final class BestAudioFileReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParrotBestAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testReaderReturnsOnlyRequestedWindowAtCanonicalSampleRate() throws {
        let url = directory.appendingPathComponent("track.caf")
        let samples = (0..<(4 * 16_000)).map { Float($0) / Float(4 * 16_000) }
        try writeCAF(samples: samples, sampleRate: 16_000, to: url)

        let window = BestAudioWindow(
            index: 1,
            startFrame: 16_000,
            endFrame: 32_000,
            ownedStartFrame: 16_000,
            ownedEndFrame: 32_000
        )
        let read = try BestAudioFileReader.readWindow(
            url: url,
            window: window,
            canonicalSampleRate: 16_000
        )

        XCTAssertEqual(read.count, 16_000)
        XCTAssertEqual(read.first ?? -1, samples[16_000], accuracy: 0.0001)
        XCTAssertEqual(read.last ?? -1, samples[31_999], accuracy: 0.0001)
    }

    func testInspectConvertsDurationToCanonicalFrameCount() throws {
        let url = directory.appendingPathComponent("track-48k.caf")
        let samples = Array(repeating: Float(0.1), count: 96_000)
        try writeCAF(samples: samples, sampleRate: 48_000, to: url)

        let info = try BestAudioFileReader.inspect(
            url: url,
            speaker: .them,
            canonicalSampleRate: 16_000
        )

        XCTAssertEqual(info.sourceFrameCount, 96_000)
        XCTAssertEqual(info.sourceSampleRate, 48_000)
        XCTAssertEqual(info.canonicalFrameCount, 32_000)
        XCTAssertEqual(info.duration, 2, accuracy: 0.001)
    }

    func testFingerprintChangesWhenAudioChanges() throws {
        let url = directory.appendingPathComponent("track.caf")
        try writeCAF(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, to: url)
        let first = try BestTranscriptionFingerprintBuilder.make(
            tracks: [(.them, url)],
            modelID: WhisperModelService.fallbackModel,
            pipelineVersion: 1,
            vocabulary: "Parrot"
        )

        try writeCAF(samples: Array(repeating: 0.2, count: 32_000), sampleRate: 16_000, to: url)
        let second = try BestTranscriptionFingerprintBuilder.make(
            tracks: [(.them, url)],
            modelID: WhisperModelService.fallbackModel,
            pipelineVersion: 1,
            vocabulary: "Parrot"
        )

        XCTAssertNotEqual(first, second)
    }

    func testMissingAndEmptyFilesAreRejected() throws {
        let missing = directory.appendingPathComponent("missing.caf")
        XCTAssertThrowsError(
            try BestAudioFileReader.inspect(url: missing, speaker: .them)
        )

        let empty = directory.appendingPathComponent("empty.caf")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertThrowsError(
            try BestAudioFileReader.inspect(url: empty, speaker: .me)
        )
    }

    private func writeCAF(samples: [Float], sampleRate: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(
                from: pointer.baseAddress!,
                count: samples.count
            )
        }
        try file.write(from: buffer)
    }
}
