import Foundation

/// Cancellation and a late callback compete for one continuation, so deleting
/// a meeting cannot leave the application's post-processing task orphaned.
final class FinalTranscriptResultAwaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<BestTranscriptArtifact, Error>, Never>?
    private var pending: Result<BestTranscriptArtifact, Error>?
    private var completed = false

    func install(_ value: CheckedContinuation<Result<BestTranscriptArtifact, Error>, Never>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            value.resume(returning: pending)
        } else {
            continuation = value
            lock.unlock()
        }
    }

    func complete(_ result: Result<BestTranscriptArtifact, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { pending = result }
        lock.unlock()
        waiting?.resume(returning: result)
    }
}
