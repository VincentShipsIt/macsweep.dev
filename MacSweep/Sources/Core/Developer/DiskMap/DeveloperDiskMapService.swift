import Darwin
import Foundation

struct DeveloperDiskMapService: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var knownRoots: [DiskMapRoot]?
    var projectRoots: [URL]?
    var limits = DiskMapLimits()
    var cache = DiskMapCache.shared
    var checker: @Sendable () -> SafetyChecker = { SafetyChecker() }
    var freeBytes: @Sendable () -> Int64? = {
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [
            .volumeAvailableCapacityKey
        ])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
    var beforeRead: @Sendable (URL) throws -> Void = { _ in }

    func scan(
        fullHome: Bool = false, refresh: Bool = false,
        progress: @escaping @Sendable (DiskMapReport) async -> Void = { _ in }
    ) async -> DiskMapReport {
        if Task.isCancelled {
            return DiskMapReport(issues: ["Scan cancelled before measurements began."], fullHome: fullHome)
        }
        let safety = checker()
        let scopeKey =
            String(reflecting: safety.userRules) + "|" + home.path + "|" + String(describing: projectRoots)
            + "|" + String(describing: knownRoots) + "|" + String(reflecting: limits) + "|" + String(fullHome)
        let previous = await previousEntry(scopeKey, fullHome: fullHome, refresh: refresh)
        let ttl = cache.ttl
        let records = previous?.records.filter { Date().timeIntervalSince($0.value.measuredAt) < ttl } ?? [:]
        if let previous, !Task.isCancelled, records.count == previous.records.count,
            previous.report.fullHome == fullHome,
            previous.report.finished, previous.report.issues.isEmpty,
            previous.report.roots.allSatisfy({ $0.coverage == .complete }) {
            var report = protectedReport(previous.report, checker: safety)
            report.cached = true
            await progress(report)
            return report
        }
        var session = Session(
            report: DiskMapReport(fullHome: fullHome, cached: previous != nil), records: records,
            safety: safety,
            progress: progress)
        session.hardLinks = session.records.values.reduce(into: Set<String>()) { $0.formUnion($1.hardLinks) }
        do {
            try await populate(&session)
            session.report.finished = true
        } catch is CancellationError {
            session.report.issues.append(
                "Scan cancelled. Completed roots remain visible; Scan / Resume continues recent measurements.")
        } catch {
            session.report.issues.append(
                (error as? ScanLimit) == .roots
                    ? "The root-count budget was reached; narrow project roots to inspect more. Results are partial."
                    : "The overall scan budget was reached. Recent root chunks remain visible; "
                        + "Scan / Resume continues them."
            )
        }
        session.report.issues = Array(Set(session.report.issues)).sorted()
        _ = await cache.put(
            DiskMapCache.Entry(key: scopeKey, report: session.report, records: session.records),
            freeBytes: freeBytes())
        await progress(session.report)
        return session.report
    }

    private func previousEntry(_ key: String, fullHome: Bool, refresh: Bool) async -> DiskMapCache.Entry? {
        if refresh { return nil }
        if let current = await cache.get(key) { return current }
        if fullHome { return await cache.get(String(key.dropLast(4)) + "false") }
        return nil
    }

    private enum ScanLimit: Error { case time, roots }

    private struct Session {
        var report: DiskMapReport
        var records: [String: DiskMapCache.Record]
        var safety: SafetyChecker
        var progress: @Sendable (DiskMapReport) async -> Void
        var hardLinks = Set<String>()
        let started = ProcessInfo.processInfo.systemUptime
    }

    private func populate(_ session: inout Session) async throws {
        try Task.checkCancellation()
        let known = try await DevArtifactIO.run { knownRoots ?? DiskMapRoots.known(home: home) }
        let roots = DiskMapRoots.disjoint(Array(known.prefix(max(0, limits.maximumRoots))))
        try await measure(roots, excluding: [], session: &session)
        if known.count > limits.maximumRoots { throw ScanLimit.roots }
        let safety = session.safety
        let fullHome = session.report.fullHome
        let discovery = try await DevArtifactIO.run {
            try DeveloperRepositoryDiscovery.discover(
                searchPaths: fullHome
                    ? [home] + (projectRoots ?? []) : projectRoots ?? DiskMapRoots.projects(home: home),
                homeDirectory: home, maxDepth: 6, maximumEntries: 50_000, timeLimit: 5, checker: safety)
        }
        session.report.issues += discovery.issues
        let repositories = DiskMapRoots.disjoint(
            discovery.roots.prefix(max(0, limits.maximumRoots)).map {
                DiskMapRoot(url: $0, kind: .repository, owner: .developerTools)
            }
        ).filter { repository in !roots.contains { DiskMapRoots.contains($0.url, repository.url) } }
        try await measure(repositories, excluding: roots.map(\.url), session: &session)
        if discovery.roots.count > limits.maximumRoots { throw ScanLimit.roots }
        if fullHome {
            try await measure(
                [DiskMapRoot(url: home, kind: .ordinary)],
                excluding: roots.map(\.url) + repositories.map(\.url), session: &session)
        }
    }

    private func measure(_ roots: [DiskMapRoot], excluding: [URL], session: inout Session) async throws {
        for root in roots {
            try Task.checkCancellation()
            guard session.report.roots.count < max(0, limits.maximumRoots) else { throw ScanLimit.roots }
            guard ProcessInfo.processInfo.systemUptime - session.started < limits.maximumScanSeconds else {
                throw ScanLimit.time
            }
            if let cached = session.records[root.url.path],
                protectionAllowsReuse(cached.node, checker: session.safety) {
                session.report.roots.append(cached.node)
                if cached.node.coverage != .complete {
                    session.report.issues.append(
                        "Recent root measurements include lower bounds or unknown sizes. Refresh to remeasure them.")
                }
            } else {
                let existing = session.hardLinks
                let checker = session.safety
                let measured = try await DevArtifactIO.run {
                    try measureRoot(root, excluding: excluding, checker: checker, existing: existing)
                }
                if let measured {
                    session.report.roots.append(measured.node)
                    session.report.issues += measured.issues
                    session.hardLinks.formUnion(measured.hardLinks)
                    session.records[root.url.path] = DiskMapCache.Record(
                        node: measured.node, hardLinks: measured.hardLinks)
                }
            }
            await session.progress(session.report)
        }
    }

    private func measureRoot(
        _ root: DiskMapRoot, excluding: [URL], checker: SafetyChecker,
        existing: Set<String>
    ) throws -> DiskMapMeasurement.Result? {
        var metadata = stat()
        guard lstat(root.url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            return DiskMapMeasurement.Result(
                node: DiskMapNode(
                    id: root.url.path, url: root.url, name: root.url.lastPathComponent,
                    kind: root.kind, coverage: .unknown),
                issues: ["A developer root could not be read; its size is unknown."], hardLinks: [])
        }
        guard DiskMapCache.noSymlinkAncestors(root.url) else {
            return DiskMapMeasurement.Result(
                node: DiskMapNode(
                    id: root.url.path, url: root.url, name: root.url.lastPathComponent,
                    kind: root.kind, coverage: .unknown, protectedReason: "Symbolic link in path; not followed."),
                issues: ["A symbolic-link root was not traversed."], hardLinks: [])
        }
        return try DiskMapMeasurement(limits: limits, checker: checker, beforeRead: beforeRead)
            .measure(root, excluding: excluding, hardLinks: existing)
    }

    private func protectionAllowsReuse(_ node: DiskMapNode, checker: SafetyChecker) -> Bool {
        guard let path = node.url else {
            return node.children.allSatisfy { protectionAllowsReuse($0, checker: checker) }
        }
        guard case .none = checker.userRules.decision(for: path.path) else {
            return node.coverage == .unknown && node.protectedReason != nil && node.children.isEmpty
        }
        return node.children.allSatisfy { protectionAllowsReuse($0, checker: checker) }
    }

    private func protectedReport(_ report: DiskMapReport, checker: SafetyChecker) -> DiskMapReport {
        func protect(_ original: DiskMapNode) -> DiskMapNode {
            var node = original
            if !protectionAllowsReuse(node, checker: checker) {
                node.protectedReason = "User rules changed; cached contents are withheld. Refresh to remeasure."
                node.children = []
                node.coverage = .unknown
                node.logicalBytes = 0
                node.allocatedBytes = 0
            }
            return node
        }
        var result = report
        result.roots = report.roots.map(protect)
        return result
    }
}
