import Foundation
import NaturalLanguage

/// A deterministic, network-free title generator. It maps every transcript
/// leaf once, then hierarchically reduces the lexical evidence. Transcript text
/// is never interpreted as an instruction and no raw copy is persisted.
struct LocalMeetingTitleGenerator: Sendable {
    /// Each persisted map/reduce node retains at most this many phrases. The
    /// cap is deliberately fixed so a transcript with entirely unique words
    /// cannot make candidate memory grow with meeting duration.
    static let maximumRetainedCandidatesPerNode = 256
    static let maximumRetainedAnchorsPerNode = 128

    private static let maximumReductionFanIn = 64
    private static let temporalBinCount = 32
    private static let longMeetingLeafThreshold = 8
    private static let maximumSkipDistance = 6
    fileprivate static let maximumRememberedSegmentIDsPerCandidate = 100
    private let maxReductionFanIn: Int

    init(maxReductionFanIn: Int = 16) {
        self.maxReductionFanIn = min(
            Self.maximumReductionFanIn,
            max(2, maxReductionFanIn)
        )
    }

    func generate(from snapshot: MeetingTitleSnapshot) -> MeetingTitleGeneration {
        guard !Task.isCancelled else { return cancelledGeneration(for: snapshot, depth: 0) }
        guard snapshot.coverageReceipt.isExact else {
            return MeetingTitleGeneration(
                title: nil,
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 0
            )
        }

        guard var nodes = mapEveryLeafOnce(snapshot) else {
            return cancelledGeneration(for: snapshot, depth: 0)
        }
        var depth = nodes.isEmpty ? 0 : 1
        while nodes.count > 1 {
            guard !Task.isCancelled else { return cancelledGeneration(for: snapshot, depth: depth) }
            var reduced: [ReductionNode] = []
            reduced.reserveCapacity((nodes.count + maxReductionFanIn - 1) / maxReductionFanIn)
            var index = 0
            while index < nodes.count {
                guard !Task.isCancelled else {
                    return cancelledGeneration(for: snapshot, depth: depth)
                }
                let upper = min(nodes.count, index + maxReductionFanIn)
                guard let node = merge(nodes[index..<upper]) else {
                    return cancelledGeneration(for: snapshot, depth: depth)
                }
                reduced.append(node)
                index = upper
            }
            nodes = reduced
            depth += 1
        }

        let final = nodes.first ?? ReductionNode()
        let consumedLeafIDs = final.leafIDs
        let receipt = snapshot.coverageReceipt.consuming(consumedLeafIDs)
        guard !Task.isCancelled else { return cancelledGeneration(for: snapshot, depth: depth) }
        let title = receipt.isExact
            ? selectTitle(
                from: final.candidates,
                anchors: final.anchors,
                totalLeafCount: snapshot.leaves.count
            )
            : nil
        return MeetingTitleGeneration(
            title: title,
            fingerprint: snapshot.fingerprint,
            coverageReceipt: receipt,
            reductionDepth: depth
        )
    }

