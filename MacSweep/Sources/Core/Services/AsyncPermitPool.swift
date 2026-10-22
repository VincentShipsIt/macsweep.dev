import Foundation

/// FIFO admission suspends queued tasks without parking a worker thread.
actor AsyncPermitPool {
    struct State: Sendable {
        let active: Int
        let queued: Int
        let limit: Int
    }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        precondition(active > 0)
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().continuation.resume() }
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(UUID())
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func state() -> State { State(active: active, queued: waiters.count, limit: limit) }
}
