import XCTest
@testable import Parrot

final class AudioRouteChangePolicyTests: XCTestCase {
    func testInputDeviceChangeRestartsOnlyMicrophone() {
        let previous = AudioRouteSnapshot(inputDeviceID: 10, outputDeviceID: 20)
        let current = AudioRouteSnapshot(inputDeviceID: 11, outputDeviceID: 20)

        XCTAssertEqual(
            AudioRouteChangePolicy.actions(previous: previous, current: current),
            [.refreshDeviceNames, .restartMicrophone]
        )
    }

    func testOutputDeviceChangeKeepsSystemCaptureRunning() {
        let previous = AudioRouteSnapshot(inputDeviceID: 10, outputDeviceID: 20)
        let current = AudioRouteSnapshot(inputDeviceID: 10, outputDeviceID: 21)

        XCTAssertEqual(
            AudioRouteChangePolicy.actions(previous: previous, current: current),
            [.refreshDeviceNames]
        )
    }

    func testEngineConfigurationChangeRestartsMicrophoneEvenWhenIDsMatch() {
        let route = AudioRouteSnapshot(inputDeviceID: 10, outputDeviceID: 20)

        XCTAssertEqual(
            AudioRouteChangePolicy.actions(
                previous: route,
                current: route,
                engineConfigurationChanged: true
            ),
            [.restartMicrophone]
        )
    }

    func testDuplicateRouteNotificationDoesNothing() {
        let route = AudioRouteSnapshot(inputDeviceID: 10, outputDeviceID: 20)

        XCTAssertTrue(
            AudioRouteChangePolicy.actions(previous: route, current: route).isEmpty
        )
    }
}

final class MicrophoneCaptureGenerationGateTests: XCTestCase {
    func testRestartRejectsCallbacksFromPreviousMicrophone() {
        var gate = MicrophoneCaptureGenerationGate()
        let first = gate.begin()
        XCTAssertTrue(gate.accepts(first))

        let second = gate.begin()
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }
}

final class MicrophoneGapCompensationTests: XCTestCase {
    func testRouteSwitchGapBecomesSilenceInSavedMicTrack() {
        XCTAssertEqual(
            MicrophoneGapCompensation.missingFrames(
                previousBufferUptime: 100,
                currentBufferUptime: 103.02,
                currentBufferFrames: 320,
                sampleRate: 16_000
            ),
            48_000
        )
    }

    func testNormalAdjacentBuffersDoNotInventSilence() {
        XCTAssertEqual(
            MicrophoneGapCompensation.missingFrames(
                previousBufferUptime: 100,
                currentBufferUptime: 100.02,
                currentBufferFrames: 320,
                sampleRate: 16_000
            ),
            0
        )
    }
}
