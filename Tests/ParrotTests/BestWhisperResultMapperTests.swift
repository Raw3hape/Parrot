import XCTest
@testable import Parrot

final class BestWhisperResultMapperTests: XCTestCase {
    func testLongFormPolicyUsesAutoLanguageTimestampsAndRequestedWorkers() {
        let policy = WhisperLongFormPolicy.bestLocal(workerCount: 4)

        XCTAssertNil(policy.language)
        XCTAssertTrue(policy.detectLanguage)
        XCTAssertTrue(policy.wordTimestamps)
        XCTAssertFalse(policy.withoutTimestamps)
        XCTAssertEqual(policy.concurrentWorkerCount, 4)
        XCTAssertTrue(policy.usesVADChunking)
    }

    func testBackgroundWindowCountFitsMachineCapacity() {
        let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
        XCTAssertEqual(
            WhisperLongFormPolicy.recommendedWindowBatchSize(
                processorCount: 18,
                physicalMemory: 64 * gibibyte
            ),
            4
        )
        XCTAssertEqual(
            WhisperLongFormPolicy.recommendedWindowBatchSize(
                processorCount: 8,
                physicalMemory: 8 * gibibyte
            ),
            1
        )
    }

    func testBestExportPreparationNeverDownloadsAModel() {
        XCTAssertFalse(WhisperPreparationPolicy.bestExport.allowDownload)
    }

    func testLocalModelLocatorFindsOnlyCompleteCachedModelFolder() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParrotModelLocator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(
                "openai_whisper-\(WhisperModelService.fallbackModel)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("TextDecoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))

        XCTAssertEqual(
            WhisperLocalModelLocator.modelFolder(
                modelName: WhisperModelService.fallbackModel,
                homeDirectories: [home]
            ),
            folder
        )
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent("TextDecoder.mlmodelc")
        )
        XCTAssertNil(
            WhisperLocalModelLocator.modelFolder(
                modelName: WhisperModelService.fallbackModel,
                homeDirectories: [home]
            )
        )
    }

    func testMapperPreservesWordTimestampsLanguageAndSpeaker() {
        let raw = BestRawWhisperSegment(
            startTime: 0.5,
            endTime: 2,
            text: " <|pl|> Dzień dobry ",
            averageLogProbability: -0.2,
            detectedLanguage: "pl",
            words: [
                .init(text: "Dzień ", startTime: 0.5, endTime: 1.1, probability: 0.91),
                .init(text: "dobry", startTime: 1.1, endTime: 2, probability: 0.93),
            ]
        )

        let mapped = BestWhisperResultMapper.map(
            [raw],
            speaker: .them,
            absoluteWindowStart: 28
        )

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].speaker, .them)
        XCTAssertEqual(mapped[0].startTime, 28.5, accuracy: 0.001)
        XCTAssertEqual(mapped[0].endTime, 30, accuracy: 0.001)
        XCTAssertEqual(mapped[0].text, "Dzień dobry")
        XCTAssertEqual(mapped[0].detectedLanguage, "pl")
        XCTAssertEqual(mapped[0].words.map(\.text), ["Dzień ", "dobry"])
        XCTAssertEqual(mapped[0].words[0].startTime, 28.5, accuracy: 0.001)
        XCTAssertEqual(mapped[0].words[1].endTime, 30, accuracy: 0.001)
        XCTAssertEqual(mapped[0].confidence ?? 0, exp(-0.2), accuracy: 0.0001)
    }

    func testMapperRejectsInvalidOrEmptyWhisperSegments() {
        let raw = [
            BestRawWhisperSegment(
                startTime: .nan,
                endTime: 1,
                text: "Invalid",
                averageLogProbability: -0.2,
                detectedLanguage: "en",
                words: []
            ),
            BestRawWhisperSegment(
                startTime: 1,
                endTime: 2,
                text: "<|startoftranscript|>",
                averageLogProbability: -0.2,
                detectedLanguage: "en",
                words: []
            ),
        ]

        XCTAssertTrue(
            BestWhisperResultMapper.map(
                raw,
                speaker: .me,
                absoluteWindowStart: 0
            ).isEmpty
        )
    }
}
