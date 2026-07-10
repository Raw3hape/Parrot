import Foundation

/// Timing constants for call-oriented speech segmentation. Values are expressed
/// as samples so the state machine is deterministic and independent of wall time.
struct CallSegmentationConfig: Sendable, Equatable {
    let sampleRate: Int
    let minSpeechSamples: Int
    let previewIntervalSamples: Int
    let maximumUtteranceSamples: Int
    let overlapSamples: Int
    let retainedPrerollSamples: Int

    static let callDefault = CallSegmentationConfig(
        sampleRate: 16_000,
        minSpeechSamples: 2_400,          // 150 ms
        previewIntervalSamples: 20_000,   // 1.25 s
        maximumUtteranceSamples: 224_000, // 14 s
        overlapSamples: 16_000,           // 1 s
        retainedPrerollSamples: 2_400     // 150 ms
    )
}

/// A stable snapshot of one utterance. Preview snapshots are replaceable; final
/// snapshots are persisted exactly once. Generation increases at every final so
/// late preview work can be rejected by the coordinator.
struct UtteranceAudio: Sendable, Equatable {
    let samples: [Float]
    let startSample: Int
    let endSample: Int
    let generation: Int
    let forcedSplit: Bool
}

enum SpeechBoundary: Sendable, Equatable {
    case started(atSample: Int)
    case ended(atSample: Int)
}

enum UtteranceEmission: Sendable, Equatable {
    case preview(UtteranceAudio)
    case final(UtteranceAudio)
}

/// Pure audio-retention and utterance-boundary state. Voice activity decisions
/// come from Silero (or the energy fallback), keeping model I/O out of this type.
struct UtteranceAssembler: Sendable {
    private let config: CallSegmentationConfig
    private var retainedSamples: [Float] = []
    private var retainedStartSample = 0
    private var streamEndSample = 0
    private var activeStartSample: Int?
    private var nextPreviewSample: Int?
    private var generation = 0

    init(config: CallSegmentationConfig = .callDefault) {
        self.config = config
    }

    var retainedSampleCount: Int { retainedSamples.count }

    mutating func append(
        _ samples: [Float],
        absoluteStartSample: Int
    ) -> [UtteranceEmission] {
        guard !samples.isEmpty else { return [] }

        appendContiguously(samples, absoluteStartSample: absoluteStartSample)

        guard activeStartSample != nil else {
            pruneIdlePreroll()
            return []
        }

        var emissions: [UtteranceEmission] = []
        emitDuePreviews(into: &emissions)
        emitForcedFinals(into: &emissions)
        return emissions
    }

    mutating func apply(_ boundary: SpeechBoundary) -> [UtteranceEmission] {
        switch boundary {
        case .started(let requestedStart):
            guard activeStartSample == nil else { return [] }
            let start = min(max(requestedStart, retainedStartSample), streamEndSample)
            activeStartSample = start
            nextPreviewSample = start + config.previewIntervalSamples
            return []

        case .ended(let requestedEnd):
            guard let start = activeStartSample else { return [] }
            let end = min(max(requestedEnd, start), streamEndSample)
            let emissions = finalize(start: start, end: end, forced: false)
            activeStartSample = nil
            nextPreviewSample = nil
            pruneIdlePreroll()
            return emissions
        }
    }

    mutating func flush(atSample requestedEnd: Int) -> [UtteranceEmission] {
        guard let start = activeStartSample else { return [] }
        let end = min(max(requestedEnd, start), streamEndSample)
        let emissions = finalize(start: start, end: end, forced: false)
        activeStartSample = nil
        nextPreviewSample = nil
        retainedSamples.removeAll(keepingCapacity: false)
        retainedStartSample = end
        streamEndSample = end
        return emissions
    }

    private mutating func appendContiguously(
        _ newSamples: [Float],
        absoluteStartSample: Int
    ) {
        if retainedSamples.isEmpty {
            retainedStartSample = absoluteStartSample
            streamEndSample = absoluteStartSample
        }

        if absoluteStartSample > streamEndSample {
            retainedSamples.append(contentsOf: repeatElement(
                Float.zero,
                count: absoluteStartSample - streamEndSample
            ))
            streamEndSample = absoluteStartSample
        }

        let overlap = max(0, streamEndSample - absoluteStartSample)
        guard overlap < newSamples.count else { return }
        retainedSamples.append(contentsOf: newSamples.dropFirst(overlap))
        streamEndSample += newSamples.count - overlap
    }

    private mutating func emitDuePreviews(into emissions: inout [UtteranceEmission]) {
        guard let start = activeStartSample, var due = nextPreviewSample else { return }
        while due <= streamEndSample {
            if let audio = snapshot(start: start, end: due, forced: false, generation: generation) {
                emissions.append(.preview(audio))
            }
            due += config.previewIntervalSamples
        }
        nextPreviewSample = due
    }

    private mutating func emitForcedFinals(into emissions: inout [UtteranceEmission]) {
        while let start = activeStartSample,
              streamEndSample - start >= config.maximumUtteranceSamples {
            let splitEnd = start + config.maximumUtteranceSamples
            emissions += finalize(start: start, end: splitEnd, forced: true)

            // The overlap gives the recognizer acoustic context across a forced
            // boundary. A later text-merging step removes repeated leading words.
            let nextStart = max(start, splitEnd - config.overlapSamples)
            activeStartSample = nextStart
            nextPreviewSample = splitEnd + config.previewIntervalSamples
            prune(before: nextStart)
        }
    }

    private mutating func finalize(
        start: Int,
        end: Int,
        forced: Bool
    ) -> [UtteranceEmission] {
        guard end - start >= config.minSpeechSamples else { return [] }
        generation += 1
        guard let audio = snapshot(
            start: start,
            end: end,
            forced: forced,
            generation: generation
        ) else { return [] }
        return [.final(audio)]
    }

    private func snapshot(
        start: Int,
        end: Int,
        forced: Bool,
        generation: Int
    ) -> UtteranceAudio? {
        let clampedStart = max(start, retainedStartSample)
        let clampedEnd = min(end, streamEndSample)
        guard clampedEnd > clampedStart else { return nil }
        let lower = clampedStart - retainedStartSample
        let upper = clampedEnd - retainedStartSample
        guard lower >= 0, upper <= retainedSamples.count else { return nil }
        return UtteranceAudio(
            samples: Array(retainedSamples[lower..<upper]),
            startSample: clampedStart,
            endSample: clampedEnd,
            generation: generation,
            forcedSplit: forced
        )
    }

    private mutating func pruneIdlePreroll() {
        let keepFrom = max(retainedStartSample, streamEndSample - config.retainedPrerollSamples)
        prune(before: keepFrom)
    }

    private mutating func prune(before absoluteSample: Int) {
        let removable = min(
            retainedSamples.count,
            max(0, absoluteSample - retainedStartSample)
        )
        guard removable > 0 else { return }
        retainedSamples.removeFirst(removable)
        retainedStartSample += removable
    }
}
