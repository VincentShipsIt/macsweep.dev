import Foundation

/// Bridges cancellation into utility-queue hashing and the last synchronous mutation boundary.
final class StaleProjectCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }; isCancelled = true
    }

    func check() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }
}
