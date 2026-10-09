import Foundation

struct SpeechRegion: Equatable, Sendable {
    let startSample: Int
    let endSample: Int
}

/// No language/model/reference text enters this detector. Offsets are integer
/// positions in the unchanged input waveform, including conservative edge pads.
enum SpeechRegionDetector {
    static func regions(samples: [Float], sampleRate: Int = 16_000) -> [SpeechRegion] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let frameSize = max(1, sampleRate / 100)
        var energies: [Double] = []
        for start in stride(from: 0, to: samples.count, by: frameSize) {
            let end = min(samples.count, start + frameSize)
            var squared = 0.0
            for index in start..<end { squared += Double(samples[index]) * Double(samples[index]) }
            energies.append(sqrt(squared / Double(end - start)))
        }
        let peak = energies.max() ?? 0
        // Digital/near-digital silence must not be sent to an autoregressive ASR.
        guard peak > 1e-6 else { return [] }
        let sorted = energies.sorted()
        let noiseFloor = sorted[min(sorted.count - 1, sorted.count / 5)]
        // A continuously spoken/very short input can have no silent noise-floor
        // sample. Cap the floor-derived threshold so it remains eligible.
        let threshold = max(1e-6, min(noiseFloor * 2.8, peak * 0.5))
        let pauseFrames = 35                    // 350 ms sustained silence
        let paddingSamples = sampleRate * 12 / 100
        let minimumVoicedFrames = 6             // retain short acknowledgements
        var core: [SpeechRegion] = []
        var first: Int?
        var last = 0
        var voiced = 0
        for index in energies.indices {
            if energies[index] > threshold {
                if first == nil { first = index }
                last = index
                voiced += 1
            } else if let start = first, index - last >= pauseFrames {
                if voiced >= minimumVoicedFrames {
                    core.append(SpeechRegion(startSample: start * frameSize,
                                             endSample: min(samples.count, (last + 1) * frameSize)))
                }
                first = nil
                voiced = 0
            }
        }
        if let start = first, voiced >= minimumVoicedFrames {
            core.append(SpeechRegion(startSample: start * frameSize,
                                     endSample: min(samples.count, (last + 1) * frameSize)))
        }
        // Never discard the only audible fragment of an extremely short reply.
        if core.isEmpty, samples.count <= sampleRate / 2 {
            return [SpeechRegion(startSample: 0, endSample: samples.count)]
        }
        var padded: [SpeechRegion] = []
        for region in core {
            let start = max(padded.last?.endSample ?? 0, region.startSample - paddingSamples)
            let end = min(samples.count, region.endSample + paddingSamples)
            if start < end { padded.append(SpeechRegion(startSample: start, endSample: end)) }
        }
        // Bound uninterrupted regions to approximately 30 s without dropping or
        // duplicating any samples. Choose the lowest energy in the final 3 s.
        let maximumSamples = sampleRate * 30
        var result: [SpeechRegion] = []
        for region in padded {
            var start = region.startSample
            while region.endSample - start > maximumSamples {
                let latest = start + maximumSamples
                let earliest = max(start + sampleRate, latest - sampleRate * 3)
                let firstFrame = earliest / frameSize
                let lastFrame = min(energies.count - 1, latest / frameSize)
                let boundaryFrame = (firstFrame...lastFrame).min {
                    energies[$0] == energies[$1] ? $0 > $1 : energies[$0] < energies[$1]
                } ?? lastFrame
                let cut = max(start + 1, min(latest, boundaryFrame * frameSize))
                result.append(SpeechRegion(startSample: start, endSample: cut))
                start = cut
            }
            if start < region.endSample { result.append(SpeechRegion(startSample: start, endSample: region.endSample)) }
        }
        return result
    }
}

struct TimedTranscript: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var speaker: String?
}

struct NormalizedTiming: Sendable {
    let text: String
    let segments: [TimedTranscript]
    let mode: String
    let adjusted: Bool
    let warning: String?
}

enum MossTimingNormalizer {
    static func plainText(_ generated: String) -> String {
        generated.replacingOccurrences(of: #"\[(?:\d+(?:[\.,]\d+)?|S\d+)\]"#,
                                       with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func normalize(generated: String, segments: [TimedTranscript], duration: Double) -> NormalizedTiming {
        let text = plainText(generated)
        let tolerance = max(0.25, min(1.0, duration * 0.05))
        var normalized: [TimedTranscript] = []
        var adjusted = false
        var reason: String?
        for var segment in segments {
            if let speaker = segment.speaker, segment.text.hasPrefix("[\(speaker)]") {
                segment.text = String(segment.text.dropFirst(speaker.count + 2))
            }
            segment.text = segment.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                  segment.end >= segment.start, segment.start <= duration,
                  segment.end <= duration + tolerance else {
                reason = "Model timestamps do not fit the audio; text uses the actual whole-window bounds."
                break
            }
            if segment.end > duration {
                segment.end = duration
                adjusted = true
            }
            if !segment.text.isEmpty { normalized.append(segment) }
        }
        let segmentedText = normalized.map(\.text).joined(separator: " ")
        if reason == nil, segmentedText != text {
            reason = "Model timestamp parsing did not cover all generated text; text uses whole-window bounds."
        }
        let hasSpeakerTiming = normalized.contains { $0.speaker != nil }
        if reason != nil || normalized.isEmpty || !hasSpeakerTiming {
            let coarse = text.isEmpty ? [] : [TimedTranscript(start: 0, end: duration, text: text, speaker: nil)]
            return NormalizedTiming(text: text, segments: coarse, mode: "window", adjusted: false, warning: reason)
        }
        return NormalizedTiming(text: text, segments: normalized, mode: "model", adjusted: adjusted, warning: nil)
    }
}
