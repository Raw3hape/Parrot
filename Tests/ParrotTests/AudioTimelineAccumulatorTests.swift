import XCTest
@testable import Parrot

final class AudioTimelineAccumulatorTests: XCTestCase {
    func testAccumulatorKeepsFirstOffsetAndCountsEveryPersistedFrame() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var accumulator = AudioTimelineAccumulator(capturedAt: date)

        accumulator.noteFirstBuffer(for: .them, offset: 0.12)
        accumulator.noteFirstBuffer(for: .them, offset: 0.30)
        accumulator.noteFirstBuffer(for: .me, offset: 0.45)
        accumulator.addFrames(1_000, for: .them)
        accumulator.addFrames(2_000, for: .them)
        accumulator.addFrames(1_500, for: .me)

        let manifest = accumulator.manifest(sampleRate: 16_000)

        XCTAssertEqual(manifest.capturedAt, date)
        XCTAssertEqual(manifest.track(for: .them)?.startOffset, 0.12)
        XCTAssertEqual(manifest.track(for: .them)?.frameCount, 3_000)
        XCTAssertEqual(manifest.track(for: .me)?.startOffset, 0.45)
        XCTAssertEqual(manifest.track(for: .me)?.frameCount, 1_500)
    }

    func testAccumulatorDoesNotInventTrackWithoutAudioFrames() {
        var accumulator = AudioTimelineAccumulator(capturedAt: .now)
        accumulator.noteFirstBuffer(for: .me, offset: -2)
        accumulator.addFrames(100, for: .me)

        let manifest = accumulator.manifest(sampleRate: 16_000)

        XCTAssertNil(manifest.track(for: .them))
        XCTAssertEqual(manifest.track(for: .me)?.startOffset, 0)
    }
}
