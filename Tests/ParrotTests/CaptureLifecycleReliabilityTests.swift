import XCTest
@testable import Parrot

@MainActor
final class CaptureLifecycleReliabilityTests: XCTestCase {
    func testStopFromBackgroundExecutorReturnsWithIdleObservedState() async {
        let capture = AudioCaptureManager()
        await Task.detached { await capture.stopCapture() }.value

        XCTAssertFalse(capture.isCapturing)
        XCTAssertFalse(capture.micActive)
        XCTAssertEqual(capture.audioLevel, 0)
        XCTAssertEqual(capture.micLevel, 0)
        XCTAssertNil(capture.lastTimelineManifest)
        XCTAssertNil(capture.systemAudioURL)
    }

    func testConcurrentStopRequestsCanJoinWithoutCaptureHardware() async {
        let capture = AudioCaptureManager()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await capture.stopCapture() }
            }
        }
        XCTAssertFalse(capture.isCapturing)
        XCTAssertFalse(capture.micActive)
    }

    func testMenuQuitDefersTerminationUntilAfterButtonActionReturns() async {
        let terminated = expectation(description: "Deferred termination")
        var events: [String] = []
        MenuBarQuitRequest.perform(closePopover: { events.append("close") }) {
            events.append("terminate")
            terminated.fulfill()
        }
        events.append("button-returned")
        XCTAssertEqual(events, ["close", "button-returned"])
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertEqual(events, ["close", "button-returned", "terminate"])
    }
}
