import XCTest
@testable import Parrot

final class HybridFinalTranscriptionServiceTests: XCTestCase {
    func testMonolingualWindowRetainsBaselineEvenWhenRefinerDisagrees() async throws {
        let baseline = HybridTestRecognizer(text: "baseline words", languages: [])
        let refiner = HybridTestRecognizer(text: "different words", languages: ["Polish"])
        let service = HybridFinalTranscriptionService(whisper: baseline, native: refiner)
        let result = try await service.transcribeWindows([window()], vocabulary: "")
        XCTAssertEqual(result[0].first?.text, "baseline words")
        let count = await baseline.calls
        XCTAssertEqual(count, 1)
    }

    func testActualLanguageSwitchUsesRefinementAndSkipsBaseline() async throws {
        let baseline = HybridTestRecognizer(text: "wrong translation", languages: [])
        let refiner = HybridTestRecognizer(text: "original languages", languages: ["Russian", "Polish"])
        let service = HybridFinalTranscriptionService(whisper: baseline, native: refiner)
        let result = try await service.transcribeWindows([window()], vocabulary: "")
        XCTAssertEqual(result[0].first?.text, "original languages")
        let count = await baseline.calls
        XCTAssertEqual(count, 0)
    }

    func testUnavailableRefinementFallsBackWithoutDroppingTheWindow() async throws {
        let baseline = HybridTestRecognizer(text: "saved baseline", languages: [])
        let refiner = HybridTestRecognizer(text: "", languages: [], failure: .workerUnavailable)
        let service = HybridFinalTranscriptionService(whisper: baseline, native: refiner)
        let result = try await service.transcribeWindows([window()], vocabulary: "")
        XCTAssertEqual(result[0].first?.text, "saved baseline")
    }

    func testRecordingCancellationNeverStartsMoreBaselineInference() async {
        let baseline = HybridTestRecognizer(text: "must not run", languages: [])
        let refiner = HybridTestRecognizer(text: "", languages: [], cancelled: true)
        let service = HybridFinalTranscriptionService(whisper: baseline, native: refiner)
        do {
            _ = try await service.transcribeWindows([window()], vocabulary: "")
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let count = await baseline.calls
        XCTAssertEqual(count, 0)
    }

    func testAliasesAndUnknownTagsDoNotFabricateLanguageSwitches() {
        XCTAssertFalse(HybridFinalTranscriptionService.containsLanguageSwitch(["ru", "Russian", "unknown", ""]))
        XCTAssertTrue(HybridFinalTranscriptionService.containsLanguageSwitch(["en", "Polish"]))
    }

    private func window() -> BestWhisperWindowInput {
        .init(samples: Array(repeating: 0.1, count: 16_000), speaker: .them, absoluteWindowStart: 0)
    }
}

private actor HybridTestRecognizer: LanguageAwareFinalRecognizing {
    nonisolated let preferredWindowBatchSize = 4
    nonisolated let modelIdentity = "test-local-model"
    nonisolated let modelDisplayName = "Test local model"
    let lastDetectedLanguages: [String]
    let text: String
    let failure: NativeFinalASRError?
    let cancelled: Bool
    private(set) var calls = 0

    init(text: String, languages: [String], failure: NativeFinalASRError? = nil, cancelled: Bool = false) {
        self.text = text
        self.lastDetectedLanguages = languages
        self.failure = failure
        self.cancelled = cancelled
    }

    func prepareLocalOnly(modelName: String) async throws {}

    func transcribeWindow(samples: [Float], speaker: BestTranscriptSpeaker, absoluteWindowStart: TimeInterval, vocabulary: String) async throws -> [BestTranscriptSegment] {
        calls += 1
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
        return [.init(id: UUID(), speaker: speaker, startTime: absoluteWindowStart, endTime: absoluteWindowStart + 1, text: text, confidence: nil, detectedLanguage: lastDetectedLanguages.first, words: [])]
    }
}
