import AVFoundation
import Foundation

/// Bounded production-capture diagnostic. Counts signal only; its temporary
/// CAF tracks are removed without exporting microphone content.
enum CaptureIntegrationTest {
    private final class Levels: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [String: Int] = [:]
        private var energy: [String: Double] = [:]

        func append(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
            let name = String(describing: source)
            let count = Int(buffer.frameLength)
            let samples = buffer.floatChannelData?[0]
            var sum = 0.0
            if let samples {
                for index in 0..<count { sum += Double(samples[index] * samples[index]) }
            }
            lock.lock(); defer { lock.unlock() }
            frames[name, default: 0] += count
            energy[name, default: 0] += sum
        }

        func snapshot() -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            var result: [String: Any] = [:]
            for (source, count) in frames {
                result["\(source)_frames"] = count
                result["\(source)_rms"] = sqrt(energy[source, default: 0] / Double(max(1, count)))
            }
            return result
        }
    }

    static func run() {
        Task { @MainActor in
            let capture = AudioCaptureManager()
            let levels = Levels()
            capture.onAudioBuffer = { buffer, source in levels.append(buffer, source: source) }
            do {
                try await capture.startCapture()
                let micWasActive = capture.micActive
                print("capture_ready: 1"); fflush(stdout)
                try await Task.sleep(for: .seconds(11))
                await capture.stopCapture()
                var result = levels.snapshot()
                result["diagnostic"] = "production_capture"
                result["mic_active"] = micWasActive
                result["microphone_authorization"] = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
                result["input_device"] = capture.inputDeviceName
                result["output_device"] = capture.outputDeviceName
                let systemFrames = result["them_frames"] as? Int ?? 0
                let micFrames = result["me_frames"] as? Int ?? 0
                let signal = result["them_rms"] as? Double ?? 0
                let passed = micWasActive && systemFrames > 16_000 && micFrames > 16_000 && signal > 0.00001
                result["passed"] = passed
                for url in [capture.systemAudioURL, capture.micAudioURL].compactMap({ $0 }) {
                    try? FileManager.default.removeItem(at: url)
                }
                print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
                exit(passed ? 0 : 2)
            } catch {
                await capture.stopCapture()
                FileHandle.standardError.write(Data("diagnostic=capture status=failed error=\(error)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