    /// Maps the snapshot's already bounded fragments instead of reloading a
    /// whole oversized segment into the tokenizer. Every leaf creates exactly
    /// one node, including silent leaves, so the coverage receipt stays exact.
    private func mapEveryLeafOnce(_ snapshot: MeetingTitleSnapshot) -> [ReductionNode]? {
        var nodes: [ReductionNode] = []
        nodes.reserveCapacity(snapshot.leaves.count)
        var previousSegmentID: UUID?
        var carry: [LexicalWord] = []
        var canBridge = false
        let segmentBinByID = Dictionary(uniqueKeysWithValues: snapshot.orderedSegments.enumerated().map {
            ($0.element.id, Self.temporalBin(for: $0.offset, totalLeafCount: snapshot.orderedSegments.count))
        })
        for leaf in snapshot.leaves {
            guard !Task.isCancelled else { return nil }
            var node = ReductionNode(leafIDs: [leaf.id])
            for fragment in leaf.fragments {
                guard !Task.isCancelled, let text = snapshot.text(for: fragment) else {
                    return nil
                }
                let temporalBin = segmentBinByID[fragment.segmentID] ?? 0
                guard let sequences = Self.tokenSequences(in: text) else { return nil }
                if previousSegmentID == fragment.segmentID,
                   canBridge,
                   !carry.isEmpty,
                   let firstSequence = sequences.first,
                   !firstSequence.isEmpty {
                    let bridge = carry + firstSequence.prefix(3)
                    guard accumulateCandidates(
                        from: Array(bridge),
                        segmentID: fragment.segmentID,
                        leafID: leaf.id,
                        temporalBin: temporalBin,
                        kind: .observed,
                        crossingBoundaryAt: carry.count,
                        into: &node.candidates
                    ) else { return nil }
                }
                for sequence in sequences {
                    accumulateAnchors(
                        from: sequence,
                        segmentID: fragment.segmentID,
                        leafID: leaf.id,
                        temporalBin: temporalBin,
                        into: &node.anchors
                    )
                    guard accumulateCandidates(
                        from: sequence,
                        segmentID: fragment.segmentID,
                        leafID: leaf.id,
                        temporalBin: temporalBin,
                        kind: .observed,
                        crossingBoundaryAt: nil,
                        into: &node.candidates
                    ) else { return nil }
                    guard accumulateCooccurrenceCandidates(
                        from: sequence,
                        segmentID: fragment.segmentID,
                        leafID: leaf.id,
                        temporalBin: temporalBin,
                        into: &node.candidates
                    ) else { return nil }
                }
                previousSegmentID = fragment.segmentID
                canBridge = !Self.endsSentence(in: text)
                carry = canBridge ? Array((sequences.last ?? []).suffix(3)) : []
            }
            node.anchors = prunedAnchors(node.anchors)
            node.candidates = prunedCandidates(node.candidates)
            nodes.append(node)
        }
        return nodes
    }

    private func merge(_ nodes: ArraySlice<ReductionNode>) -> ReductionNode? {
        var merged = ReductionNode()
        for node in nodes {
            guard !Task.isCancelled else { return nil }
            merged.leafIDs.append(contentsOf: node.leafIDs)
            for (key, incoming) in node.anchors {
                if var current = merged.anchors[key] {
                    current.merge(incoming)
                    merged.anchors[key] = current
                } else {
                    merged.anchors[key] = incoming
                }
            }
            for (key, incoming) in node.candidates {
                guard !Task.isCancelled else { return nil }
                if var current = merged.candidates[key] {
                    current.merge(incoming)
                    merged.candidates[key] = current
                } else {
                    merged.candidates[key] = incoming
                }
            }
        }
        merged.anchors = prunedAnchors(merged.anchors)
        merged.candidates = prunedCandidates(merged.candidates)
        return merged
    }

