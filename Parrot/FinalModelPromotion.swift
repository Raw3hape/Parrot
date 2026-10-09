import CryptoKit
import Foundation

/// Explicit installer/QA command. Only a pinned, fully hashed local directory
/// can become the selected speech refinement; previous model data is preserved.
enum FinalModelPromotion {
    static func run(engine: String, sourceRoot: String, evidenceSHA256: String) {
        Task {
            do {
                guard engine == "qwen", evidenceSHA256.count == 64,
                      evidenceSHA256.allSatisfy(\.isHexDigit),
                      let descriptor = FinalSpeechModelCatalog.descriptor(for: engine) else {
                    throw NativeFinalASRError.modelUnavailable
                }
                let source = URL(fileURLWithPath: sourceRoot, isDirectory: true)
                    .appendingPathComponent(descriptor.directoryName, isDirectory: true)
                guard FinalSpeechModelCatalog.isComplete(descriptor, root: URL(fileURLWithPath: sourceRoot)) else {
                    throw NativeFinalASRError.modelUnavailable
                }
                let weight = source.appendingPathComponent(descriptor.weightFile)
                let hash = try await Task.detached(priority: .utility) {
                    let handle = try FileHandle(forReadingFrom: weight)
                    defer { try? handle.close() }
                    var digest = SHA256()
                    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                        digest.update(data: data)
                    }
                    return digest.finalize().map { String(format: "%02x", $0) }.joined()
                }.value
                guard hash == descriptor.weightSHA256 else { throw NativeFinalASRError.modelUnavailable }
                let destinationRoot = FinalSpeechModelCatalog.rootDirectory
                try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
                let destination = destinationRoot.appendingPathComponent(descriptor.directoryName, isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    // A model already present is never overwritten by a QA command.
                    guard FinalSpeechModelCatalog.isComplete(descriptor, root: destinationRoot) else {
                        throw NativeFinalASRError.modelUnavailable
                    }
                    let existing = try FileHandle(forReadingFrom: destination.appendingPathComponent(descriptor.weightFile))
                    defer { try? existing.close() }
                    var digest = SHA256()
                    while let data = try existing.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
                    guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else {
                        throw NativeFinalASRError.modelUnavailable
                    }
                } else {
                    let staging = destinationRoot.appendingPathComponent(".incoming-\(UUID())", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try FileManager.default.copyItem(at: source, to: staging)
                    try FileManager.default.moveItem(at: staging, to: destination)
                }
                let selection = FinalSpeechModelCatalog.Selection(engine: engine, revision: descriptor.revision, validationEvidenceSHA256: evidenceSHA256)
                let data = try JSONEncoder().encode(selection)
                try data.write(to: destinationRoot.appendingPathComponent("selection.json"), options: .atomic)
                let message: [String: Any] = ["promoted": true, "engine": engine, "revision": descriptor.revision, "weights_sha256": hash]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) + Data("\n".utf8))
                exit(0)
            } catch {
                let message = ["promoted": "false", "error_type": String(reflecting: type(of: error))]
                if let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) {
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                }
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
