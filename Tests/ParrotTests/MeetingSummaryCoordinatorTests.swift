import SwiftData
import XCTest
@testable import Parrot

@MainActor
final class MeetingSummaryCoordinatorTests: XCTestCase {
    func testManualTitleDoesNotPreventLocalSummaryGeneration() async throws {
        let meeting = Meeting(title: "Client Workshop")
        meeting.status = .done
        meeting.segments = [segment("We agreed to redesign the onboarding flow.")]
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(meeting)
        try context.save()
        let coordinator = MeetingTitleCoordinator(
            generate: { snapshot in emptyTitle(for: snapshot) },
            generateSummary: { snapshot in
                MeetingSummaryGeneration(
                    title: "Onboarding Flow Redesign Agreement",
                    summary: "The team agreed to redesign the onboarding flow.",
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt
                )
            }
        )
        coordinator.configure(modelContext: context, enqueueExisting: false)

        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertEqual(meeting.title, "Client Workshop")
        XCTAssertEqual(meeting.summary, "The team agreed to redesign the onboarding flow.")
        XCTAssertEqual(meeting.summaryOriginRaw, "local")
        XCTAssertEqual(meeting.summaryGeneratorVersion, MeetingTitleCoordinator.summaryGeneratorVersion)
        XCTAssertNotNil(meeting.summaryGeneratedAt)
    }

    func testExistingLegacySummaryIsNeverOverwritten() async throws {
        let meeting = Meeting()
        meeting.status = .done
        meeting.summary = "Existing user-owned report"
        meeting.segments = [segment("A different transcript topic")]
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(meeting)
        try context.save()
        let calls = SummaryCallCounter()
        let coordinator = MeetingTitleCoordinator(
            generate: { snapshot in emptyTitle(for: snapshot) },
            generateSummary: { snapshot in
                await calls.increment()
                return MeetingSummaryGeneration(
                    title: "Different Transcript Replacement",
                    summary: "Replacement",
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt
                )
            }
        )
        coordinator.configure(modelContext: context, enqueueExisting: false)

        await coordinator.processImmediatelyForTesting(meeting)

        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(meeting.summary, "Existing user-owned report")
    }

    func testUnchangedLocalSummaryUsesCacheWithoutAnotherModelCall() async throws {
        let meeting = Meeting()
        meeting.status = .done
        meeting.segments = [segment("The checkout redesign is ready for testing.")]
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(meeting)
        try context.save()
        let calls = SummaryCallCounter()
        let coordinator = MeetingTitleCoordinator(
            generate: { snapshot in emptyTitle(for: snapshot) },
            generateSummary: { snapshot in
                await calls.increment()
                return MeetingSummaryGeneration(
                    title: "Checkout Redesign Testing Readiness",
                    summary: "The checkout redesign is ready for testing.",
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt
                )
            }
        )
        coordinator.configure(modelContext: context, enqueueExisting: false)

        await coordinator.processImmediatelyForTesting(meeting)
        await coordinator.processImmediatelyForTesting(meeting)

        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testContextualTitleFromWholeMeetingSummaryReplacesOldAutomaticTitle() async throws {
        let meeting = Meeting()
        meeting.status = .done
        meeting.title = "Player Experience"
        meeting.titleOriginRaw = "automatic"
        meeting.segments = [segment("We reviewed tournament submission errors and rejected-state feedback.")]
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(meeting)
        try context.save()
        let coordinator = MeetingTitleCoordinator(
            generate: { snapshot in emptyTitle(for: snapshot) },
            generateSummary: { snapshot in
                MeetingSummaryGeneration(
                    title: "Tournament Submission Flow Review",
                    summary: "The team reviewed submission errors and rejected-state feedback.",
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt
                )
            }
        )
        coordinator.configure(modelContext: context, enqueueExisting: false)

        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertEqual(meeting.title, "Tournament Submission Flow Review")
        XCTAssertEqual(meeting.titleGeneratorVersion, MeetingTitleCoordinator.generatorVersion)
    }

    func testNilResultForSubstantialTranscriptPreservesPreviousLocalArtifact() async throws {
        let meeting = Meeting()
        meeting.status = .done
        meeting.title = "Existing Contextual Meeting Title"
        meeting.titleOriginRaw = "automatic"
        meeting.titleGeneratorVersion = "older-title-version"
        meeting.summary = "Existing local summary that remains useful."
        meeting.summaryOriginRaw = "local"
        meeting.summaryGeneratorVersion = "older-summary-version"
        meeting.segments = [segment(String(repeating: "Tournament setup and bracket validation. ", count: 30))]
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(meeting)
        try context.save()
        let coordinator = MeetingTitleCoordinator(
            generate: { snapshot in emptyTitle(for: snapshot) },
            generateSummary: { snapshot in
                MeetingSummaryGeneration(
                    title: nil,
                    summary: nil,
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt
                )
            }
        )
        coordinator.configure(modelContext: context, enqueueExisting: false)

        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertEqual(meeting.title, "Existing Contextual Meeting Title")
        XCTAssertEqual(meeting.titleGeneratorVersion, "older-title-version")
        XCTAssertEqual(meeting.summary, "Existing local summary that remains useful.")
        XCTAssertEqual(meeting.summaryGeneratorVersion, "older-summary-version")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(startTime: 0, endTime: 1, text: text, speakerLabel: "Them", confidence: 1)
    }
}

private actor SummaryCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private func emptyTitle(for snapshot: MeetingTitleSnapshot) -> MeetingTitleGeneration {
    MeetingTitleGeneration(
        title: nil,
        fingerprint: snapshot.fingerprint,
        coverageReceipt: snapshot.coverageReceipt,
        reductionDepth: 0
    )
}
