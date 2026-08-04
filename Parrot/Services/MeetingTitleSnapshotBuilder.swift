import CryptoKit
import Foundation

struct MeetingTitleSnapshotBuilder: Sendable {
    let maxLeafUTF8Bytes: Int

    // A byte can be a complete tokenizer unit in the worst case. Seven KiB
    // leaves leave room for the chat template, instructions, and output inside
    // the runtime's 8K context without losing any transcript bytes.
    init(maxLeafUTF8Bytes: Int = 7 * 1024) {
        self.maxLeafUTF8Bytes = max(1, maxLeafUTF8Bytes)
    }

    func build(from segments: [TranscriptSegment]) -> MeetingTitleSnapshot {
        build(from: segments.map(MeetingTitleSourceSegment.init))
    }

    func build(from sourceSegments: [MeetingTitleSourceSegment]) -> MeetingTitleSnapshot {
        let ordered = sourceSegments
            .sorted(by: Self.segmentOrder)
            .map {
                MeetingTitleSegmentSnapshot(
                    id: $0.id,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    speakerLabel: $0.speakerLabel,
                    text: $0.text
                )
            }

        var leaves: [MeetingTitleLeaf] = []
        var pendingFragments: [MeetingTitleTextFragment] = []
        var pendingByteCount = 0

        func flush() {
            guard !pendingFragments.isEmpty else { return }
            leaves.append(MeetingTitleLeaf(id: leaves.count, fragments: pendingFragments))
            pendingFragments.removeAll(keepingCapacity: true)
            pendingByteCount = 0
        }

        for segment in ordered {
            for range in Self.utf8Ranges(in: segment.text, maximumBytes: maxLeafUTF8Bytes) {
                let fragment = MeetingTitleTextFragment(
                    segmentID: segment.id,
                    lowerUTF8Offset: range.lowerBound,
                    upperUTF8Offset: range.upperBound
                )
                if !pendingFragments.isEmpty,
                   pendingByteCount + fragment.utf8ByteCount > maxLeafUTF8Bytes {
                    flush()
                }
                pendingFragments.append(fragment)
                pendingByteCount += fragment.utf8ByteCount
                if pendingByteCount >= maxLeafUTF8Bytes {
                    flush()
                }
            }
        }
        flush()

        let sourceByteCount = ordered.reduce(0) { $0 + $1.text.utf8.count }
        let coveredByteCount = leaves.reduce(0) { sum, leaf in
            sum + leaf.fragments.reduce(0) { $0 + $1.utf8ByteCount }
        }
        let exactRanges = Self.hasExactRangeCoverage(segments: ordered, leaves: leaves)
        let receipt = MeetingTitleCoverageReceipt(
            sourceSegmentIDs: ordered.map(\.id),
            expectedLeafIDs: leaves.map(\.id),
            consumedLeafIDs: leaves.map(\.id),
            sourceUTF8ByteCount: sourceByteCount,
            coveredUTF8ByteCount: coveredByteCount,
            rangeCoverageIsExact: exactRanges
        )

        return MeetingTitleSnapshot(
            orderedSegments: ordered,
            leaves: leaves,
            fingerprint: Self.fingerprint(for: ordered),
            coverageReceipt: receipt
        )
    }

    private static func segmentOrder(
        _ lhs: MeetingTitleSourceSegment,
        _ rhs: MeetingTitleSourceSegment
    ) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Returns contiguous ranges ending only at Unicode-scalar boundaries. A
    /// single scalar may exceed a deliberately tiny test limit by at most four
    /// UTF-8 bytes; production limits are much larger.
    private static func utf8Ranges(in text: String, maximumBytes: Int) -> [Range<Int>] {
        guard !text.isEmpty else { return [0..<0] }

        var scalarEnds: [Int] = []
        var whitespaceEnds: Set<Int> = []
        var byteOffset = 0
        for scalar in text.unicodeScalars {
            byteOffset += scalar.utf8.count
            scalarEnds.append(byteOffset)
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                whitespaceEnds.insert(byteOffset)
            }
        }

        var result: [Range<Int>] = []
        var lower = 0
        var boundaryIndex = 0
        while lower < byteOffset {
            let target = lower + maximumBytes
            var lastAllowed: Int?
            var lastWhitespace: Int?
            var scan = boundaryIndex
            while scan < scalarEnds.count, scalarEnds[scan] <= target {
                let boundary = scalarEnds[scan]
                lastAllowed = boundary
                if whitespaceEnds.contains(boundary) { lastWhitespace = boundary }
                scan += 1
            }

            let upper: Int
            if lastAllowed == byteOffset {
                upper = byteOffset
            } else if let whitespace = lastWhitespace,
               whitespace - lower >= max(1, maximumBytes / 2) {
                upper = whitespace
            } else if let allowed = lastAllowed, allowed > lower {
                upper = allowed
            } else {
                upper = scalarEnds.first(where: { $0 > lower }) ?? byteOffset
            }
            result.append(lower..<upper)
            lower = upper
            while boundaryIndex < scalarEnds.count, scalarEnds[boundaryIndex] <= lower {
                boundaryIndex += 1
            }
        }
        return result
    }

    private static func hasExactRangeCoverage(
        segments: [MeetingTitleSegmentSnapshot],
        leaves: [MeetingTitleLeaf]
    ) -> Bool {
        let allFragments = leaves.flatMap(\.fragments)
        let knownSegmentIDs = Set(segments.map(\.id))
        var fragmentsBySegment: [UUID: [MeetingTitleTextFragment]] = [:]
        fragmentsBySegment.reserveCapacity(segments.count)
        for fragment in allFragments {
            guard knownSegmentIDs.contains(fragment.segmentID) else { return false }
            fragmentsBySegment[fragment.segmentID, default: []].append(fragment)
        }
        for segment in segments {
            let ranges = (fragmentsBySegment[segment.id] ?? [])
                .sorted {
                    if $0.lowerUTF8Offset != $1.lowerUTF8Offset {
                        return $0.lowerUTF8Offset < $1.lowerUTF8Offset
                    }
                    return $0.upperUTF8Offset < $1.upperUTF8Offset
                }
            guard !ranges.isEmpty else { return false }
            var expectedLower = 0
            for range in ranges {
                guard range.lowerUTF8Offset == expectedLower else { return false }
                guard range.upperUTF8Offset >= range.lowerUTF8Offset else { return false }
                expectedLower = range.upperUTF8Offset
            }
            guard expectedLower == segment.text.utf8.count else { return false }
        }
        return true
    }

    private static func fingerprint(for segments: [MeetingTitleSegmentSnapshot]) -> String {
        var bytes = Data()
        append(UInt64(segments.count), to: &bytes)
        for segment in segments {
            append(segment.id.uuidString, to: &bytes)
            append(segment.startTime.bitPattern, to: &bytes)
            append(segment.endTime.bitPattern, to: &bytes)
            if let speaker = segment.speakerLabel {
                bytes.append(1)
                append(speaker, to: &bytes)
            } else {
                bytes.append(0)
            }
            append(segment.text, to: &bytes)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: String, to data: inout Data) {
        let encoded = Data(value.utf8)
        append(UInt64(encoded.count), to: &data)
        data.append(encoded)
    }
}