    /// Keeps a balanced top-K across 2-, 3-, and 4-word phrases. Reserving a
    /// share for each length prevents longer unique phrases from evicting every
    /// concise title before higher-level nodes can combine repeated evidence.
    private func prunedCandidates(
        _ candidates: [String: CandidateEvidence]
    ) -> [String: CandidateEvidence] {
        guard candidates.count > Self.maximumRetainedCandidatesPerNode else { return candidates }
        var retained: [String: CandidateEvidence] = [:]
        retained.reserveCapacity(Self.maximumRetainedCandidatesPerNode)
        let edgeQuota = 24
        let earliest = candidates.values.sorted {
            if $0.firstLeafID != $1.firstLeafID { return $0.firstLeafID < $1.firstLeafID }
            return Self.ranksBefore($0, $1)
        }
        let latest = candidates.values.sorted {
            if $0.lastLeafID != $1.lastLeafID { return $0.lastLeafID > $1.lastLeafID }
            return Self.ranksBefore($0, $1)
        }
        for evidence in earliest.prefix(edgeQuota) { retained[evidence.normalized] = evidence }
        for evidence in latest.prefix(edgeQuota) { retained[evidence.normalized] = evidence }

        let lengths = [2, 3, 4]
        let rankedByLength = Dictionary(uniqueKeysWithValues: lengths.map { length in
            (length, candidates.values.filter { $0.words.count == length }.sorted(by: Self.ranksBefore))
        })
        var offsets = Dictionary(uniqueKeysWithValues: lengths.map { ($0, 0) })
        while retained.count < Self.maximumRetainedCandidatesPerNode {
            guard !Task.isCancelled else { return [:] }
            var added = false
            for length in lengths where retained.count < Self.maximumRetainedCandidatesPerNode {
                guard let ranked = rankedByLength[length] else { continue }
                var offset = offsets[length] ?? 0
                while offset < ranked.count, retained[ranked[offset].normalized] != nil {
                    offset += 1
                }
                offsets[length] = offset + 1
                if offset < ranked.count {
                    let next = ranked[offset]
                    retained[next.normalized] = next
                    added = true
                }
            }
            if !added { break }
        }
        return retained
    }

    private func prunedAnchors(
        _ anchors: [String: AnchorEvidence]
    ) -> [String: AnchorEvidence] {
        guard anchors.count > Self.maximumRetainedAnchorsPerNode else { return anchors }
        var retained: [String: AnchorEvidence] = [:]
        retained.reserveCapacity(Self.maximumRetainedAnchorsPerNode)
        let edgeQuota = 16
        let earliest = anchors.values.sorted {
            if $0.firstLeafID != $1.firstLeafID { return $0.firstLeafID < $1.firstLeafID }
            return Self.anchorRanksBefore($0, $1)
        }
        let latest = anchors.values.sorted {
            if $0.lastLeafID != $1.lastLeafID { return $0.lastLeafID > $1.lastLeafID }
            return Self.anchorRanksBefore($0, $1)
        }
        for anchor in earliest.prefix(edgeQuota) { retained[anchor.normalized] = anchor }
        for anchor in latest.prefix(edgeQuota) { retained[anchor.normalized] = anchor }
        for anchor in anchors.values.sorted(by: Self.anchorRanksBefore) {
            if retained.count >= Self.maximumRetainedAnchorsPerNode { break }
            retained[anchor.normalized] = anchor
        }
        return retained
    }

    private func cancelledGeneration(
        for snapshot: MeetingTitleSnapshot,
        depth: Int
    ) -> MeetingTitleGeneration {
        MeetingTitleGeneration(
            title: nil,
            fingerprint: snapshot.fingerprint,
            // A canceled pass must never be mistaken for a final artifact.
            coverageReceipt: snapshot.coverageReceipt.consuming([]),
            reductionDepth: depth
        )
    }

    private func selectTitle(
        from candidates: [String: CandidateEvidence],
        anchors: [String: AnchorEvidence],
        totalLeafCount: Int
    ) -> String? {
        let longMeeting = totalLeafCount >= Self.longMeetingLeafThreshold
        let strongAnchors = Set(anchors.values.compactMap { anchor in
            anchor.isStrong(longMeeting: longMeeting) ? anchor.normalized : nil
        })
        let ranked = candidates.values
            .compactMap { evidence -> RankedCandidate? in
                guard (2...4).contains(evidence.words.count) else { return nil }
                guard evidence.words.filter(\.isMeaningful).count >= 2 else { return nil }
                guard !evidence.hasRepeatedContentWord else { return nil }
                guard !evidence.hasIncompleteBoundary else { return nil }
                guard evidence.hasCorroboratedEvidence else { return nil }
                if longMeeting, evidence.temporalBins.count < 2 { return nil }
                let anchorCount = Set(evidence.words.map(\.normalized))
                    .intersection(strongAnchors)
                    .count
                guard anchorCount >= 2 else { return nil }
                return RankedCandidate(evidence: evidence, anchorCount: anchorCount)
            }
            .sorted(by: Self.rankedCandidateBefore)

        guard let best = ranked.first else { return nil }
        let bestTerms = Set(best.evidence.words.filter(\.isMeaningful).map(\.normalized))
        if let competitor = ranked.dropFirst().first(where: { candidate in
            let terms = Set(candidate.evidence.words.filter(\.isMeaningful).map(\.normalized))
            return terms.isDisjoint(with: bestTerms)
        }), competitor.supportScore * 100 >= best.supportScore * 85 {
            return nil
        }

        let title = best.evidence.words.map { Self.titleCased($0.display) }.joined(separator: " ")
        return MeetingTitle.isValid(title) ? title : nil
    }

