import XCTest
@testable import Parrot

final class BestTranscriptionCoreTests: XCTestCase {
    func testWindowPlanCoversAudioExactlyOnceThroughOwnershipIntervals() {
        let plan = BestAudioWindowPlanner.plan(
            totalFrames: 65 * 16_000,
            sampleRate: 16_000,
            windowSeconds: 30,
            overlapSeconds: 2
        )

        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.map(\.startFrame), [0, 28 * 16_000, 56 * 16_000])
        XCTAssertEqual(plan.map(\.endFrame), [30 * 16_000, 58 * 16_000, 65 * 16_000])
        XCTAssertEqual(plan.first?.ownedStartFrame, 0)
        XCTAssertEqual(plan.first?.ownedEndFrame, 29 * 16_000)
        XCTAssertEqual(plan[1].ownedStartFrame, 29 * 16_000)
        XCTAssertEqual(plan[1].ownedEndFrame, 57 * 16_000)
        XCTAssertEqual(plan.last?.ownedStartFrame, 57 * 16_000)
        XCTAssertEqual(plan.last?.ownedEndFrame, 65 * 16_000)
    }

    func testTwoHourRecordingStillUsesOnlyBoundedThirtySecondWindows() {
        let plan = BestAudioWindowPlanner.plan(
            totalFrames: 2 * 60 * 60 * 16_000,
            sampleRate: 16_000,
            windowSeconds: 30,
            overlapSeconds: 2
        )

        XCTAssertEqual(plan.count, 258)
        XCTAssertLessThanOrEqual(
            plan.map { $0.endFrame - $0.startFrame }.max() ?? .max,
            30 * 16_000
        )
        XCTAssertEqual(plan.first?.ownedStartFrame, 0)
        XCTAssertEqual(plan.last?.ownedEndFrame, 2 * 60 * 60 * 16_000)
    }

    func testOwnershipDropsBoundaryDuplicateButKeepsEveryUniqueWord() {
        let first = BestAudioWindow(
            index: 0,
            startFrame: 0,
            endFrame: 480_000,
            ownedStartFrame: 0,
            ownedEndFrame: 464_000
        )
        let second = BestAudioWindow(
            index: 1,
            startFrame: 448_000,
            endFrame: 928_000,
            ownedStartFrame: 464_000,
            ownedEndFrame: 912_000
        )
        let repeated = BestTranscriptWord(text: "projekt", startTime: 28.7, endTime: 29.2, probability: 0.9)
        let continuation = BestTranscriptWord(text: "dzisiaj", startTime: 29.3, endTime: 29.8, probability: 0.9)

        let firstWords = BestWindowOwnership.wordsOwned(
            [repeated, continuation],
            by: first,
            sampleRate: 16_000
        )
        let secondWords = BestWindowOwnership.wordsOwned(
            [repeated, continuation],
            by: second,
            sampleRate: 16_000
        )

        XCTAssertEqual(firstWords.map(\.text), ["projekt"])
        XCTAssertEqual(secondWords.map(\.text), ["dzisiaj"])
    }

    func testSegmentOwnershipRebuildsTextFromWordsOwnedByWindow() {
        let window = BestAudioWindow(
            index: 1,
            startFrame: 448_000,
            endFrame: 928_000,
            ownedStartFrame: 464_000,
            ownedEndFrame: 912_000
        )
        let input = segment(
            "projekt dzisiaj",
            speaker: .them,
            start: 28.7,
            end: 29.8,
            words: [
                .init(text: "projekt ", startTime: 28.7, endTime: 29.2, probability: 0.9),
                .init(text: "dzisiaj", startTime: 29.3, endTime: 29.8, probability: 0.9),
            ]
        )

        let owned = BestWindowOwnership.segmentsOwned(
            [input],
            by: window,
            sampleRate: 16_000
        )

        XCTAssertEqual(owned.count, 1)
        XCTAssertEqual(owned[0].text, "dzisiaj")
        XCTAssertEqual(owned[0].startTime, 29.3, accuracy: 0.001)
    }

    func testMergeKeepsRealSimultaneousSpeechAndShortAcknowledgements() {
        let segments = [
            segment("Tak", speaker: .them, start: 10, end: 10.4),
            segment("Tak", speaker: .me, start: 10.1, end: 10.5),
            segment("Wyślę dokument jutro rano", speaker: .them, start: 12, end: 14),
            segment("Dobrze, sprawdzę po spotkaniu", speaker: .me, start: 12.2, end: 14.5),
        ]

        let merged = BestTranscriptMerger.merge(segments)

        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.map(\.speaker), [.them, .me, .them, .me])
    }

    func testMergeRemovesLongCrossTrackEchoAndPrefersSystemAudio() {
        let segments = [
            segment(
                "Wyślę wszystkie dokumenty jutro rano",
                speaker: .them,
                start: 20,
                end: 23,
                confidence: 0.82
            ),
            segment(
                "Wyślę wszystkie dokumenty jutro rano",
                speaker: .me,
                start: 20.1,
                end: 23.1,
                confidence: 0.95
            ),
        ]

        let merged = BestTranscriptMerger.merge(segments)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.speaker, .them)
    }

    func testCacheRequiresExactAudioAndConfigurationFingerprint() {
        let fingerprint = BestTranscriptionFingerprint(
            modelID: "large-v3-v20240930_turbo",
            pipelineVersion: 1,
            vocabularyHash: "abc",
            tracks: [
                .init(
                    speaker: .them,
                    fileSize: 100,
                    modifiedAtNanoseconds: 200,
                    frameCount: 300,
                    sampleRate: 16_000
                ),
            ]
        )
        let manifest = BestTranscriptionManifest.completed(
            meetingID: UUID(),
            fingerprint: fingerprint,
            artifactFilename: "artifact.json"
        )

        XCTAssertTrue(manifest.hasValidCompletedArtifact(for: fingerprint))

        var changed = fingerprint
        changed.vocabularyHash = "different"
        XCTAssertFalse(manifest.hasValidCompletedArtifact(for: changed))
    }

    func testBestTXTContainsOnlyProvenanceAndFullTranscript() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let artifact = BestTranscriptArtifact(
            meetingID: UUID(),
            generatedAt: date,
            modelID: "large-v3-v20240930_turbo",
            pipelineVersion: 1,
            fingerprint: .init(
                modelID: "large-v3-v20240930_turbo",
                pipelineVersion: 1,
                vocabularyHash: "none",
                tracks: []
            ),
            alignmentQuality: .estimated,
            warnings: [],
            segments: [
                segment("Dzień dobry", speaker: .them, start: 13, end: 15),
                segment("Здравствуйте", speaker: .me, start: 21, end: 23),
            ]
        )

        let text = ExportService.exportBestTranscriptTXT(
            title: "Demo",
            date: date,
            duration: 90,
            artifact: artifact
        )

        XCTAssertTrue(text.contains("Generated locally with Whisper Large V3 Turbo"))
        XCTAssertTrue(text.contains("Language detection: Polish / Russian / English auto-detection"))
        XCTAssertTrue(text.contains("[00:00:13] Them: Dzień dobry"))
        XCTAssertTrue(text.contains("[00:00:21] Me: Здравствуйте"))
        XCTAssertFalse(text.contains("Summary"))
        XCTAssertFalse(text.contains("Coaching"))
        XCTAssertFalse(text.contains("Insights"))
    }

    func testSilencePolicyKeepsAQuiet150MillisecondReplyInsideLongWindow() {
        var samples = Array(repeating: Float.zero, count: 30 * 16_000)
        for index in 0..<(150 * 16) {
            samples[index] = Float(sin(Double(index) * 0.1) * 0.01)
        }

        XCTAssertFalse(BestTranscriptionSignalPolicy.isSilent(samples))
        XCTAssertTrue(
            BestTranscriptionSignalPolicy.isSilent(
                Array(repeating: 0, count: 30 * 16_000)
            )
        )
    }

    private func segment(
        _ text: String,
        speaker: BestTranscriptSpeaker,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Float = 0.9,
        words: [BestTranscriptWord] = []
    ) -> BestTranscriptSegment {
        BestTranscriptSegment(
            id: UUID(),
            speaker: speaker,
            startTime: start,
            endTime: end,
            text: text,
            confidence: confidence,
            detectedLanguage: nil,
            words: words
        )
    }
}
