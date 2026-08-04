import Foundation

enum BestTranscriptSpeaker: String, Codable, CaseIterable, Sendable {
    case me = "Me"
    case them = "Them"

    var source: AudioSource {
        switch self {
        case .me: .me
        case .them: .them
        }
    }
}

struct BestTranscriptWord: Codable, Equatable, Sendable {
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var probability: Float?
}

struct BestTranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var speaker: BestTranscriptSpeaker
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var confidence: Float?
    var detectedLanguage: String?
    var words: [BestTranscriptWord]
}

struct BestRawWhisperWord: Equatable, Sendable {
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var probability: Float?
}

struct BestRawWhisperSegment: Equatable, Sendable {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var averageLogProbability: Float
    var detectedLanguage: String?
    var words: [BestRawWhisperWord]
}

enum BestWhisperResultMapper {
    static func map(
        _ rawSegments: [BestRawWhisperSegment],
        speaker: BestTranscriptSpeaker,
        absoluteWindowStart: TimeInterval
    ) -> [BestTranscriptSegment] {
        rawSegments.compactMap { raw in
            guard raw.startTime.isFinite,
                  raw.endTime.isFinite,
                  raw.startTime >= 0,
                  raw.endTime > raw.startTime else { return nil }
            let text = cleaned(raw.text)
            guard !text.isEmpty else { return nil }

            let words = raw.words.compactMap { word -> BestTranscriptWord? in
                guard word.startTime.isFinite,
                      word.endTime.isFinite,
                      word.startTime >= 0,
                      word.endTime > word.startTime else { return nil }
                return BestTranscriptWord(
                    text: word.text,
                    startTime: absoluteWindowStart + word.startTime,
                    endTime: absoluteWindowStart + word.endTime,
                    probability: word.probability
                )
            }
            return BestTranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: absoluteWindowStart + raw.startTime,
                endTime: absoluteWindowStart + raw.endTime,
                text: text,
                confidence: WhisperModelService.normalizedConfidence(
                    [raw.averageLogProbability]
                ),
                detectedLanguage: raw.detectedLanguage,
                words: words
            )
        }
    }

    static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"<\|[^|>]*\|>"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum BestTranscriptAlignmentQuality: String, Codable, Sendable {
    case exact
    case estimated
}

struct BestAudioTrackFingerprint: Codable, Equatable, Sendable {
    var speaker: BestTranscriptSpeaker
    var fileSize: UInt64
    var modifiedAtNanoseconds: UInt64
    var frameCount: Int64
    var sampleRate: Double
}

struct BestTranscriptionFingerprint: Codable, Equatable, Sendable {
    var modelID: String
    var pipelineVersion: Int
    var vocabularyHash: String
    var tracks: [BestAudioTrackFingerprint]
}

struct BestTranscriptArtifact: Codable, Equatable, Sendable {
    var meetingID: UUID
    var generatedAt: Date
    var modelID: String
    var pipelineVersion: Int
    var fingerprint: BestTranscriptionFingerprint
    var alignmentQuality: BestTranscriptAlignmentQuality
    var warnings: [String]
    var segments: [BestTranscriptSegment]
}

enum BestTranscriptionPersistentState: String, Codable, Sendable {
    case queued
    case validatingInput
    case waitingForModel
    case transcribing
    case merging
    case exporting
    case completed
    case interrupted
    case cancelled
    case failed
}

struct BestTranscriptionManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var meetingID: UUID
    var state: BestTranscriptionPersistentState
    var fingerprint: BestTranscriptionFingerprint
    var artifactFilename: String?
    var updatedAt: Date
    var lastError: String?

    static func completed(
        meetingID: UUID,
        fingerprint: BestTranscriptionFingerprint,
        artifactFilename: String
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            meetingID: meetingID,
            state: .completed,
            fingerprint: fingerprint,
            artifactFilename: artifactFilename,
            updatedAt: .now,
            lastError: nil
        )
    }

    func hasValidCompletedArtifact(for candidate: BestTranscriptionFingerprint) -> Bool {
        schemaVersion == Self.schemaVersion
            && state == .completed
            && fingerprint == candidate
            && artifactFilename?.isEmpty == false
    }
}

struct BestAudioWindow: Codable, Equatable, Sendable {
    var index: Int
    var startFrame: Int64
    var endFrame: Int64
    var ownedStartFrame: Int64
    var ownedEndFrame: Int64
}