    private static func ranksBefore(_ lhs: CandidateEvidence, _ rhs: CandidateEvidence) -> Bool {
        let leftScore = lhs.score
        let rightScore = rhs.score
        if leftScore != rightScore { return leftScore > rightScore }
        if lhs.firstLeafID != rhs.firstLeafID { return lhs.firstLeafID < rhs.firstLeafID }
        if lhs.firstTokenOffset != rhs.firstTokenOffset { return lhs.firstTokenOffset < rhs.firstTokenOffset }
        return lhs.normalized < rhs.normalized
    }

    private static func rankedCandidateBefore(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return ranksBefore(lhs.evidence, rhs.evidence)
    }

    private static func anchorRanksBefore(_ lhs: AnchorEvidence, _ rhs: AnchorEvidence) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.firstLeafID != rhs.firstLeafID { return lhs.firstLeafID < rhs.firstLeafID }
        return lhs.normalized < rhs.normalized
    }

    private static func tokenSequences(in text: String) -> [[LexicalWord]]? {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var sequences: [[LexicalWord]] = [[]]
        var priorUpper = text.startIndex
        var tokenOffset = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            guard !Task.isCancelled else { return false }
            let gap = text[priorUpper..<range.lowerBound]
            if gap.contains(where: { ".!?。！？\n\r".contains($0) }),
               !(sequences.last?.isEmpty ?? true) {
                sequences.append([])
            }
            let raw = String(text[range])
            if let word = lexicalWord(raw, tokenOffset: tokenOffset) {
                sequences[sequences.count - 1].append(word)
                tokenOffset += 1
            }
            priorUpper = range.upperBound
            return true
        }
        guard !Task.isCancelled else { return nil }
        return sequences.filter { !$0.isEmpty }
    }

    private static func lexicalWord(_ raw: String, tokenOffset: Int) -> LexicalWord? {
        var normalized = raw
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        if normalized.hasSuffix("'s"), normalized.count > 3 {
            normalized.removeLast(2)
        }
        let letters = normalized.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return nil }
        let service = serviceTokens.contains(normalized)
        let stop = stopWords.contains(normalized)
        let generic = genericWords.contains(normalized)
        return LexicalWord(
            normalized: normalized,
            display: raw,
            tokenOffset: tokenOffset,
            isMeaningful: !service && !stop,
            isGeneric: generic || service
        )
    }

    private static func temporalBin(for leafID: Int, totalLeafCount: Int) -> Int {
        guard totalLeafCount > 1 else { return 0 }
        return min(
            temporalBinCount - 1,
            max(0, leafID) * temporalBinCount / totalLeafCount
        )
    }

    private func accumulateAnchors(
        from words: [LexicalWord],
        segmentID: UUID,
        leafID: Int,
        temporalBin: Int,
        into anchors: inout [String: AnchorEvidence]
    ) {
        for word in words where word.isMeaningful {
            let incoming = AnchorEvidence(
                normalized: word.normalized,
                display: word.display,
                count: 1,
                segmentIDs: [segmentID],
                temporalBins: [temporalBin],
                firstLeafID: leafID,
                lastLeafID: leafID,
                isGeneric: word.isGeneric
            )
            if var current = anchors[word.normalized] {
                current.merge(incoming)
                anchors[word.normalized] = current
            } else {
                anchors[word.normalized] = incoming
            }
        }
    }

    private func accumulateCandidates(
        from words: [LexicalWord],
        segmentID: UUID,
        leafID: Int,
        temporalBin: Int,
        kind: CandidateKind,
        crossingBoundaryAt boundary: Int?,
        into candidates: inout [String: CandidateEvidence]
    ) -> Bool {
        guard words.count >= 2 else { return true }
        for start in words.indices {
            guard !Task.isCancelled else { return false }
            for length in 2...4 where start + length <= words.count {
                if let boundary,
                   !(start < boundary && start + length > boundary) {
                    continue
                }
                let phrase = Array(words[start..<(start + length)])
                guard phrase.first?.isMeaningful == true, phrase.last?.isMeaningful == true else {
                    continue
                }
                guard phrase.filter(\.isMeaningful).count >= 2 else { continue }
                let normalized = phrase.map(\.normalized).joined(separator: " ")
                let evidence = CandidateEvidence(
                    normalized: normalized,
                    words: phrase,
                    count: 1,
                    segmentIDs: [segmentID],
                    temporalBins: [temporalBin],
                    observedCount: kind == .observed ? 1 : 0,
                    cooccurrenceCount: kind == .cooccurrence ? 1 : 0,
                    firstLeafID: leafID,
                    lastLeafID: leafID,
                    firstTokenOffset: phrase[0].tokenOffset
                )
                if var current = candidates[normalized] {
                    current.merge(evidence)
                    candidates[normalized] = current
                } else {
                    candidates[normalized] = evidence
                }
                // Keep transient storage fixed too; pruning at 2K amortizes the
                // sort while limiting pathological unique candidate growth.
                if candidates.count > Self.maximumRetainedCandidatesPerNode * 4 {
                    candidates = prunedCandidates(candidates)
                    guard !Task.isCancelled else { return false }
                }
            }
        }
        return true
    }

    private func accumulateCooccurrenceCandidates(
        from words: [LexicalWord],
        segmentID: UUID,
        leafID: Int,
        temporalBin: Int,
        into candidates: inout [String: CandidateEvidence]
    ) -> Bool {
        let meaningful = words.enumerated().filter { $0.element.isMeaningful }
        guard meaningful.count >= 2 else { return true }
        for leftIndex in meaningful.indices {
            guard !Task.isCancelled else { return false }
            let (leftPosition, leftWord) = meaningful[leftIndex]
            guard Self.canFormSkipCandidate(leftWord) else { continue }
            for rightIndex in meaningful.index(after: leftIndex)..<meaningful.endIndex {
                let (rightPosition, rightWord) = meaningful[rightIndex]
                if rightPosition - leftPosition > Self.maximumSkipDistance { break }
                guard Self.canFormSkipCandidate(rightWord) else { continue }
                // Adjacent meaningful words are already represented by the
                // observed-phrase channel; this channel is only for real skip
                // co-occurrence inside the same bounded transcript sequence.
                guard rightPosition - leftPosition > 1 else { continue }
                guard leftWord.normalized != rightWord.normalized else { continue }
                let phrase = [leftWord, rightWord]
                let normalized = phrase.map(\.normalized).joined(separator: " ")
                let incoming = CandidateEvidence(
                    normalized: normalized,
                    words: phrase,
                    count: 1,
                    segmentIDs: [segmentID],
                    temporalBins: [temporalBin],
                    observedCount: 0,
                    cooccurrenceCount: 1,
                    firstLeafID: leafID,
                    lastLeafID: leafID,
                    firstTokenOffset: leftWord.tokenOffset
                )
                if var current = candidates[normalized] {
                    current.merge(incoming)
                    candidates[normalized] = current
                } else {
                    candidates[normalized] = incoming
                }
                if candidates.count > Self.maximumRetainedCandidatesPerNode * 4 {
                    candidates = prunedCandidates(candidates)
                    guard !Task.isCancelled else { return false }
                }
            }
        }
        return true
    }

    private static func canFormSkipCandidate(_ word: LexicalWord) -> Bool {
        word.normalized.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || $0 == "'"
        }
    }

    private static func endsSentence(in text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return ".!?。！？\n\r".contains(last)
    }

    private static func titleCased(_ word: String) -> String {
        if word.count <= 5, word == word.uppercased(), word != word.lowercased() {
            return word
        }
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst().lowercased()
    }

    private static let serviceTokens: Set<String> = [
        "unk", "unknown", "inaudible", "unintelligible", "silence",
        "mm", "mmm", "hm", "hmm", "mhm", "uh", "uhh", "um", "umm",
    ]

    private static let genericWords: Set<String> = [
        "call", "meeting", "today", "discussion", "discuss", "discussing", "review", "item",
        "spotkanie", "dzisiaj", "omawiamy", "rozmawiamy", "temat", "punkt",
        "встреча", "встречи", "сегодня", "обсуждаем", "обсуждение", "тема", "пункт",
        "ignore", "instructions", "previous", "title",
    ]

    private static let stopWords: Set<String> = [
        // English
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "for", "from",
        "has", "have", "he", "her", "his", "i", "in", "is", "it", "its", "of", "on", "or",
        "our", "she", "that", "the", "their", "them", "they", "this", "to", "we", "were",
        "will", "with", "you", "your", "yes", "need", "needs", "next", "main", "after",
        "it's", "not", "know", "like", "yeah", "yep", "okay", "ok", "well", "right",
        "really", "just", "actually", "basically", "kind", "sort", "thing", "things",
        // Polish
        "a", "aby", "ale", "bo", "by", "dla", "do", "i", "jak", "jest", "na", "nie", "o",
        "od", "oraz", "po", "się", "to", "w", "we", "z", "za", "że", "tak", "najważniejszy",
        "główna", "kolejne", "kroki", "ustalamy", "wymaga",
        "jakiś", "jakis", "jakaś", "jakas", "jakieś", "jakies", "tam", "jeżeli", "jezeli",
        "chodzi", "no", "właśnie", "wlasnie", "ten", "ta", "te", "tego", "tym", "tutaj",
        "taki", "taka", "takie", "więc", "wiec", "znaczy", "generalnie", "właściwie",
        "wlasciwie", "prostu", "może", "moze",
        // Russian
        "а", "без", "бы", "был", "была", "были", "в", "во", "для", "до", "и", "из", "к",
        "как", "на", "не", "но", "о", "по", "с", "со", "то", "у", "что", "это", "я", "да",
        "главная", "следующий", "этап", "начнётся", "завтра",
        "ну", "есть", "общем", "вообще", "понимаешь", "понятно", "значит", "типа", "просто",
        "вот", "там", "такой", "такая", "такие", "получается", "короче", "наверное",
    ]
}

