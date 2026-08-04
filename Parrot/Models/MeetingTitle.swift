import Foundation

/// A value-only copy of a transcript segment used by the title pipeline.
/// The raw text is intentionally preserved exactly as persisted.
struct MeetingTitleSourceSegment: Sendable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerLabel: String?
    let text: String

    init(
        id: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerLabel: String?,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speakerLabel = speakerLabel
        self.text = text
    }

    init(_ segment: TranscriptSegment) {
        self.init(
            id: segment.id,
            startTime: segment.startTime,
            endTime: segment.endTime,
            speakerLabel: segment.speakerLabel,
            text: segment.text
        )
    }
}

struct MeetingTitleSegmentSnapshot: Sendable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerLabel: String?
    let text: String
}

struct MeetingTitleTextFragment: Sendable, Equatable {
    let segmentID: UUID
    let lowerUTF8Offset: Int
    let upperUTF8Offset: Int

    var utf8ByteCount: Int { upperUTF8Offset - lowerUTF8Offset }
}

struct MeetingTitleLeaf: Sendable, Equatable {
    let id: Int
    let fragments: [MeetingTitleTextFragment]

    var utf8ByteCount: Int {
        fragments.reduce(0) { $0 + $1.utf8ByteCount }
    }
}

struct MeetingTitleCoverageReceipt: Sendable, Equatable {
    let sourceSegmentIDs: [UUID]
    let expectedLeafIDs: [Int]
    let consumedLeafIDs: [Int]
    let sourceUTF8ByteCount: Int
    let coveredUTF8ByteCount: Int
    let rangeCoverageIsExact: Bool

    var isExact: Bool {
        rangeCoverageIsExact
            && Set(sourceSegmentIDs).count == sourceSegmentIDs.count
            && sourceUTF8ByteCount == coveredUTF8ByteCount
            && consumedLeafIDs.count == expectedLeafIDs.count
            && Set(consumedLeafIDs).count == consumedLeafIDs.count
            && consumedLeafIDs.sorted() == expectedLeafIDs.sorted()
    }

    func consuming(_ leafIDs: [Int]) -> MeetingTitleCoverageReceipt {
        MeetingTitleCoverageReceipt(
            sourceSegmentIDs: sourceSegmentIDs,
            expectedLeafIDs: expectedLeafIDs,
            consumedLeafIDs: leafIDs,
            sourceUTF8ByteCount: sourceUTF8ByteCount,
            coveredUTF8ByteCount: coveredUTF8ByteCount,
            rangeCoverageIsExact: rangeCoverageIsExact
        )
    }
}

struct MeetingTitleSnapshot: Sendable, Equatable {
    let orderedSegments: [MeetingTitleSegmentSnapshot]
    let leaves: [MeetingTitleLeaf]
    let fingerprint: String
    let coverageReceipt: MeetingTitleCoverageReceipt
    private let segmentIndexByID: [UUID: Int]

    init(
        orderedSegments: [MeetingTitleSegmentSnapshot],
        leaves: [MeetingTitleLeaf],
        fingerprint: String,
        coverageReceipt: MeetingTitleCoverageReceipt
    ) {
        self.orderedSegments = orderedSegments
        self.leaves = leaves
        self.fingerprint = fingerprint
        self.coverageReceipt = coverageReceipt
        self.segmentIndexByID = Dictionary(
            uniqueKeysWithValues: orderedSegments.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    func text(for fragment: MeetingTitleTextFragment) -> String? {
        guard let index = segmentIndexByID[fragment.segmentID] else {
            return nil
        }
        let segment = orderedSegments[index]
        let bytes = segment.text.utf8
        guard
            fragment.lowerUTF8Offset >= 0,
            fragment.upperUTF8Offset >= fragment.lowerUTF8Offset,
            fragment.upperUTF8Offset <= bytes.count,
            let lower = bytes.index(bytes.startIndex, offsetBy: fragment.lowerUTF8Offset, limitedBy: bytes.endIndex),
            let upper = bytes.index(bytes.startIndex, offsetBy: fragment.upperUTF8Offset, limitedBy: bytes.endIndex)
        else {
            return nil
        }
        return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }

    func reconstructedText(for segmentID: UUID) -> String? {
        guard segmentIndexByID[segmentID] != nil else { return nil }
        let fragments = leaves
            .sorted { $0.id < $1.id }
            .flatMap(\.fragments)
            .filter { $0.segmentID == segmentID }
            .sorted {
                if $0.lowerUTF8Offset != $1.lowerUTF8Offset {
                    return $0.lowerUTF8Offset < $1.lowerUTF8Offset
                }
                return $0.upperUTF8Offset < $1.upperUTF8Offset
            }
        return fragments.compactMap { text(for: $0) }.joined()
    }
}

struct MeetingTitleGeneration: Sendable, Equatable {
    let title: String?
    let fingerprint: String
    let coverageReceipt: MeetingTitleCoverageReceipt
    let reductionDepth: Int
    let disposition: MeetingTitleGenerationDisposition

    init(
        title: String?,
        fingerprint: String,
        coverageReceipt: MeetingTitleCoverageReceipt,
        reductionDepth: Int,
        disposition: MeetingTitleGenerationDisposition = .completed
    ) {
        self.title = title
        self.fingerprint = fingerprint
        self.coverageReceipt = coverageReceipt
        self.reductionDepth = reductionDepth
        self.disposition = disposition
    }
}

enum MeetingTitleGenerationDisposition: Sendable, Equatable {
    case completed
    case deferred(MeetingTitleDeferralReason)
}

enum MeetingTitleDeferralReason: Sendable, Equatable {
    case memoryPressure
    case runtimeUnavailable
    case runtimeFailure
}

enum MeetingTitle {
    static func isValid(_ title: String) -> Bool {
        guard title == title.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        guard !title.contains("\n"), !title.contains("\r"), title.count <= 64 else { return false }
        let words = title.split(whereSeparator: \.isWhitespace)
        guard (2...4).contains(words.count) else { return false }
        return words.allSatisfy { word in
            word.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
    }
}
