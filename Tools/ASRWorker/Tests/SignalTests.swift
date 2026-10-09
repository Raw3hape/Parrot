import Foundation

@main
struct SignalTests {
    static func main() {
        let rate = 16_000
        func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }
        func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
            (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 170 / Float(rate)) }
        }
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { fatalError(message) }
        }
        expect(SpeechRegionDetector.regions(samples: silence(3)).isEmpty, "All-silence input must skip ASR")
        expect(SpeechRegionDetector.regions(samples: [Float](repeating: 1e-8, count: rate)).isEmpty, "Near-digital silence must skip ASR")
        let reply = SpeechRegionDetector.regions(samples: tone(0.09))
        expect(reply == [SpeechRegion(startSample: 0, endSample: 1_440)], "Very short reply must remain intact")
        let mixed = silence(0.4) + tone(2) + silence(0.7) + tone(2.4) + silence(0.5)
        let regions = SpeechRegionDetector.regions(samples: mixed)
        expect(regions.count == 2, "Sustained pause must reset language detection")
        expect(regions[0].startSample == 4_480 && regions[0].endSample == 40_320, "First region must preserve exact padded sample offsets")
        expect(regions[1].startSample == 47_680 && regions[1].endSample == 89_920, "Second region offsets must not drift")
        let weakReply = silence(0.5) + tone(1) + silence(0.7) + tone(0.2, amplitude: 0.0002) + silence(0.5)
        expect(SpeechRegionDetector.regions(samples: weakReply).count == 2, "Weak short reply after loud speech must survive")
        let quietBase = silence(0.5) + tone(2, amplitude: 0.08) + silence(0.7) + tone(2, amplitude: 0.08) + silence(0.5)
        let roomTone = quietBase.enumerated().map { $0.element + 0.02 * sin(Float($0.offset) * 2 * .pi * 65 / Float(rate)) }
        expect(SpeechRegionDetector.regions(samples: roomTone).count == 2, "A steady audible noise floor must not hide a sustained pause")
        let continuous = SpeechRegionDetector.regions(samples: tone(61))
        expect(continuous.count == 3 && continuous.first?.startSample == 0 && continuous.last?.endSample == 61 * rate, "Long speech must be bounded and fully covered")
        expect(zip(continuous, continuous.dropFirst()).allSatisfy { $0.endSample == $1.startSample }, "Safety splits must neither drop nor repeat samples")
        let valid = MossTimingNormalizer.normalize(generated: "[0.3][S01]Hello world[2.1]",
            segments: [TimedTranscript(start: 0.3, end: 2.1, text: "[S01] Hello world", speaker: "S01")], duration: 2)
        expect(valid.mode == "model" && valid.adjusted && valid.segments[0].end == 2 && valid.text == "Hello world", "Modest timestamp overshoot should clip without altering words")
        let impossible = MossTimingNormalizer.normalize(generated: "[0.3][S01]Hello world[9]",
            segments: [TimedTranscript(start: 0.3, end: 9, text: "[S01] Hello world", speaker: "S01")], duration: 2)
        expect(impossible.mode == "window" && impossible.segments == [TimedTranscript(start: 0, end: 2, text: "Hello world", speaker: nil)], "Impossible model timing needs truthful coarse fallback")
        let incompleteParsing = MossTimingNormalizer.normalize(generated: "[0][S01]One[1][1.1][S02]Two[1.8]",
            segments: [TimedTranscript(start: 0, end: 1, text: "[S01] One", speaker: "S01")], duration: 2)
        expect(incompleteParsing.mode == "window" && incompleteParsing.text == "One Two", "A timing parser must not silently omit generated words")
        print("PASS: \(checks) segmentation and timestamp edge-case checks")
    }
}
