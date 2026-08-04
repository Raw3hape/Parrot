import AVFoundation
import CryptoKit
import Foundation

struct BestAudioTrackInfo: Equatable, Sendable {
    var speaker: BestTranscriptSpeaker
    var url: URL
    var sourceFrameCount: Int64
    var sourceSampleRate: Double
    var canonicalFrameCount: Int64
    var duration: TimeInterval
}

enum BestAudioFileReader {
    static let canonicalSampleRate: Double = 16_000

    enum ReaderError: LocalizedError {
        case missingFile
        case emptyFile
        case invalidFormat
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingFile:
                "Recording audio is missing."
            case .emptyFile:
                "Recording audio is empty."
            case .invalidFormat:
                "Recording audio has an unsupported format."
            case .conversionFailed(let detail):
                "Recording audio could not be converted: \(detail)"
            }
        }
    }

    static func inspect(
        url: URL,
        speaker: BestTranscriptSpeaker,
        canonicalSampleRate: Double = canonicalSampleRate
    ) throws -> BestAudioTrackInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReaderError.missingFile
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0 else {
            throw ReaderError.emptyFile
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ReaderError.conversionFailed(error.localizedDescription)
        }
        let sourceRate = file.processingFormat.sampleRate
        guard file.length > 0, sourceRate > 0, canonicalSampleRate > 0 else {
            throw ReaderError.invalidFormat
        }
        let duration = Double(file.length) / sourceRate
        return BestAudioTrackInfo(
            speaker: speaker,
            url: url,
            sourceFrameCount: file.length,
            sourceSampleRate: sourceRate,
            canonicalFrameCount: Int64((duration * canonicalSampleRate).rounded()),
            duration: duration
        )
    }

    static func readWindow(
        url: URL,
        window: BestAudioWindow,
        canonicalSampleRate: Double = canonicalSampleRate
    ) throws -> [Float] {
        guard window.endFrame > window.startFrame else { return [] }
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw ReaderError.invalidFormat
        }

        let startSeconds = Double(window.startFrame) / canonicalSampleRate
        let endSeconds = Double(window.endFrame) / canonicalSampleRate
        let sourceStart = AVAudioFramePosition(
            (startSeconds * sourceFormat.sampleRate).rounded(.down)
        )
        let sourceEnd = AVAudioFramePosition(
            (endSeconds * sourceFormat.sampleRate).rounded(.up)
        ) + 64
        let available = max(0, min(file.length, sourceEnd) - min(file.length, sourceStart))
        guard available > 0 else { return [] }

        file.framePosition = min(file.length, sourceStart)
        let sourceBuffer = try readBuffer(
            from: file,
            frameCount: AVAudioFrameCount(available)
        )

        let expectedCount = Int(window.endFrame - window.startFrame)
        if abs(sourceFormat.sampleRate - canonicalSampleRate) < 0.5 {
            return normalizedMonoSamples(
                from: sourceBuffer,
                expectedCount: expectedCount
            )
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: canonicalSampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
        let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(expectedCount + 64)
        ) else {
            throw ReaderError.invalidFormat
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            throw ReaderError.conversionFailed(conversionError.localizedDescription)
        }
        guard status != .error else {
            throw ReaderError.conversionFailed("The audio converter returned an error.")
        }
        return normalizedMonoSamples(from: converted, expectedCount: expectedCount)
    }

    private static func normalizedMonoSamples(
        from buffer: AVAudioPCMBuffer,
        expectedCount: Int
    ) -> [Float] {
        guard expectedCount > 0,
              let channels = buffer.floatChannelData else { return [] }
        let available = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var output = Array(repeating: Float.zero, count: expectedCount)
        let copied = min(available, expectedCount)
        guard copied > 0 else { return output }

        if channelCount == 1 {
            output.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(from: channels[0], count: copied)
            }
        } else {
            for frame in 0..<copied {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channels[channel][frame]
                }
                output[frame] = sum / Float(channelCount)
            }
        }
        return output
    }

    /// AVAudioFile is allowed to return fewer frames than requested at packet
    /// boundaries. Fill a bounded window with repeated reads so a short packet
    /// never turns the remainder of a 30-second recognition window into silence.
    private static func readBuffer(
        from file: AVAudioFile,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let combined = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
              ),
              let destinationChannels = combined.floatChannelData else {
            throw ReaderError.invalidFormat
        }

        var total = 0
        while total < Int(frameCount), file.framePosition < file.length {
            let requested = min(16_384, Int(frameCount) - total)
            guard let chunk = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(requested)
            ) else {
                throw ReaderError.invalidFormat
            }
            do {
                try file.read(into: chunk, frameCount: AVAudioFrameCount(requested))
            } catch {
                throw ReaderError.conversionFailed(error.localizedDescription)
            }
            let read = Int(chunk.frameLength)
            guard read > 0, let sourceChannels = chunk.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                destinationChannels[channel]
                    .advanced(by: total)
                    .update(from: sourceChannels[channel], count: read)
            }
            total += read
        }
        combined.frameLength = AVAudioFrameCount(total)
        return combined
    }
}

enum BestTranscriptionFingerprintBuilder {
    static func make(
        tracks: [(BestTranscriptSpeaker, URL)],
        modelID: String,
        pipelineVersion: Int,
        vocabulary: String
    ) throws -> BestTranscriptionFingerprint {
        let trackFingerprints = try tracks.map { speaker, url -> BestAudioTrackFingerprint in
            let info = try BestAudioFileReader.inspect(url: url, speaker: speaker)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
            let nanoseconds = UInt64(max(0, modified.timeIntervalSince1970) * 1_000_000_000)
            return BestAudioTrackFingerprint(
                speaker: speaker,
                fileSize: size,
                modifiedAtNanoseconds: nanoseconds,
                frameCount: info.sourceFrameCount,
                sampleRate: info.sourceSampleRate
            )
        }
        .sorted { left, right in
            if left.speaker == right.speaker { return left.fileSize < right.fileSize }
            return left.speaker == .them
        }

        return BestTranscriptionFingerprint(
            modelID: modelID,
            pipelineVersion: pipelineVersion,
            vocabularyHash: vocabularyHash(vocabulary),
            tracks: trackFingerprints
        )
    }

    static func vocabularyHash(_ vocabulary: String) -> String {
        SHA256.hash(data: Data(vocabulary.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