private struct ReductionNode {
    var leafIDs: [Int] = []
    var anchors: [String: AnchorEvidence] = [:]
    var candidates: [String: CandidateEvidence] = [:]
}

private enum CandidateKind {
    case observed
    case cooccurrence
}

private struct LexicalWord: Equatable {
    let normalized: String
    let display: String
    let tokenOffset: Int
    let isMeaningful: Bool
    let isGeneric: Bool
}

private struct AnchorEvidence {
    let normalized: String
    var display: String
    var count: Int
    var segmentIDs: Set<UUID>
    var temporalBins: Set<Int>
    var firstLeafID: Int
    var lastLeafID: Int
    let isGeneric: Bool

    var score: Int {
        temporalBins.count * 1_000
            + min(segmentIDs.count, 100) * 100
            + saturatedLog2(count + 1) * 80
            - (isGeneric ? 500 : 0)
    }

    func isStrong(longMeeting: Bool) -> Bool {
        guard !isGeneric, count >= 2, segmentIDs.count >= 2 else { return false }
        return !longMeeting || temporalBins.count >= 2
    }

    mutating func merge(_ other: AnchorEvidence) {
        count = count > Int.max - other.count ? Int.max : count + other.count
        mergeBounded(other.segmentIDs, into: &segmentIDs, maximum: 100)
        mergeBounded(other.temporalBins, into: &temporalBins, maximum: 32)
        if other.firstLeafID < firstLeafID {
            display = other.display
            firstLeafID = other.firstLeafID
        }
        lastLeafID = max(lastLeafID, other.lastLeafID)
    }
}

