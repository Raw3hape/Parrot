import Foundation

/// Hard privacy contract for Nikita's personal build. Model downloads are the
/// only network activity this transcription stack needs; call audio and text are
/// never routed to a hosted recognition, polish, or copilot provider.
enum PersonalBuildPolicy {
    static let cloudFeaturesAllowed = false

    static func apply(to defaults: UserDefaults = .standard) {
        defaults.set(
            TranscriptionBackend.local.rawValue,
            forKey: TranscriptionBackend.defaultsKey
        )
        defaults.set(false, forKey: "polishAfterCall")
        defaults.set(false, forKey: "copilotEnabled")
        defaults.set("parakeet", forKey: "localSpeechEngine")
        defaults.set(WhisperModelService.fallbackModel, forKey: "whisperModel")

        if defaults.string(forKey: "transcriptionLanguage") == nil {
            defaults.set("auto", forKey: "transcriptionLanguage")
        }
    }
}
