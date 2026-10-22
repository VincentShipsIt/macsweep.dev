import Foundation
import Testing

@testable import MacSweepCore

private final class IOTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var started = 0
    private var released = false

    func enter() {
        lock.lock()
        active += 1
        started += 1
        maximum = max(maximum, active)
        lock.unlock()
    }
    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }
    var counts: (started: Int, maximum: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (started, maximum)
    }
    var canFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }
}

struct DevArtifactIOTests {
    private enum FixtureError: Error { case failed, timeout }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !(await predicate()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureError.timeout }
            await Task.yield()
        }
    }

    @Test func globalStyleBudgetBoundsConcurrentWorkersAndReleasesAfterErrors() async throws {
        let budget = DevArtifactIOBudget(limit: 2)
        let probe = IOTestProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await DevArtifactIO.run(budget: budget) {
                        probe.enter()
                        defer { probe.leave() }
                        Thread.sleep(forTimeInterval: 0.003)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(probe.counts.started == 12 && probe.counts.maximum <= 2)
        do {
            try await DevArtifactIO.run(budget: budget) { throw FixtureError.failed }
            Issue.record("Injected IO failure was swallowed")
        } catch FixtureError.failed {}
        #expect(try await DevArtifactIO.run(budget: budget) { 7 } == 7)
        let state = await budget.state()
        #expect(state.active == 0 && state.queued == 0)
    }

    @Test func mixedAsyncAndSynchronousWorkersShareOneBudget() async throws {
        let budget = DevArtifactIOBudget(limit: 2)
        let probe = IOTestProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        try await DevArtifactIO.run(budget: budget) {
                            probe.enter()
                            defer { probe.leave() }
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                    } else {
                        try await DevArtifactIO.runAsync(budget: budget) {
                            probe.enter()
                            defer { probe.leave() }
                            try await Task.sleep(for: .milliseconds(5))
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(probe.counts.started == 16 && probe.counts.maximum <= 2)
        #expect(await budget.state().active == 0)
    }

    @Test func queuedAsyncCancellationNeverDispatchesAndActiveAsyncCancellationReleases() async throws {
        let budget = DevArtifactIOBudget(limit: 1)
        let probe = IOTestProbe()
        let first = Task {
            try await DevArtifactIO.runAsync(budget: budget) {
                probe.enter()
                defer { probe.leave() }
                try await Task.sleep(for: .seconds(3))
            }
        }
        try await waitUntil { probe.counts.started == 1 }
        let queued = Task {
            try await DevArtifactIO.runAsync(budget: budget) {
                probe.enter()
                probe.leave()
            }
        }
        try await waitUntil { await budget.state().queued == 1 }
        queued.cancel()
        do {
            try await queued.value
            Issue.record("Cancelled async waiter dispatched")
        } catch is CancellationError {}
        #expect(probe.counts.started == 1)
        #expect(await budget.state().queued == 0)
        first.cancel()
        do {
            try await first.value
            Issue.record("Cancelled async work returned success")
        } catch is CancellationError {}
        #expect(await budget.state().active == 0)
        let collector = ScanDiagnostics.Collector()
        do {
            try await ScanDiagnostics.$current.withValue(collector) {
                try await DevArtifactIO.runAsync(budget: budget) {
                    ScanDiagnostics.current?.record(
                        CocoaError(.fileReadNoPermission), at: URL(fileURLWithPath: "/fixture"))
                    throw FixtureError.failed
                }
            }
            Issue.record("Async failure was swallowed")
        } catch FixtureError.failed {}
        #expect(collector.issues.count == 1)
        #expect(await budget.state().active == 0)
    }

    @Test func activeCancellationReachesTheSynchronousWorker() async throws {
        let budget = DevArtifactIOBudget(limit: 1)
        let probe = IOTestProbe()
        let task = Task {
            try await DevArtifactIO.run(budget: budget) {
                probe.enter()
                defer { probe.leave() }
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.001)
                }
                throw FixtureError.timeout
            }
        }
        try await waitUntil { probe.counts.started == 1 }
        let cancelled = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled worker returned success")
        } catch is CancellationError {}
        #expect(ProcessInfo.processInfo.systemUptime - cancelled < 1)
        #expect(await budget.state().active == 0)
    }

    @Test func cancelledQueuedWorkIsRemovedWithoutDispatch() async throws {
        let budget = DevArtifactIOBudget(limit: 1)
        let probe = IOTestProbe()
        let first = Task {
            try await DevArtifactIO.run(budget: budget) {
                probe.enter()
                defer { probe.leave() }
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while !probe.canFinish {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureError.timeout }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }
        try await waitUntil { probe.counts.started == 1 }
        let queued = Task {
            try await DevArtifactIO.run(budget: budget) {
                probe.enter()
                probe.leave()
            }
        }
        try await waitUntil { await budget.state().queued == 1 }
        queued.cancel()
        do {
            try await queued.value
            Issue.record("Cancelled queued work was dispatched")
        } catch is CancellationError {}
        #expect(probe.counts.started == 1)
        #expect(await budget.state().queued == 0)
        probe.release()
        try await first.value
        #expect(await budget.state().active == 0)
    }

    @Test func nestedSubmissionCanReenterAfterLeaseReleaseAndDiagnosticsStayTaskLocal() async throws {
        let budget = DevArtifactIOBudget(limit: 1)
        let collector = ScanDiagnostics.Collector()
        let value = try await ScanDiagnostics.$current.withValue(collector) {
            let nested = try await DevArtifactIO.run(budget: budget) {
                ScanDiagnostics.current?.record(CocoaError(.fileReadNoPermission), at: URL(fileURLWithPath: "/fixture"))
                return Task { try await DevArtifactIO.run(budget: budget) { 42 } }
            }
            return try await nested.value
        }
        #expect(value == 42 && collector.issues.count == 1)
        let state = await budget.state()
        #expect(state.active == 0 && state.queued == 0)
    }
}
