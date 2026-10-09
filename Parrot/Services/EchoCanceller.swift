import Foundation
import CSpeexDSP

/// A bounded reference timeline on the common host clock. Each capture callback
/// re-anchors its first sample, so an independent device clock cannot accumulate
/// minutes of FIFO drift. Gaps are unavailable reference, never invented speech.
struct EchoReferenceTimeline {
    private struct Chunk {
        let start: TimeInterval
        let samples: [Int16]
    }

    private var chunks: [Chunk] = []
    private var head = 0
    private let sampleRate = 16_000.0
    private let historySeconds = 2.0

    var retainedChunkCount: Int { chunks.count - head }

    mutating func append(_ samples: [Int16], at start: TimeInterval) {
        guard !samples.isEmpty, start.isFinite, start >= 0 else { return }
        // A delayed reference from before the last callback cannot replace the
        // timeline belonging to the current route.
        if let latest = chunks.last, start <= latest.start { return }
        chunks.append(Chunk(start: start, samples: samples))
        let oldestAllowed = start + Double(samples.count) / sampleRate - historySeconds
        while head < chunks.count,
              chunks[head].start + Double(chunks[head].samples.count) / sampleRate < oldestAllowed {
            head += 1
        }
        if head > 0, head * 2 >= chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
    }

    func frame(at start: TimeInterval, count: Int) -> [Int16]? {
        guard start.isFinite, count > 0, head < chunks.count else { return nil }
        var low = head
        var high = chunks.count
        while low < high {
            let middle = low + (high - low) / 2
            if chunks[middle].start <= start { low = middle + 1 }
            else { high = middle }
        }
        var index = max(head, low - 1)
        var output: [Int16] = []
        output.reserveCapacity(count)
        for sample in 0..<count {
            let time = start + Double(sample) / sampleRate
            while index + 1 < chunks.count, chunks[index + 1].start <= time {
                index += 1
            }
            let chunk = chunks[index]
            let positionInSamples = (time - chunk.start) * sampleRate
            // Half-sample rounding tolerates conversion arithmetic, but a real
            // timestamp gap bypasses cancellation for the entire mic frame.
            guard positionInSamples >= -0.5,
                  positionInSamples < Double(chunk.samples.count) else { return nil }
            let position = max(0, min(chunk.samples.count - 1,
                                      Int(positionInSamples.rounded())))
            output.append(chunk.samples[position])
        }
        return output
    }
}

struct EchoAlignmentStatistics: Sendable {
    var alignedFrames = 0
    var passthroughFrames = 0
}

/// SpeexDSP echo cancellation at 16 kHz mono with timestamp-aligned reference.
/// Missing timestamps/reference pass the mic through; Stop flushes every sample.
final class EchoCanceller {
    private struct MicrophoneFrame {
        let start: TimeInterval
        let samples: [Float]
    }

    private var echoState: OpaquePointer?
    private var preprocess: OpaquePointer?
    private let frameSize = 160
    private let sampleRate = 16_000.0
    // SCK can deliver the speaker reference after the matching mic tap. Bounded
    // look-ahead gives it time to arrive without waiting for reference forever.
    private let lookAheadSeconds = 0.1
    private let referenceLock = NSLock()
    private var reference = EchoReferenceTimeline()
    // A device restart can briefly overlap old/new tap callbacks. Serialize DSP
    // as well as its accumulators; reference delivery has its own short lock.
    private let processLock = NSLock()
    private var partialMic: [Float] = []
    private var partialMicStart: TimeInterval?
    private var pendingFrames: [MicrophoneFrame] = []
    private var pendingHead = 0
    private var latestMicEnd: TimeInterval?
    private var hadReference = false
    private var statistics = EchoAlignmentStatistics()

    var isActive: Bool { echoState != nil && preprocess != nil }

    var alignmentStatistics: EchoAlignmentStatistics {
        processLock.lock(); defer { processLock.unlock() }
        return statistics
    }

