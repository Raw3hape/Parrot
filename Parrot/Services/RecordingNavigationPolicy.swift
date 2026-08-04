enum RecordingDetailPresentation: Equatable {
    case selectedDestination
    case liveRecording
    case selectedDestinationWithRecordingBanner
}
enum RecordingNavigationPolicy {
    static func presentation(
        isRecording: Bool,
        prefersLiveRecording: Bool
    ) -> RecordingDetailPresentation {
        guard isRecording else { return .selectedDestination }
        return prefersLiveRecording
            ? .liveRecording
            : .selectedDestinationWithRecordingBanner
    }
}
