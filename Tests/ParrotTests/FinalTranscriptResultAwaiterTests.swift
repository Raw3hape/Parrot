import XCTest
@testable import Parrot

final class FinalTranscriptResultAwaiterTests: XCTestCase {
    func testCancellationBeforeCallbackInstallationReturnsWithoutWaiting() async {
        let waiter = FinalTranscriptResultAwaiter()
        waiter.complete(.failure(CancellationError()))
        let result = await withCheckedContinuation { waiter.install($0) }
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("Cancelled result must reach the waiting owner") }
    }

    func testCancellationAndLateCompletionResumeOnlyOnce() async {
        let waiter = FinalTranscriptResultAwaiter()
        let result = await withCheckedContinuation { continuation in
            waiter.install(continuation)
            waiter.complete(.failure(CancellationError()))
            waiter.complete(.failure(BestTranscriptionError.noAudio))
        }
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("The first terminal event owns the result") }
    }

    func testNormalFailureIsPreservedInsteadOfBecomingCancellation() async {
        let waiter = FinalTranscriptResultAwaiter()
        let result = await withCheckedContinuation { continuation in
            waiter.install(continuation)
            waiter.complete(.failure(BestTranscriptionError.noAudio))
        }
        if case .failure(let error) = result {
            XCTAssertEqual(error as? BestTranscriptionError, .noAudio)
        } else { XCTFail("Expected the actual failure") }
    }
}
