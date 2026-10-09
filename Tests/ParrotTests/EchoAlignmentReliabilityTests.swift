import XCTest
@testable import Parrot

final class EchoReferenceTimelineTests: XCTestCase {
    func testFrameCrossesReferenceCallbacksByTimestamp() {
        var timeline = EchoReferenceTimeline()
        timeline.append(Array(repeating: 100, count: 320), at: 10)
        timeline.append(Array(repeating: 200, count: 320), at: 10.02)
        let frame = timeline.frame(at: 10.015, count: 160)
        XCTAssertEqual(frame, Array(repeating: 100, count: 80) + Array(repeating: 200, count: 80))
    }

    func testGapAndStaleReferenceCannotInventAudio() {
        var timeline = EchoReferenceTimeline()
        timeline.append(Array(repeating: 100, count: 160), at: 10)
        timeline.append(Array(repeating: 300, count: 160), at: 10.03)
        timeline.append(Array(repeating: 200, count: 160), at: 10.01)
        XCTAssertNil(timeline.frame(at: 10.005, count: 160))
        XCTAssertEqual(timeline.frame(at: 10.03, count: 160), Array(repeating: 300, count: 160))
    }

    func testNinetyMinuteCallKeepsReferenceAlignedDespiteIndependentClockDrift() {
        // One reference device runs 200 ppm faster than the microphone. At
        // 90 minutes, equal-count FIFO pairing is over a second behind. Every
        // checkpoint supplies the same timestamped callback pattern; fast-forward
        // between checkpoints avoids storing 90 minutes of disposable audio.
        let sampleRate = 16_000.0
        let framesPerCallback = 320
        let referenceRateRatio = 1.0002
        let referenceDuration = Double(framesPerCallback) / (sampleRate * referenceRateRatio)
        var timeline = EchoReferenceTimeline()
        for minute in 0...90 {
            let checkpoint = 100 + Double(minute * 60)
            let currentCallback = Int((checkpoint - 100) / referenceDuration)
            for callback in max(0, currentCallback - 30)...currentCallback + 5 {
                let marker = Int16(callback % 30_000 + 1)
                timeline.append(
                    Array(repeating: marker, count: framesPerCallback),
                    at: 100 + Double(callback) * referenceDuration
                )
            }
            let microphoneTime = 100 + Double(currentCallback) * referenceDuration + 0.005
            let expected = Array(repeating: Int16(currentCallback % 30_000 + 1), count: 160)
            XCTAssertEqual(timeline.frame(at: microphoneTime, count: 160), expected,
                           "Reference lost alignment at minute \(minute)")
            XCTAssertLessThanOrEqual(timeline.retainedChunkCount, 110)
        }
        let fifoDrift = 90 * 60.0 * (1 - 1 / referenceRateRatio)
        XCTAssertGreaterThan(fifoDrift, 1)
        // The prior 128 ms DSP tail cannot compensate for this FIFO drift.
        XCTAssertGreaterThan(fifoDrift, 0.128 * 8)
    }
}

