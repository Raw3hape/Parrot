import SwiftData
import XCTest
@testable import Parrot

@MainActor
final class MeetingTitleCoordinatorTests: XCTestCase {
    func testCompletedPlaceholderMeetingReceivesAutomaticTitle() async throws {
        let (container, meeting) = try makeMeeting(text: "Polish onboarding roadmap")
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            MeetingTitleGeneration(
                title: "Polish Onboarding",
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 1
            )
        })

        coordinator.configure(modelContext: ModelContext(container), enqueueExisting: false)
        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertEqual(meeting.title, "Polish Onboarding")
        XCTAssertEqual(meeting.titleOriginRaw, "automatic")
        XCTAssertNotNil(meeting.titleTranscriptFingerprint)
        XCTAssertEqual(meeting.titleGeneratorVersion, MeetingTitleCoordinator.generatorVersion)
        XCTAssertNotNil(meeting.titleGeneratedAt)
    }

    func testManualTitleAlwaysWins() async throws {
        let (container, meeting) = try makeMeeting(text: "Polish onboarding roadmap")
        XCTAssertTrue(meeting.applyManualTitle("Client Alpha"))
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            MeetingTitleGeneration(
                title: "Wrong Automatic Title",
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 1
            )
        })

        coordinator.configure(modelContext: ModelContext(container), enqueueExisting: false)
        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertEqual(meeting.title, "Client Alpha")
        XCTAssertEqual(meeting.titleOriginRaw, "manual")
    }

    func testInvalidCoverageNeverChangesTitle() async throws {
        let (container, meeting) = try makeMeeting(text: "Polish onboarding roadmap")
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            MeetingTitleGeneration(
                title: "Polish Onboarding",
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt.consuming([]),
                reductionDepth: 1
            )
        })

        coordinator.configure(modelContext: ModelContext(container), enqueueExisting: false)
        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertTrue(meeting.hasPlaceholderTitle)
        XCTAssertEqual(meeting.titleOriginRaw, "default")
    }

    func testUnchangedTranscriptIsNotReprocessed() async throws {
        let (container, meeting) = try makeMeeting(text: "Polish onboarding roadmap")
        let counter = LockedCounter()
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            counter.increment()
            return MeetingTitleGeneration(
                title: "Polish Onboarding",
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 1
            )
        })
        coordinator.configure(modelContext: ModelContext(container), enqueueExisting: false)

        await coordinator.processImmediatelyForTesting(meeting)
        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertEqual(counter.value, 1)
    }

    func testStricterGeneratorRevertsRejectedAutomaticTitleToDateFallback() async throws {
        let (container, meeting) = try makeMeeting(text: "Mm hmm. It's not, you know.")
        meeting.title = "Mm Hmm"
        meeting.titleOriginRaw = "automatic"
        meeting.titleGeneratorVersion = "natural-language-title-v1"
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            MeetingTitleGeneration(
                title: nil,
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 1
            )
        })
        coordinator.configure(modelContext: ModelContext(container), enqueueExisting: false)

        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertEqual(meeting.title, Meeting.defaultTitle(for: meeting.date))
        XCTAssertEqual(meeting.titleOriginRaw, "default")
        XCTAssertEqual(meeting.titleGeneratorVersion, MeetingTitleCoordinator.generatorVersion)
    }

    func testCustomLegacyTitleIsConservativelyProtected() async throws {
        let (container, meeting) = try makeMeeting(text: "Polish onboarding roadmap")
        meeting.title = "Client Alpha"
        meeting.titleOriginRaw = "default" // Simulates a lightweight-migrated row.
        let counter = LockedCounter()
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            counter.increment()
            return MeetingTitleGeneration(
                title: "Polish Onboarding",
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 1
            )
        })
        coordinator.configure(modelContext: ModelContext(container), enqueueExisting: false)

        await coordinator.processImmediatelyForTesting(meeting)

        XCTAssertEqual(meeting.title, "Client Alpha")
        XCTAssertEqual(counter.value, 0)
    }

    func testRenamingCurrentJobDoesNotStrandNextQueuedMeeting() async throws {
        let (container, context, meetings) = try makeMeetings(texts: ["first topic", "second topic"])
        let first = meetings[0]
        let second = meetings[1]
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            let raw = snapshot.orderedSegments.map(\.text).joined()
            if raw.contains("first") {
                let deadline = Date().addingTimeInterval(0.5)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            return MeetingTitleGeneration(
                title: raw.contains("second") ? "Second Topic" : "First Topic",
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 1
            )
        })
        coordinator.configure(modelContext: context, enqueueExisting: false)
        coordinator.enqueue(first)
        coordinator.enqueue(second)
        let firstStarted = await waitUntil { coordinator.state == .generating(first.id) }
        XCTAssertTrue(firstStarted)

        coordinator.rename(first, draft: "Manual First")

        let secondFinished = await waitUntil { second.title == "Second Topic" }
        XCTAssertTrue(secondFinished)
        XCTAssertEqual(first.title, "Manual First")
        XCTAssertEqual(second.titleOriginRaw, "automatic")
        _ = container // Retain the in-memory store through the async assertions.
    }

    func testPauseForRecordingCooperativelyCancelsLongGeneration() async throws {
        let (container, context, meetings) = try makeMeetings(texts: ["long running topic"])
        let meeting = meetings[0]
        let counter = LockedCounter()
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            counter.increment()
            if counter.value == 1 {
                let deadline = Date().addingTimeInterval(2)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            return MeetingTitleGeneration(
                title: "Long Topic",
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 1
            )
        })
        coordinator.configure(modelContext: context, enqueueExisting: false)
        coordinator.enqueue(meeting)
        let generationStarted = await waitUntil { coordinator.state == .generating(meeting.id) }
        XCTAssertTrue(generationStarted)

        let clock = ContinuousClock()
        let start = clock.now
        await coordinator.pauseForRecording()
        let elapsed = start.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .milliseconds(250))
        XCTAssertEqual(coordinator.state, .pausedForRecording)
        coordinator.resumeAfterRecording()
        let resumed = await waitUntil { meeting.title == "Long Topic" }
        XCTAssertTrue(resumed)
        _ = container
    }

    func testManualRenameRollsBackWhenPersistenceFails() throws {
        let (container, meeting) = try makeMeeting(text: "Polish onboarding roadmap")
        let coordinator = MeetingTitleCoordinator(
            persist: { _ in throw PersistenceFailure.expected }
        )
        coordinator.configure(modelContext: ModelContext(container), enqueueExisting: false)

        coordinator.rename(meeting, draft: "Client Alpha")

        XCTAssertTrue(meeting.hasPlaceholderTitle)
        XCTAssertEqual(meeting.titleOriginRaw, "default")
        XCTAssertNotNil(coordinator.lastError)
    }

    func testMemoryDeferralPreservesExistingTitleAndRetriesLater() async throws {
        let (container, meeting) = try makeMeeting(text: "Checkout redesign roadmap")
        meeting.title = "Checkout Roadmap"
        meeting.titleOriginRaw = "automatic"
        meeting.titleGeneratorVersion = "older-generator"
        guard let context = meeting.modelContext else {
            return XCTFail("Expected the meeting to remain attached to its test context")
        }
        try context.save()
        let counter = LockedCounter()
        let coordinator = MeetingTitleCoordinator(
            memoryRetryDelay: .milliseconds(250),
            generate: { snapshot in
                counter.increment()
                if counter.value == 1 {
                    return MeetingTitleGeneration(
                        title: nil,
                        fingerprint: snapshot.fingerprint,
                        coverageReceipt: snapshot.coverageReceipt,
                        reductionDepth: 0,
                        disposition: .deferred(.memoryPressure)
                    )
                }
                return MeetingTitleGeneration(
                    title: "Checkout Redesign",
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt,
                    reductionDepth: 1
                )
            }
        )
        coordinator.configure(modelContext: context, enqueueExisting: false)
        coordinator.enqueue(meeting)

        let deferred = await waitUntil { counter.value == 1 && !coordinator.hasRunningJobs }
        XCTAssertTrue(deferred)
        XCTAssertEqual(meeting.title, "Checkout Roadmap")
        XCTAssertEqual(meeting.titleGeneratorVersion, "older-generator")
        XCTAssertNotNil(coordinator.lastError)

        let retried = await waitUntil(timeout: .seconds(1)) {
            meeting.title == "Checkout Redesign"
        }
        XCTAssertTrue(retried)
        XCTAssertEqual(meeting.titleGeneratorVersion, MeetingTitleCoordinator.generatorVersion)
        _ = container
    }

    func testGenerateMissingTitlesImmediatelyRestartsDeferredQueuedMeeting() async throws {
        let (container, meeting) = try makeMeeting(text: "Checkout redesign roadmap")
        guard let context = meeting.modelContext else {
            return XCTFail("Expected the meeting to remain attached to its test context")
        }
        let counter = LockedCounter()
        let coordinator = MeetingTitleCoordinator(
            memoryRetryDelay: .seconds(30),
            generate: { snapshot in
                counter.increment()
                if counter.value == 1 {
                    return MeetingTitleGeneration(
                        title: nil,
                        fingerprint: snapshot.fingerprint,
                        coverageReceipt: snapshot.coverageReceipt,
                        reductionDepth: 0,
                        disposition: .deferred(.memoryPressure)
                    )
                }
                return MeetingTitleGeneration(
                    title: "Checkout Redesign",
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt,
                    reductionDepth: 1
                )
            }
        )
        coordinator.configure(modelContext: context, enqueueExisting: false)
        coordinator.enqueue(meeting)
        let deferred = await waitUntil { counter.value == 1 && !coordinator.hasRunningJobs }
        XCTAssertTrue(deferred)

        coordinator.generateMissingTitles()

        let completed = await waitUntil { meeting.title == "Checkout Redesign" }
        XCTAssertTrue(completed)
        XCTAssertEqual(counter.value, 2)
        _ = container
    }

    func testPauseAndTerminationSynchronouslyReleaseTitleRuntime() async throws {
        let calls = LockedCounter()
        let coordinator = MeetingTitleCoordinator(
            shutdownRuntime: { calls.increment() },
            generate: { snapshot in
                MeetingTitleGeneration(
                    title: nil,
                    fingerprint: snapshot.fingerprint,
                    coverageReceipt: snapshot.coverageReceipt,
                    reductionDepth: 0
                )
            }
        )

        await coordinator.pauseForRecording()
        XCTAssertEqual(calls.value, 1)

        await coordinator.prepareForTermination()
        XCTAssertEqual(calls.value, 2)
    }

    func testRapidDisableEnableRescansCanceledCurrentMeeting() async throws {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: MeetingTitleCoordinator.automaticTitlesKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: MeetingTitleCoordinator.automaticTitlesKey) }
            else { defaults.removeObject(forKey: MeetingTitleCoordinator.automaticTitlesKey) }
        }
        defaults.set(true, forKey: MeetingTitleCoordinator.automaticTitlesKey)
        let (container, context, meetings) = try makeMeetings(texts: ["Checkout redesign roadmap"])
        let meeting = meetings[0]
        let counter = LockedCounter()
        let coordinator = MeetingTitleCoordinator(generate: { snapshot in
            counter.increment()
            if counter.value == 1 {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            }
            return MeetingTitleGeneration(
                title: "Checkout Redesign",
                fingerprint: snapshot.fingerprint,
                coverageReceipt: snapshot.coverageReceipt,
                reductionDepth: 1
            )
        })
        coordinator.configure(modelContext: context, enqueueExisting: false)
        coordinator.enqueue(meeting)
        let started = await waitUntil { coordinator.state == .generating(meeting.id) }
        XCTAssertTrue(started)

        defaults.set(false, forKey: MeetingTitleCoordinator.automaticTitlesKey)
        coordinator.setAutomaticEnabled(false)
        defaults.set(true, forKey: MeetingTitleCoordinator.automaticTitlesKey)
        coordinator.setAutomaticEnabled(true)

        let completed = await waitUntil { meeting.title == "Checkout Redesign" }
        XCTAssertTrue(completed)
        XCTAssertEqual(counter.value, 2)
        _ = container
    }

    private func makeMeeting(text: String) throws -> (ModelContainer, Meeting) {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let meeting = Meeting(date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.status = .done
        let segment = TranscriptSegment(startTime: 0, endTime: 2, text: text, speakerLabel: "Them")
        context.insert(meeting)
        context.insert(segment)
        segment.meeting = meeting
        try context.save()
        return (container, meeting)
    }

    private func makeMeetings(
        texts: [String]
    ) throws -> (ModelContainer, ModelContext, [Meeting]) {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        var meetings: [Meeting] = []
        for (index, text) in texts.enumerated() {
            let meeting = Meeting(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            meeting.status = .done
            let segment = TranscriptSegment(
                startTime: 0,
                endTime: 2,
                text: text,
                speakerLabel: "Them"
            )
            context.insert(meeting)
            context.insert(segment)
            segment.meeting = meeting
            meetings.append(meeting)
        }
        try context.save()
        return (container, context, meetings)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1.5),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private enum PersistenceFailure: Error {
    case expected
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
