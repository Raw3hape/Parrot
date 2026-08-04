import Foundation

enum MenuBarPresentation: Equatable {
    case manual
    case suggestion
    case starting
    case recording
}

enum MenuBarPresentationPolicy {
    static func presentation(
        isRecording: Bool,
        isStarting: Bool,
        suggestion: CallCandidate?
    ) -> MenuBarPresentation {
        if isRecording { return .recording }
        if isStarting { return .starting }
        if suggestion != nil { return .suggestion }
        return .manual
    }
}