final class EchoCancellerReliabilityTests: XCTestCase {
    func testMissingReferencePreservesAllSamplesIncludingStopTail() {
        let canceller = EchoCanceller()
        XCTAssertTrue(canceller.isActive)
        let samples = voiceSamples(count: 16_037)
        var output: [Float] = []
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + 341, samples.count)
            output.append(contentsOf: canceller.process(
                mic: Array(samples[cursor..<end]), at: 100 + Double(cursor) / 16_000
            ))
            cursor = end
        }
        output.append(contentsOf: canceller.flush())
        XCTAssertEqual(output, samples)
        XCTAssertTrue(canceller.flush().isEmpty)
    }

    func testMissingHostTimeAndRouteGapPreserveBufferedNearEndVoice() {
        let canceller = EchoCanceller()
        let first = voiceSamples(count: 337)
        let second = voiceSamples(count: 413)
        var output = canceller.process(mic: first, at: 100)
        output.append(contentsOf: canceller.process(mic: second, at: 103))
        let final: [Float] = [0.3, -0.2, 0.1]
        output.append(contentsOf: canceller.process(mic: final, at: nil))
        output.append(contentsOf: canceller.flush())
        XCTAssertEqual(output, first + second + final)
    }

    func testLateReferenceStillCancelsSyntheticSpeakerBleed() {
        let count = 16_000 * 12
        let reference = deterministicSignal(count: count, seed: 123)
        let microphone = (0..<count).map { index -> Float in
            index >= 480 ? reference[index - 480] * 0.6 : 0
        }
        let result = run(reference: reference, microphone: microphone)
        XCTAssertEqual(result.output.count, microphone.count)
        XCTAssertGreaterThan(result.statistics.alignedFrames, 1_100)
        let start = 16_000 * 8
        let before = rms(Array(microphone[start...]))
        let after = rms(Array(result.output[start...]))
        XCTAssertLessThan(after, before * 0.4, "Matched echo should fall by at least 8 dB")
    }

    func testDoubleTalkKeepsNearEndVoiceAudibleAndRecognizable() {
        let count = 16_000 * 12
        let reference = deterministicSignal(count: count, seed: 789)
        let nearEnd = voiceSamples(count: count)
        let microphone = (0..<count).map { index -> Float in
            let echo = index >= 480 ? reference[index - 480] * 0.5 : 0
            return echo + (index >= 16_000 * 4 ? nearEnd[index] : 0)
        }
        let result = run(reference: reference, microphone: microphone)
        XCTAssertEqual(result.output.count, microphone.count)
        let start = 16_000 * 8
        let tail = Array(result.output[start...])
        XCTAssertGreaterThan(rms(tail), rms(Array(nearEnd[start...])) * 0.35,
                             "Echo removal must not silence the user's own voice")
        // Speex's preprocessor can add a frame of latency; compare the waveform
        // with that fixed DSP delay rather than mistaking delay for lost speech.
        let correlations = [0, 160, 320].map { delay in
            correlation(
                Array(result.output[(start + delay)..<count]),
                Array(nearEnd[start..<(count - delay)])
            )
        }
        XCTAssertGreaterThan(correlations.max() ?? 0, 0.65)
    }

    private func run(reference: [Float], microphone: [Float])
        -> (output: [Float], statistics: EchoAlignmentStatistics) {
        let canceller = EchoCanceller()
        XCTAssertTrue(canceller.isActive)
        var output: [Float] = []
        for cursor in stride(from: 0, to: microphone.count, by: 320) {
            let end = min(cursor + 320, microphone.count)
            let time = 100 + Double(cursor) / 16_000
            // Deliver the mic first. Timestamp matching must tolerate the
            // speaker-reference callback arriving later in wall-clock order.
            output.append(contentsOf: canceller.process(
                mic: Array(microphone[cursor..<end]), at: time
            ))
            canceller.pushReference(Array(reference[cursor..<end]), at: time)
        }
        output.append(contentsOf: canceller.flush())
        return (output, canceller.alignmentStatistics)
    }

    private func deterministicSignal(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.35
        }
    }

    private func voiceSamples(count: Int) -> [Float] {
        (0..<count).map { index in
            let t = Double(index) / 16_000
            let envelope = 0.7 + 0.3 * sin(2 * .pi * 3.1 * t)
            return Float(envelope * (
                0.12 * sin(2 * .pi * 173 * t)
                + 0.06 * sin(2 * .pi * 347 * t)
                + 0.025 * sin(2 * .pi * 521 * t)
            ))
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0
        var energyA = 0.0
        var energyB = 0.0
        for (left, right) in zip(a, b) {
            dot += Double(left * right)
            energyA += Double(left * left)
            energyB += Double(right * right)
        }
        return dot / max(0.000_001, sqrt(energyA * energyB))
    }
}
