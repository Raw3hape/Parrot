import Foundation

enum MeetingTranscriptMessageTone: Equatable {
    case progress
    case information
    case error
}

struct MeetingTranscriptPresentation: Equatable {
    let message: String?
    let tone: MeetingTranscriptMessageTone
    let showsProgress: Bool
    let showsTranscript: Bool
}

/// Pure presentation rules shared by the SwiftUI meeting list and detail view.
/// Keeping status/search decisions here makes partial and failed recordings
/// predictable without coupling them to audio playback or SwiftData queries.
enum MeetingPresentationPolicy {
    /// A SwiftData model must disappear from the sidebar before it is deleted
    /// from its context. SwiftUI may otherwise render one final frame of the
    /// existing row and fault a property on an already-invalidated model.
    static func shouldPresentMeeting(
        id: UUID,
        pendingDeletionIDs: Set<UUID>
    ) -> Bool {
        !pendingDeletionIDs.contains(id)
    }

    static func shouldShowPlayer(
        status: MeetingStatus,
        hasPlayableAudio: Bool
    ) -> Bool {
        status != .recording && hasPlayableAudio
    }

    static func transcriptPresentation(
        status: MeetingStatus,
        segmentCount: Int,
        errorMessage: String?
    ) -> MeetingTranscriptPresentation {
        let hasTranscript = segmentCount > 0

        switch status {
        case .recording:
            return MeetingTranscriptPresentation(
                message: hasTranscript ? nil : "The transcript will appear here during recording.",
                tone: .information,
                showsProgress: false,
                showsTranscript: hasTranscript
            )
        case .processing:
            return MeetingTranscriptPresentation(
                message: "Finalizing the local transcript…",
                tone: .progress,
                showsProgress: true,
                showsTranscript: hasTranscript
            )
        case .done:
            return MeetingTranscriptPresentation(
                message: hasTranscript ? nil : "No speech was transcribed for this meeting.",
                tone: .information,
                showsProgress: false,
                showsTranscript: hasTranscript
            )
        case .failed:
            let storedMessage = errorMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingTranscriptPresentation(
                message: storedMessage?.isEmpty == false
                    ? storedMessage
                    : "Transcription did not finish. Any captured audio and transcript were preserved.",
                tone: .error,
                showsProgress: false,
                showsTranscript: hasTranscript
            )
        }
    }

    static func shouldShowNotes(_ notes: String) -> Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func matchesSearch<Transcript: Sequence>(
        query: String,
        title: String,
        transcript: Transcript
    ) -> Bool where Transcript.Element == String {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(term)
            || transcript.contains { $0.localizedCaseInsensitiveContains(term) }
    }

    static func committedTitle(draft: String, previousTitle: String) -> String {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? previousTitle : title
    }
}
