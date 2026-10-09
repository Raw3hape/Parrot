import AVFoundation
import Foundation

@main
struct InspectRegions {
    static func main() throws {
        var rows: [[String: Any]] = []
        for path in CommandLine.arguments.dropFirst() {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.fileFormat.sampleRate == 16_000, file.fileFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                continue
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { continue }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let regions = SpeechRegionDetector.regions(samples: samples)
            rows.append([
                "audioPath": path, "sampleCount": samples.count,
                "regions": regions.map { ["startSample": $0.startSample, "endSample": $0.endSample,
                                           "start": Double($0.startSample) / 16_000,
                                           "end": Double($0.endSample) / 16_000] }
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
