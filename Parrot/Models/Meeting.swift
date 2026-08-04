import Foundation
import SwiftData

enum MeetingStatus: String, Codable {
    case recording
    case processing
    case done
    case failed
}

@Model
final class Meeting {
    var id: UUID
    var title: String
    /// Provenance protects a user-edited title from asynchronous local title
    /// generation. String-backed/defaulted fields keep existing SwiftData rows
    /// eligible for lightweight migration.
    var titleOriginRaw: String = "default"
    var titleTranscriptFingerprint: String?
    var titleGeneratorVersion: String?
    var titleGeneratedAt: Date?
    var date: Date
    var duration: TimeInterval
    var systemAudioPath: String
    var micAudioPath: String?
    var status: MeetingStatus
    var errorMessage: String?
    /// AI-generated post-call report; set shortly after recording stops.
    var summary: String?
    /// Local summaries are fingerprinted separately from titles. Defaulted
    /// fields allow existing SwiftData stores to migrate without rewriting the
    /// transcript or any legacy/cloud report.
    var summaryOriginRaw: String = "none"
    var summaryTranscriptFingerprint: String?
    var summaryGeneratorVersion: String?
    var summaryGeneratedAt: Date?
    /// AI coaching + follow-ups report (talk ratio, what to improve, commitments).
    var coaching: String?
    /// User-assigned name for the other party ("Them"), e.g. "Sam". When set, it
    /// replaces "Them"/"Speaker N" labels in the transcript and reports.
    var themName: String?
    /// The user's own typed notes for this call — live during recording (side
    /// panel) and editable afterwards (Notes tab). Defaulted → old rows migrate.
    var notes: String = ""

    /// Profile recorded under (nil for pre-Phase-C meetings).
    var profile: CallProfile?
    /// One-line brief for this specific call (was ephemeral nextCallBrief).
    var brief: String?
    /// Denormalized [ProfileKind] used at record time, so the report renders with
    /// the right kind labels/colors even if the profile is later edited/deleted.
    var profileSnapshotData: Data?
    /// Per-call AI usage/cost snapshot (AIUsage JSON); nil for meetings recorded
    /// before cost tracking existed — those show no cost row.
    var aiUsageData: Data?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment]

    @Relationship(deleteRule: .cascade, inverse: \CallInsight.meeting)
    var insights: [CallInsight]

    init(
        title: String? = nil,
        date: Date = .now,
        systemAudioPath: String = "",
        micAudioPath: String? = nil
    ) {
        self.id = UUID()
        self.title = title ?? Self.defaultTitle(for: date)
        self.titleOriginRaw = title == nil ? "default" : "manual"
        self.date = date
        self.duration = 0
        self.systemAudioPath = systemAudioPath
        self.micAudioPath = micAudioPath
        self.status = .recording
        self.errorMessage = nil
        self.summary = nil
        self.summaryOriginRaw = "none"
        self.segments = []
        self.insights = []
    }

    var sortedInsights: [CallInsight] {
        insights.sorted { $0.callTime < $1.callTime }
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        // Persist one predictable fallback format regardless of the current
        // macOS language, region, or calendar. This avoids mixed strings such
        // as "Meeting июля ..." after a locale change.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return "Meeting \(formatter.string(from: date))"
    }

    /// Strict matching is intentional: a legacy custom name such as
    /// "Meeting with Lena" must never be mistaken for an automatic placeholder.
    var hasPlaceholderTitle: Bool {
        title == Self.defaultTitle(for: date)
    }

    /// Old placeholder strings were rendered in the locale/time zone active at
    /// recording time. Recognize only the full historical date-time shape so a
    /// later travel/locale change does not make them look like custom names.
    var hasLegacyPlaceholderTitle: Bool {
        if hasPlaceholderTitle { return true }
        let pattern = #"^Meeting\s+.+\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}[:.-]\d{2}\s*(?:AM|PM)?$"#
        return title.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Applies a user-authored title without modifying anything other than the
    /// draft's surrounding whitespace/newlines. Returns false for a blank draft.
    @discardableResult
    func applyManualTitle(_ draft: String) -> Bool {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        title = value
        titleOriginRaw = "manual"
        titleTranscriptFingerprint = nil
        titleGeneratorVersion = nil
        titleGeneratedAt = nil
        return true
    }

    var sortedSegments: [TranscriptSegment] {
        segments.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var snapshotKinds: [ProfileKind] {
        guard let data = profileSnapshotData else { return [] }
        return (try? JSONDecoder().decode([ProfileKind].self, from: data)) ?? []
    }

    var aiUsage: AIUsage? {
        guard let data = aiUsageData else { return nil }
        return try? JSONDecoder().decode(AIUsage.self, from: data)
    }

    /// Number of distinct participants by display name. Counting display names
    /// (not raw labels) means that once the other party is named, the imperfect
    /// diarization splitting one voice into "Speaker 1"/"Speaker 2" collapses back
    /// to a single person — so a 1-on-1 reads as 2, not 3.
    var speakerCount: Int {
        Set(segments.map { displayName(forSpeaker: $0.speakerLabel) }).count
    }

    /// Human-facing speaker name: "Me" stays "Me"; everyone else becomes the
    /// user-assigned `themName` (e.g. "Sam") if set, otherwise the raw label.
    func displayName(forSpeaker label: String?) -> String {
        guard let label, !label.isEmpty else { return themName ?? "Them" }
        if label == "Me" { return "Me" }
        return themName ?? label
    }

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
