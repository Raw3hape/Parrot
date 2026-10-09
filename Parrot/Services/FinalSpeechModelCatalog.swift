import Foundation

/// One pinned, bundled registry supplies runtime identities and cache keys.
enum FinalSpeechModelCatalog {
    struct Descriptor: Codable, Equatable, Sendable {
        var engine: String
        var displayName: String
        var modelID: String
        var revision: String
        var directoryName: String
        var weightFile: String
        var weightBytes: UInt64
        var weightSHA256: String
        var requiredFiles: [String]

        var identity: String {
            "\(modelID)@\(revision):native-window30-overlap0-v1"
        }
    }

    struct Registry: Codable, Sendable {
        var schemaVersion: Int
        var models: [Descriptor]
    }

    struct Selection: Codable, Sendable {
        var engine: String
        var revision: String
        var validationEvidenceSHA256: String
    }

    static var models: [Descriptor] {
        #if SWIFT_PACKAGE
        let resourceURL = Bundle.module.url(forResource: "FinalSpeechModels", withExtension: "json")
            ?? Bundle.module.url(forResource: "FinalSpeechModels", withExtension: "json", subdirectory: "Resources")
        #else
        let resourceURL = Bundle.main.url(forResource: "FinalSpeechModels", withExtension: "json")
        #endif
        guard let resourceURL,
              let data = try? Data(contentsOf: resourceURL),
              let registry = try? JSONDecoder().decode(Registry.self, from: data),
              registry.schemaVersion == 1 else { return [] }
        return registry.models
    }

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Parrot/FinalSpeech", isDirectory: true)
    }

    static var workerURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ASRWorker.app/Contents/MacOS/ParrotASRWorker")
    }

    static func descriptor(for engine: String) -> Descriptor? {
        models.first { $0.engine == engine }
    }

    static func selectedDescriptor(root: URL = rootDirectory) -> Descriptor? {
        let selectionURL = root.appendingPathComponent("selection.json")
        guard let data = try? Data(contentsOf: selectionURL),
              let selection = try? JSONDecoder().decode(Selection.self, from: data),
              selection.validationEvidenceSHA256.count == 64,
              selection.validationEvidenceSHA256.allSatisfy(\.isHexDigit),
              let descriptor = descriptor(for: selection.engine),
              selection.revision == descriptor.revision,
              isComplete(descriptor, root: root) else { return nil }
        return descriptor
    }

    static func isComplete(_ descriptor: Descriptor, root: URL) -> Bool {
        let directory = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        let weight = directory.appendingPathComponent(descriptor.weightFile)
        guard let size = try? weight.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              UInt64(size) == descriptor.weightBytes else { return false }
        return descriptor.requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func displayName(for identity: String) -> String {
        if identity.hasPrefix("hybrid:"), let model = models.first(where: { identity.contains($0.modelID + "@") }) {
            return "Whisper Turbo + \(model.displayName)"
        }
        return models.first { identity == $0.identity || identity.hasPrefix($0.modelID + "@") }?.displayName
            ?? (identity == WhisperModelService.fallbackModel ? "Whisper Large V3 Turbo" : identity)
    }
}
