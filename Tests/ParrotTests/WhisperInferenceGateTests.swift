import XCTest
@testable import Parrot

final class WhisperInferenceGateTests: XCTestCase {
    func testLiveInferenceGetsNextPermitBeforeBackgroundWork() async {
        let gate = WhisperInferenceGate()
        let events = EventRecorder()

        await gate.acquire(priority: .background)
        let background = Task {
            await gate.acquire(priority: .background)
            await events.append("background")
            await gate.release()
        }
        let live = Task {
            await gate.acquire(priority: .live)
            await events.append("live")
            await gate.release()
        }

        while true {
            let waiting = await gate.waitingCounts()
            if waiting.live == 1, waiting.background == 1 { break }
            await Task.yield()
        }
        await gate.release()
        await live.value
        await background.value

        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["live", "background"])
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}
