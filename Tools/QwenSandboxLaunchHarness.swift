import Foundation

let helper = Bundle.main.bundleURL
    .appendingPathComponent("Contents/Helpers/bin/llama-server")
let process = Process()
process.executableURL = helper
process.arguments = ["--version"]
let output = Pipe()
process.standardOutput = output
process.standardError = output

do {
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    FileHandle.standardOutput.write(data)
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("launch failed\n".utf8))
    exit(70)
}