private struct CandidateEvidence {
    let normalized: String
    var words: [LexicalWord]
    var count: Int
    var segmentIDs: Set<UUID>
    var temporalBins: Set<Int>
    var observedCount: Int
    var cooccurrenceCount: Int
    var firstLeafID: Int
    var lastLeafID: Int
    var firstTokenOffset: Int

    var hasRepeatedContentWord: Bool {
        let content = words.filter(\.isMeaningful).map(\.normalized)
        return Set(content).count != content.count
    }

    var hasIncompleteBoundary: Bool {
        guard let last = words.last?.normalized else { return true }
        return ["follow"].contains(last)
    }

    /// A lone conversational span is not enough evidence for renaming a
    /// meeting. Repetition may come from another transcript segment or from a
    /// second occurrence inside one long segment.
    var hasCorroboratedEvidence: Bool {
        segmentIDs.count >= 2 || (count >= 3 && temporalBins.count >= 2)
    }

    var score: Int {
        let contentCount = words.filter(\.isMeaningful).count
        let genericCount = words.filter(\.isGeneric).count
        let internalStopCount = words.count - contentCount
        return temporalBins.count * 1_200
            + min(segmentIDs.count, 100) * 120
            + saturatedLog2(count + 1) * 90
            + min(observedCount, 8) * 30
            + min(cooccurrenceCount, 8) * 10
            + words.count * 40
            + contentCount * 25
            - genericCount * 350
            - internalStopCount * 20
    }

