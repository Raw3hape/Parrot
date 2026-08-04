import Darwin
import Foundation

@main
struct QwenSandboxInferenceHarness {
    static func main() async {
        guard memoryProbeSucceeds() else { exit(71) }
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/bin/llama-server")
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { exit(72) }
        let model = applicationSupport
            .appendingPathComponent("Parrot/Models/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf")
        guard FileManager.default.isReadableFile(atPath: model.path) else { exit(73) }

        let port = Int.random(in: 49_152...65_535)
        let apiKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let process = Process()
        process.executableURL = helper
        process.currentDirectoryURL = helper.deletingLastPathComponent()
        process.arguments = [
            "--model", model.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--api-key", apiKey,
            "--ctx-size", "8192",
            "--parallel", "1",
            "--gpu-layers", "all",
            "--cache-ram", "0",
            "--no-slots",
            "--no-warmup",
            "--reasoning", "off",
            "--log-disable",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
            }
            let root = URL(string: "http://127.0.0.1:\(port)/")!
            guard await waitUntilHealthy(root: root, apiKey: apiKey, process: process) else {
                exit(74)
            }
            guard await runInference(root: root, apiKey: apiKey) else { exit(75) }
            print("sandbox memory, model read, Metal load, loopback, and inference: PASS")
        } catch {
            exit(76)
        }
    }

    private static func memoryProbeSucceeds() -> Bool {
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        guard sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &pressure,
            &pressureSize,
            nil,
            0
        ) == 0 else { return false }

        let host = mach_host_self()
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        return withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        } == KERN_SUCCESS
    }

    private static func waitUntilHealthy(
        root: URL,
        apiKey: String,
        process: Process
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline, process.isRunning {
            var request = URLRequest(url: root.appendingPathComponent("health"))
            request.timeoutInterval = 1
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func runInference(root: URL, apiKey: String) async -> Bool {
        var request = URLRequest(url: root.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "messages": [["role": "user", "content": "Return only: {\"ok\":true}"]],
            "temperature": 0,
            "seed": 42,
            "max_tokens": 24,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return false }
        return !content.isEmpty
    }
}
