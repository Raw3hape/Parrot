import Foundation

struct MeetingSummaryGeneration: Sendable, Equatable {
    let title: String?
    let summary: String?
    let fingerprint: String
    let coverageReceipt: MeetingTitleCoverageReceipt
    let disposition: MeetingTitleGenerationDisposition

    init(
        title: String? = nil,
        summary: String?,
        fingerprint: String,
        coverageReceipt: MeetingTitleCoverageReceipt,
        disposition: MeetingTitleGenerationDisposition = .completed
    ) {
        self.title = title
        self.summary = summary
        self.fingerprint = fingerprint
        self.coverageReceipt = coverageReceipt
        self.disposition = disposition
    }
}

enum MeetingSummary {
    static func validated(_ raw: String) -> String? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard (16...1_200).contains(value.count),
              !value.contains("<transcript"),
              !value.contains("```"),
              value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
        else { return nil }
        return value
    }

    static func validatedContextualTitle(_ raw: String) -> String? {
        let value = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'“”„«»*#.:;,-"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let words = value.split(whereSeparator: \.isWhitespace)
        guard (3...12).contains(words.count), value.count <= 140,
              !value.contains("\n"), !value.contains("\r"),
              words.allSatisfy({ word in
                  word.unicodeScalars.contains { CharacterSet.letters.contains($0) }
              })
        else { return nil }
        return value
    }
}