    init() {
        echoState = speex_echo_state_init(Int32(frameSize), 2048)
        var rate: Int32 = 16_000
        if let echoState {
            _ = speex_echo_ctl(echoState, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        }
        preprocess = speex_preprocess_state_init(Int32(frameSize), rate)
        if let preprocess, let echoState {
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE,
                                     UnsafeMutableRawPointer(echoState))
            // This path removes echo. Keep general denoising out of the near-end
            // voice and bound residual suppression during double talk.
            var denoise: Int32 = 0
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DENOISE, &denoise)
            var nearEndEchoSuppression: Int32 = -6
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE,
                                     &nearEndEchoSuppression)
        }
    }

    deinit {
        if let echoState { speex_echo_state_destroy(echoState) }
        if let preprocess { speex_preprocess_state_destroy(preprocess) }
    }

    func pushReference(_ samples: [Float], at timestamp: TimeInterval) {
        guard !samples.isEmpty, timestamp.isFinite, timestamp >= 0 else { return }
        let integers = samples.map(Self.toInt16)
        referenceLock.lock(); defer { referenceLock.unlock() }
        reference.append(integers, at: timestamp)
    }

    func process(mic samples: [Float], at timestamp: TimeInterval?) -> [Float] {
        guard isActive, !samples.isEmpty else { return samples }
        processLock.lock(); defer { processLock.unlock() }
        guard let timestamp, timestamp.isFinite, timestamp >= 0 else {
            return flushLocked(cancelEcho: false) + samples
        }

        var output: [Float] = []
        if let latestMicEnd, abs(timestamp - latestMicEnd) > 0.1 {
            // Do not join a partial frame across an unplug/restart gap or a
            // backwards clock. Preserve its original mic samples instead.
            output = flushLocked(cancelEcho: false)
        }
        var cursor = 0
        while cursor < samples.count {
            if partialMic.isEmpty {
                partialMicStart = timestamp + Double(cursor) / sampleRate
            }
            let take = min(frameSize - partialMic.count, samples.count - cursor)
            partialMic.append(contentsOf: samples[cursor ..< cursor + take])
            cursor += take
            if partialMic.count == frameSize {
                pendingFrames.append(MicrophoneFrame(
                    start: partialMicStart!, samples: partialMic
                ))
                partialMic.removeAll(keepingCapacity: true)
                partialMicStart = nil
            }
        }
        latestMicEnd = timestamp + Double(samples.count) / sampleRate
        output.append(contentsOf: drainFrames(
            through: latestMicEnd! - lookAheadSeconds, cancelEcho: true
        ))
        return output
    }

    /// Called after tap callbacks have drained. Includes the incomplete final
    /// 10 ms frame unchanged, so the user's last word is never discarded.
    func flush() -> [Float] {
        processLock.lock(); defer { processLock.unlock() }
        return flushLocked(cancelEcho: true)
    }

    private func flushLocked(cancelEcho: Bool) -> [Float] {
        var output = drainFrames(through: .infinity, cancelEcho: cancelEcho)
        output.append(contentsOf: partialMic)
        partialMic.removeAll(keepingCapacity: true)
        partialMicStart = nil
        latestMicEnd = nil
        if let echoState { speex_echo_state_reset(echoState) }
        hadReference = false
        return output
    }

    private func drainFrames(through cutoff: TimeInterval, cancelEcho: Bool) -> [Float] {
        var output: [Float] = []
        while pendingHead < pendingFrames.count {
            let frame = pendingFrames[pendingHead]
            guard frame.start + Double(frameSize) / sampleRate <= cutoff + 0.000_001 else { break }
            pendingHead += 1
            referenceLock.lock()
            let farEnd = cancelEcho ? reference.frame(at: frame.start, count: frameSize) : nil
            referenceLock.unlock()
            guard let farEnd, let echoState, let preprocess else {
                if hadReference, let echoState { speex_echo_state_reset(echoState) }
                hadReference = false
                statistics.passthroughFrames += 1
                output.append(contentsOf: frame.samples)
                continue
            }
            hadReference = true
            statistics.alignedFrames += 1
            let microphone = frame.samples.map(Self.toInt16)
            var cleaned = [Int16](repeating: 0, count: frameSize)
            microphone.withUnsafeBufferPointer { mic in
                farEnd.withUnsafeBufferPointer { ref in
                    speex_echo_cancellation(echoState, mic.baseAddress, ref.baseAddress, &cleaned)
                }
            }
            _ = speex_preprocess_run(preprocess, &cleaned)
            output.append(contentsOf: cleaned.map { Float($0) / 32767 })
        }
        if pendingHead > 0, pendingHead * 2 >= pendingFrames.count {
            pendingFrames.removeFirst(pendingHead)
            pendingHead = 0
        }
        return output
    }

    private static func toInt16(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-1, min(1, value)) * 32767)
    }
}
