import Foundation

/// Async waiters do not occupy Swift worker threads while another disk walk owns the budget.
actor DevArtifactIOBudget {
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

    init(limit: Int = 2) {
        precondition(limit > 0)
        self.limit = limit
    }

    func acquire(_ id: UUID) async throws {
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

    func release() {
        precondition(active > 0)
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().continuation.resume() }
    }

    func state() -> State { State(active: active, queued: waiters.count, limit: limit) }
}

enum DevArtifactIO {
    static let sharedBudget = DevArtifactIOBudget()

    static func run<T: Sendable>(
        budget: DevArtifactIOBudget = sharedBudget,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await runAsync(budget: budget) { try operation() }
    }

    /// Async subprocess work shares the same leases as synchronous native walks.
    static func runAsync<T: Sendable>(
        budget: DevArtifactIOBudget = sharedBudget,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try await budget.acquire(UUID())
        do {
            try Task.checkCancellation()
            let collector = ScanDiagnostics.current
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try await ScanDiagnostics.$current.withValue(collector, operation: operation)
            }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            await budget.release()
            return result
        } catch {
            await budget.release()
            throw error
        }
    }
}
