import XCTest
@testable import Parrot

final class CoreAudioCallbackCoalescerTests: XCTestCase {
    func testRepeatedCallbackStormKeepsOnlyOnePendingDeliveryPerKind() {
        let coalescer = CoreAudioCallbackCoalescer()

        XCTAssertTrue(coalescer.claim(.activitiesChanged))
        for _ in 0..<10_000 {
            XCTAssertFalse(coalescer.claim(.activitiesChanged))
        }

        XCTAssertEqual(coalescer.pendingCount, 1)
    }

    func testDeliveryCanBeScheduledAgainAfterPreviousOneFinishes() {
        let coalescer = CoreAudioCallbackCoalescer()

        XCTAssertTrue(coalescer.claim(.processListChanged))
        coalescer.beginDelivery(.processListChanged)
        XCTAssertFalse(coalescer.finish(.processListChanged))

        XCTAssertTrue(coalescer.claim(.processListChanged))
        XCTAssertEqual(coalescer.pendingCount, 1)
    }

    func testDifferentCallbackKindsCanEachHaveOnePendingDelivery() {
        let coalescer = CoreAudioCallbackCoalescer()

        XCTAssertTrue(coalescer.claim(.activitiesChanged))
        XCTAssertTrue(coalescer.claim(.processListChanged))
        XCTAssertTrue(coalescer.claim(.audioServiceRestarted))

        XCTAssertEqual(coalescer.pendingCount, 3)
    }

    func testNotificationDuringDeliveryRequestsOnlyOneFollowUpDelivery() {
        let coalescer = CoreAudioCallbackCoalescer()

        XCTAssertTrue(coalescer.claim(.activitiesChanged))
        XCTAssertFalse(coalescer.claim(.activitiesChanged))
        XCTAssertFalse(coalescer.claim(.activitiesChanged))
        coalescer.beginDelivery(.activitiesChanged)
        XCTAssertFalse(coalescer.claim(.activitiesChanged))

        XCTAssertTrue(coalescer.finish(.activitiesChanged))
        XCTAssertFalse(coalescer.finish(.activitiesChanged))
        XCTAssertEqual(coalescer.pendingCount, 0)
    }
}

final class CoreAudioProcessListenerDeltaTests: XCTestCase {
    func testUnchangedProcessListDoesNotRequestListenerChurn() {
        let delta = CoreAudioProcessListenerDelta(
            existing: [11, 22, 33],
            current: [33, 11, 22]
        )

        XCTAssertEqual(delta.added, [])
        XCTAssertEqual(delta.removed, [])
        XCTAssertFalse(delta.hasChanges)
    }

    func testDeltaAddsAndRemovesOnlyChangedProcesses() {
        let delta = CoreAudioProcessListenerDelta(
            existing: [11, 22, 33],
            current: [22, 33, 44, 55]
        )

        XCTAssertEqual(delta.added, [44, 55])
        XCTAssertEqual(delta.removed, [11])
        XCTAssertTrue(delta.hasChanges)
    }
}