enum BestAudioWindowPlanner {
    static func plan(
        totalFrames: Int64,
        sampleRate: Double,
        windowSeconds: TimeInterval = 30,
        overlapSeconds: TimeInterval = 2
    ) -> [BestAudioWindow] {
        guard totalFrames > 0, sampleRate > 0 else { return [] }
        let windowFrames = max(1, Int64((windowSeconds * sampleRate).rounded()))
        let overlapFrames = min(
            max(0, Int64((overlapSeconds * sampleRate).rounded())),
            max(0, windowFrames - 1)
        )
        let strideFrames = max(1, windowFrames - overlapFrames)
        let halfOverlap = overlapFrames / 2

        var starts: [Int64] = []
        var start: Int64 = 0
        while start < totalFrames {
            starts.append(start)
            start += strideFrames
        }

        return starts.enumerated().map { index, startFrame in
            let endFrame = min(totalFrames, startFrame + windowFrames)
            let ownedStart = index == 0 ? 0 : min(endFrame, startFrame + halfOverlap)
            let ownedEnd: Int64
            if index == starts.count - 1 {
                ownedEnd = totalFrames
            } else {
                ownedEnd = min(totalFrames, starts[index + 1] + halfOverlap)
            }
            return BestAudioWindow(
                index: index,
                startFrame: startFrame,
                endFrame: endFrame,
                ownedStartFrame: ownedStart,
                ownedEndFrame: max(ownedStart, ownedEnd)
            )
        }
    }
}

enum BestWindowOwnership {
    static func wordsOwned(
        _ words: [BestTranscriptWord],
        by window: BestAudioWindow,
        sampleRate: Double
    ) -> [BestTranscriptWord] {
        guard sampleRate > 0 else { return [] }
        return words.filter { word in
            let midpoint = (word.startTime + word.endTime) / 2
            let frame = Int64((midpoint * sampleRate).rounded(.down))
            return frame >= window.ownedStartFrame && frame < window.ownedEndFrame
        }
    }

    static func segmentsOwned(
        _ segments: [BestTranscriptSegment],
        by window: BestAudioWindow,
        sampleRate: Double
    ) -> [BestTranscriptSegment] {
        segments.compactMap { segment in
            if segment.words.isEmpty {
                let midpoint = (segment.startTime + segment.endTime) / 2
                let frame = Int64((midpoint * sampleRate).rounded(.down))
                return frame >= window.ownedStartFrame && frame < window.ownedEndFrame
                    ? segment
                    : nil
            }

            let words = wordsOwned(segment.words, by: window, sampleRate: sampleRate)
            guard let first = words.first, let last = words.last else { return nil }
            var owned = segment
            owned.startTime = first.startTime
            owned.endTime = last.endTime
            owned.words = words
            owned.text = BestWhisperResultMapper.cleaned(
                words.map(\.text).joined()
            )
            return owned.text.isEmpty ? nil : owned
        }
    }
}

enum BestTranscriptMerger {
    static func merge(_ input: [BestTranscriptSegment]) -> [BestTranscriptSegment] {
        let sorted = input
            .filter {
                $0.startTime.isFinite
                    && $0.endTime.isFinite
                    && $0.startTime >= 0
                    && $0.endTime > $0.startTime
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted(by: stableOrder)

        var result: [BestTranscriptSegment] = []
        for candidate in sorted {
            if let echoIndex = result.lastIndex(where: { isCrossTrackEcho($0, candidate) }) {
                if candidate.speaker == .them && result[echoIndex].speaker == .me {
                    result[echoIndex] = candidate
                    result.sort(by: stableOrder)
                }
                continue
            }
            result.append(candidate)
        }
        return result.sorted(by: stableOrder)
    }

    private static func stableOrder(
        _ lhs: BestTranscriptSegment,
        _ rhs: BestTranscriptSegment
    ) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.speaker != rhs.speaker { return lhs.speaker == .them }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func isCrossTrackEcho(
        _ lhs: BestTranscriptSegment,
        _ rhs: BestTranscriptSegment
    ) -> Bool {
        guard lhs.speaker != rhs.speaker else { return false }
        let leftTokens = normalizedTokens(lhs.text)
        let rightTokens = normalizedTokens(rhs.text)
        guard min(leftTokens.count, rightTokens.count) >= 4 else { return false }

        let overlap = max(0, min(lhs.endTime, rhs.endTime) - max(lhs.startTime, rhs.startTime))
        let shorterDuration = min(lhs.endTime - lhs.startTime, rhs.endTime - rhs.startTime)
        guard shorterDuration > 0, overlap / shorterDuration >= 0.6 else { return false }

        let leftSet = Set(leftTokens)
        let rightSet = Set(rightTokens)
        let union = leftSet.union(rightSet).count
        guard union > 0 else { return false }
        let similarity = Double(leftSet.intersection(rightSet).count) / Double(union)
        return similarity >= 0.85
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

enum BestTranscriptionSignalPolicy {
    static func isSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var peak: Float = 0
        for sample in samples where sample.isFinite {
            peak = max(peak, abs(sample))
            if peak >= 0.0001 { return false }
        }
        return true
    }
}
