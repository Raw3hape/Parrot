import CryptoKit
import Foundation
import SQLite3

// Temporary, signed QA helper using Parrot's existing sandbox identity. It emits
// aggregate history proof, and can remove only an explicitly named QA input
// directory in the app's temporary area. It never exports meeting text/audio.
func output(_ value: [String: Any]) throws {
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data("\n".utf8))
}

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
do {
    if ["--history-check", "--history-check-before"].contains(CommandLine.arguments.dropFirst().first ?? "") {
        var condition = ""
        if CommandLine.arguments[1] == "--history-check-before" {
            guard CommandLine.arguments.count == 3,
                  let date = ISO8601DateFormatter().date(from: CommandLine.arguments[2]) else { throw CocoaError(.fileReadUnknown) }
            condition = " WHERE ZDATE < \(date.timeIntervalSinceReferenceDate)"
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(support.appendingPathComponent("default.store").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        func scalar(_ sql: String) throws -> Int {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            return Int(sqlite3_column_int64(query, 0))
        }
        func rowHash(_ sql: String) throws -> String {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
            defer { sqlite3_finalize(query) }
            var digest = SHA256()
            while sqlite3_step(query) == SQLITE_ROW {
                digest.update(data: Data([255]))
                for column in 0..<sqlite3_column_count(query) {
                    let type = sqlite3_column_type(query, column)
                    let payload: Data
                    if type == SQLITE_INTEGER {
                        var value = sqlite3_column_int64(query, column).bigEndian
                        payload = withUnsafeBytes(of: &value) { Data($0) }
                    } else if type == SQLITE_FLOAT {
                        var value = sqlite3_column_double(query, column).bitPattern.bigEndian
                        payload = withUnsafeBytes(of: &value) { Data($0) }
                    } else if type == SQLITE_NULL { payload = Data() }
                    else {
                        let count = Int(sqlite3_column_bytes(query, column))
                        payload = count == 0 ? Data() : Data(bytes: sqlite3_column_blob(query, column)!, count: count)
                    }
                    var length = UInt64(payload.count).bigEndian
                    digest.update(data: Data([UInt8(type)]))
                    digest.update(data: withUnsafeBytes(of: &length) { Data($0) })
                    digest.update(data: payload)
                }
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT ZID FROM ZMEETING\(condition) ORDER BY ZID", -1, &query, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(query) }
        var ids: [String] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(query, 0))
            guard let bytes = sqlite3_column_blob(query, 0), size > 0 else { throw CocoaError(.fileReadCorruptFile) }
            ids.append(Data(bytes: bytes, count: size).map { String(format: "%02x", $0) }.joined())
        }
        let fingerprint = SHA256.hash(data: Data(ids.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        let segmentQuery = condition.isEmpty ? "SELECT COUNT(*) FROM ZTRANSCRIPTSEGMENT"
            : "SELECT COUNT(*) FROM ZTRANSCRIPTSEGMENT JOIN ZMEETING ON ZTRANSCRIPTSEGMENT.ZMEETING = ZMEETING.Z_PK\(condition)"
        try output(["diagnostic": "history", "meetings": try scalar("SELECT COUNT(*) FROM ZMEETING\(condition)"),
                    "live_segments": try scalar(segmentQuery), "meeting_ids_sha256": fingerprint,
                    "meeting_data_sha256": try rowHash("SELECT ZID,ZDATE,ZDURATION,ZTITLE,ZSUMMARY,ZNOTES,ZTHEMNAME,ZSYSTEMAUDIOPATH,ZMICAUDIOPATH,ZSTATUS,ZBRIEF,ZCOACHING FROM ZMEETING\(condition) ORDER BY ZID"),
                    "live_transcript_data_sha256": try rowHash("SELECT s.ZID,s.ZTEXT,s.ZSTARTTIME,s.ZENDTIME,s.ZSPEAKERLABEL,s.ZCONFIDENCE,m.ZID FROM ZTRANSCRIPTSEGMENT s JOIN ZMEETING m ON s.ZMEETING=m.Z_PK\(condition) ORDER BY s.ZID")])
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--qa-meetings-after" {
        guard let cutoff = ISO8601DateFormatter().date(from: CommandLine.arguments[2]) else { throw CocoaError(.fileReadUnknown) }
        var database: OpaquePointer?
        guard sqlite3_open_v2(support.appendingPathComponent("default.store").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(database) }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT ZID,ZDATE,ZTITLE,ZDURATION FROM ZMEETING WHERE ZDATE > ? ORDER BY ZDATE", -1, &query, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, cutoff.timeIntervalSinceReferenceDate)
        var meetings: [[String: Any]] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let id = Data(bytes: sqlite3_column_blob(query, 0)!, count: Int(sqlite3_column_bytes(query, 0))).map { String(format: "%02x", $0) }.joined()
            let title = String(cString: sqlite3_column_text(query, 2))
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(query, 1))
            meetings.append(["id": id, "date": ISO8601DateFormatter().string(from: date), "title": title, "duration_seconds": sqlite3_column_double(query, 3)])
        }
        try output(["meetings": meetings])
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--final-artifact-check" {
        guard let cutoff = ISO8601DateFormatter().date(from: CommandLine.arguments[2]) else { throw CocoaError(.fileReadUnknown) }
        let root = support.appendingPathComponent("Parrot/BestTranscripts", isDirectory: true)
        var records: [[String: Any]] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let manifestURL = folder.appendingPathComponent("completed.json")
            guard let modified = try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= cutoff,
                  let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  let filename = manifest["artifactFilename"] as? String,
                  filename.hasPrefix("artifact-"), filename.hasSuffix(".json"), !filename.contains("/") else { continue }
            let artifactURL = folder.appendingPathComponent(filename)
            guard let size = try artifactURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2 * 1024 * 1024,
                  let artifact = try JSONSerialization.jsonObject(with: Data(contentsOf: artifactURL)) as? [String: Any],
                  let segments = artifact["segments"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            records.append(["meeting_id_sha256": SHA256.hash(data: Data(folder.lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined(),
                            "modelID": artifact["modelID"] as? String ?? "unknown", "segments": segments.count,
                            "transcript_characters": segments.reduce(0) { $0 + (($1["text"] as? String)?.count ?? 0) },
                            "alignment": artifact["alignmentQuality"] as? String ?? "unknown"])
        }
        try output(["diagnostic": "final_artifacts", "count": records.count, "records": records])
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--remove-quality-fixtures" {
        let name = CommandLine.arguments[2]
        guard name.range(of: "^ParrotQualityFixtures-[0-9]{8}$", options: .regularExpression) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.removeItem(at: folder)
        try output(["diagnostic": "qa_cleanup", "removed": name, "exists_after": FileManager.default.fileExists(atPath: folder.path)])
    } else {
        throw CocoaError(.fileReadUnknown)
    }
} catch {
    try? output(["diagnostic": "qa_data", "error_type": String(reflecting: type(of: error))])
    exit(1)
}
