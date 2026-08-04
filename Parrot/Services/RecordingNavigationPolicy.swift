enum RecordingDetailPresentation: Equatable {
    case selectedDestination
    case liveRecording
    case selectedDestinationWithRecordingBanner
}

enum RecordingSessionPhase: Equatable {
    case starting
    case recording
    case stopping
}

enum RecordingNavigationPolicy {
    static func sessionPhase(
        isStarting: Bool,
        isRecording: Bool,
        isStopping: Bool
    ) -> RecordingSessionPhase? {
        if isStopping { return .stopping }
        if isRecording { return .recording }
        if isStarting { return .starting }
        return nil
    }

    static func presentation(
        sessionPhase: RecordingSessionPhase?,
        prefersLiveRecording: Bool
    ) -> RecordingDetailPresentation {
        guard sessionPhase != nil else { return .selectedDestination }
        return prefersLiveRecording
            ? .liveRecording
            : .selectedDestinationWithRecordingBanner
    }
}

enum LiveTranscriptPresentationPolicy {
    static func shouldShowStatus(
        persistedSegmentCount: Int,
        hasInterimText: Bool
    ) -> Bool {
        persistedSegmentCount == 0 && !hasInterimText
    }
}
