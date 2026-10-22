import Foundation

enum DevArtifactIO {
    static let sharedBudget = AsyncPermitPool(limit: 2)

    static func run<T: Sendable>(
        budget: AsyncPermitPool = sharedBudget,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await runAsync(budget: budget) { try operation() }
    }

    /// Async subprocess work shares the same leases as synchronous native walks.
    static func runAsync<T: Sendable>(
        budget: AsyncPermitPool = sharedBudget,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await perform(budget: budget, requireUncancelledResult: true, operation)
    }

    /// Preserve a completed mutation's receipt if cancellation arrives after its
    /// final pre-commit check. Callers still validate immediately before mutation.
    static func commit<T: Sendable>(
        budget: AsyncPermitPool = sharedBudget,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await perform(budget: budget, requireUncancelledResult: false) { try operation() }
    }

    private static func perform<T: Sendable>(
        budget: AsyncPermitPool, requireUncancelledResult: Bool,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await budget.withPermit {
            try Task.checkCancellation()
            let collector = ScanDiagnostics.current
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try await ScanDiagnostics.$current.withValue(collector) { try await operation() }
            }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            if requireUncancelledResult { try Task.checkCancellation() }
            return result
        }
    }
}
