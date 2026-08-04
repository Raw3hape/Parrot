import XCTest
@testable import Parrot

final class QwenMeetingTitleGeneratorTests: XCTestCase {
    func testMemoryAdmissionRequiresNormalPressureAndConfiguredHeadroom() {
        let policy = QwenMemoryAdmissionPolicy(requiredReclaimableBytes: 6 * 1_024 * 1_024 * 1_024)

        XCTAssertEqual(
            policy.decision(for: QwenMemorySnapshot(pressure: .normal, reclaimableBytes: 8 * 1_024 * 1_024 * 1_024)),
            .admitted
        )
        XCTAssertEqual(
            policy.decision(for: QwenMemorySnapshot(pressure: .warning, reclaimableBytes: 20 * 1_024 * 1_024 * 1_024)),
            .deferredForMemoryPressure
        )
        XCTAssertEqual(
            policy.decision(for: QwenMemorySnapshot(pressure: .normal, reclaimableBytes: 5 * 1_024 * 1_024 * 1_024)),
            .deferredForMemoryPressure
        )
        XCTAssertEqual(
            policy.decision(for: QwenMemorySnapshot(pressure: .unknown, reclaimableBytes: 20 * 1_024 * 1_024 * 1_024)),
            .deferredForMemoryPressure
        )
    }

    func testDefaultStartupHeadroomIncludesMeasuredModelAndTransientMargin() {
        XCTAssertEqual(
            QwenMemoryAdmissionPolicy.defaultRequiredReclaimableBytes,
            10 * 1_024 * 1_024 * 1_024
        )
    }

    func testLoadedModelMayContinueBelowStartupHeadroomOnlyAtNormalPressure() {
        let policy = QwenMemoryAdmissionPolicy(requiredReclaimableBytes: 6 * 1_024 * 1_024 * 1_024)

        XCTAssertEqual(
            policy.continuationDecision(
                for: QwenMemorySnapshot(pressure: .normal, reclaimableBytes: 1 * 1_024 * 1_024 * 1_024)
            ),
            .admitted
        )
        XCTAssertEqual(
            policy.continuationDecision(
                for: QwenMemorySnapshot(pressure: .warning, reclaimableBytes: 20 * 1_024 * 1_024 * 1_024)
            ),
            .deferredForMemoryPressure
        )
        XCTAssertEqual(
            policy.continuationDecision(
                for: QwenMemorySnapshot(pressure: .unknown, reclaimableBytes: 20 * 1_024 * 1_024 * 1_024)
            ),
            .deferredForMemoryPressure
        )
    }