    mutating func merge(_ other: CandidateEvidence) {
        count = count > Int.max - other.count ? Int.max : count + other.count
        observedCount = observedCount > Int.max - other.observedCount
            ? Int.max : observedCount + other.observedCount
        cooccurrenceCount = cooccurrenceCount > Int.max - other.cooccurrenceCount
            ? Int.max : cooccurrenceCount + other.cooccurrenceCount
        mergeBounded(
            other.segmentIDs,
            into: &segmentIDs,
            maximum: LocalMeetingTitleGenerator.maximumRememberedSegmentIDsPerCandidate
        )
        mergeBounded(other.temporalBins, into: &temporalBins, maximum: 32)
        lastLeafID = max(lastLeafID, other.lastLeafID)
        if other.firstLeafID < firstLeafID
            || (other.firstLeafID == firstLeafID && other.firstTokenOffset < firstTokenOffset) {
            words = other.words
            firstLeafID = other.firstLeafID
            firstTokenOffset = other.firstTokenOffset
        }
    }
}

private struct RankedCandidate {
    let evidence: CandidateEvidence
    let anchorCount: Int

    var score: Int {
        evidence.score + anchorCount * 1_500
    }

    var supportScore: Int {
        evidence.temporalBins.count * 1_000
            + min(evidence.segmentIDs.count, 100) * 120
            + saturatedLog2(evidence.count + 1) * 80
    }
}

private func saturatedLog2(_ value: Int) -> Int {
    var remaining = max(1, value)
    var result = 0
    while remaining > 1, result < 16 {
        remaining >>= 1
        result += 1
    }
    return result
}

private func mergeBounded<Element: Hashable>(
    _ incoming: Set<Element>,
    into destination: inout Set<Element>,
    maximum: Int
) {
    guard destination.count < maximum else { return }
    for value in incoming {
        destination.insert(value)
        if destination.count >= maximum { return }
    }
}