    func testMemoryPressureDefersBeforeStartingRuntime() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, "Checkout redesign")])
        let runtime = FakeQwenTitleRuntime(
            response: Self.payload("Checkout Redesign", evidence: "Checkout redesign")
        )
        let generator = QwenMeetingTitleGenerator(
            runtime: runtime,
            memoryAdmission: { .deferredForMemoryPressure }
        )

        let result = await generator.generate(from: snapshot)
        let requests = await runtime.capturedRequests()
        let shutdownCount = await runtime.capturedShutdownCount()

        XCTAssertEqual(result.disposition, .deferred(.memoryPressure))
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(shutdownCount, 0)
    }

    func testMapsEveryWholeTranscriptLeafBeforeReducing() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 80).build(from: [
            source(0, "Checkout redesign needs clearer validation and error states."),
            source(1, "The team agreed to test the checkout redesign next week."),
            source(2, "Polish, Russian and English labels remain in scope."),
        ])
        let leafText = Dictionary(uniqueKeysWithValues: snapshot.leaves.map { leaf in
            (leaf.id, leaf.fragments.compactMap { snapshot.text(for: $0) }.joined())
        })
        let runtime = FakeQwenTitleRuntime { request in
            switch request.stage {
            case let .map(leafID):
                return Self.payload("Checkout Redesign", evidence: leafText[leafID] ?? "")
            case .reduce:
                return Self.payload("Checkout Redesign", evidence: leafText[0] ?? leafText.values.first ?? "")
            }
        }
        let generator = QwenMeetingTitleGenerator(
            runtime: runtime,
            maxReductionFanIn: 2,
            requestTimeout: .seconds(1)
        )

        let result = await generator.generate(from: snapshot)
        let requests = await runtime.capturedRequests()
        let shutdownCount = await runtime.capturedShutdownCount()

        XCTAssertEqual(result.title, "Checkout Redesign")
        XCTAssertEqual(
            requests.filter { if case .map = $0.stage { return true }; return false }.count,
            snapshot.leaves.count
        )
        XCTAssertTrue(result.coverageReceipt.isExact)
        XCTAssertEqual(shutdownCount, 1)
        for segment in snapshot.orderedSegments {
            XCTAssertTrue(requests.contains { $0.prompt.contains(segment.text) })
        }
    }

    func testUnavailableRuntimeReturnsSafeNilWithoutStartingInference() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, "Product launch roadmap")])
        let runtime = FakeQwenTitleRuntime(
            isAvailable: false,
            response: Self.payload("Product Launch", evidence: "Product launch roadmap")
        )

        let result = await QwenMeetingTitleGenerator(runtime: runtime).generate(from: snapshot)

        let requests = await runtime.capturedRequests()
        let shutdownCount = await runtime.capturedShutdownCount()
        XCTAssertNil(result.title)
        XCTAssertEqual(result.disposition, .deferred(.runtimeUnavailable))
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(shutdownCount, 0)
    }

    func testGenericModelTitleIsRejected() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, "A specific migration plan")])
        let runtime = FakeQwenTitleRuntime(
            response: Self.payload("Project Discussion", evidence: "A specific migration plan")
        )

        let result = await QwenMeetingTitleGenerator(runtime: runtime).generate(from: snapshot)

        let shutdownCount = await runtime.capturedShutdownCount()
        XCTAssertNil(result.title)
        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(shutdownCount, 1)
    }

    func testVagueUncertainAndDiscussionTitlesAreRejected() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [
            source(0, "A transcript fragment with enough words for title analysis."),
        ])
        for vagueTitle in [
            "The Idea",
            "Апдейт или письмо",
            "Onboarding Process Discussion",
            "Jedno najważniejsze",
            "Bloom's Ambition",
        ] {
            let runtime = FakeQwenTitleRuntime(
                response: Self.payload(
                    vagueTitle,
                    evidence: "A transcript fragment with enough words for title analysis."
                )
            )
            let result = await QwenMeetingTitleGenerator(runtime: runtime).generate(from: snapshot)
            XCTAssertNil(result.title, "Expected a safe date fallback for: \(vagueTitle)")
        }
    }

    func testFluentButUngroundedTitleIsRejected() async {
        let evidence = "The transcript discusses GPS trackers and Apple AirTags."
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, evidence)])
        let runtime = FakeQwenTitleRuntime(
            response: Self.payload("Paevolami Anbardam", evidence: evidence)
        )

        let result = await QwenMeetingTitleGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertNil(result.title)
    }

    func testGroundedAnchorAllowsConciseParaphrase() async {
        let evidence = "We are redesigning the website for launch."
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, evidence)])
        let runtime = FakeQwenTitleRuntime(
            response: Self.payload("Website Launch Strategy", evidence: evidence)
        )

        let result = await QwenMeetingTitleGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertEqual(result.title, "Website Launch Strategy")
    }

    func testTimeoutReturnsNilAndAlwaysShutsRuntimeDown() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, "Checkout redesign")])
        let runtime = FakeQwenTitleRuntime(
            responseDelay: .seconds(30),
            response: Self.payload("Checkout Redesign", evidence: "Checkout redesign")
        )
        let generator = QwenMeetingTitleGenerator(
            runtime: runtime,
            requestTimeout: .milliseconds(20)
        )

        let result = await generator.generate(from: snapshot)

        let shutdownCount = await runtime.capturedShutdownCount()
        XCTAssertNil(result.title)
        XCTAssertEqual(result.disposition, .deferred(.runtimeFailure))
        XCTAssertEqual(shutdownCount, 1)
    }

    func testCancellationReturnsNilAndAlwaysShutsRuntimeDown() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, "Checkout redesign")])
        let runtime = FakeQwenTitleRuntime(
            responseDelay: .seconds(30),
            response: Self.payload("Checkout Redesign", evidence: "Checkout redesign")
        )
        let generator = QwenMeetingTitleGenerator(runtime: runtime, requestTimeout: .seconds(60))

        let task = Task { await generator.generate(from: snapshot) }
        while await runtime.capturedRequests().isEmpty { await Task.yield() }
        task.cancel()
        let result = await task.value

        let shutdownCount = await runtime.capturedShutdownCount()
        XCTAssertNil(result.title)
        XCTAssertEqual(shutdownCount, 1)
    }

    private static func payload(_ title: String, evidence: String) -> String {
        let object: [String: Any] = [
            "title": title,
            "confidence": 0.91,
            "evidence": [evidence],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func source(_ index: Int, _ text: String) -> MeetingTitleSourceSegment {
        MeetingTitleSourceSegment(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
            startTime: Double(index),
            endTime: Double(index + 1),
            speakerLabel: index.isMultiple(of: 2) ? "Them" : "Me",
            text: text
        )
    }
}

private actor FakeQwenTitleRuntime: QwenTitleRunning {
    let isAvailable: Bool
    let responseDelay: Duration
    let response: @Sendable (QwenTitleRequest) -> String
    private(set) var requests: [QwenTitleRequest] = []
    private(set) var shutdownCount = 0
    private(set) var immediateShutdownCount = 0

    init(
        isAvailable: Bool = true,
        responseDelay: Duration = .zero,
        response: String
    ) {
        self.isAvailable = isAvailable
        self.responseDelay = responseDelay
        self.response = { _ in response }
    }

    init(response: @escaping @Sendable (QwenTitleRequest) -> String) {
        isAvailable = true
        responseDelay = .zero
        self.response = response
    }

    func available() async -> Bool { isAvailable }

    func complete(_ request: QwenTitleRequest) async throws -> String {
        requests.append(request)
        if responseDelay > .zero {
            try await Task.sleep(for: responseDelay)
        }
        return response(request)
    }

    func shutdown() async {
        shutdownCount += 1
    }

    func shutdownImmediately() async {
        immediateShutdownCount += 1
    }

    func capturedRequests() -> [QwenTitleRequest] { requests }
    func capturedShutdownCount() -> Int { shutdownCount }
    func capturedImmediateShutdownCount() -> Int { immediateShutdownCount }
}
