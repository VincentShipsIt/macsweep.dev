import Darwin
import Foundation

struct StaleProjectsService: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var searchPaths = [FileManager.default.homeDirectoryForCurrentUser]
    var policy = StaleProjectPolicy()
    var artifactModule = DevToolsModule()
    var activity: @Sendable () async throws -> DevProcessSnapshot = { try await DevProcessActivity.snapshot() }
    var checker: @Sendable () -> SafetyChecker = { SafetyChecker() }
    var archive = StaleProjectArchive()
    var history = StaleProjectHistory.shared
    var moveToTrash: @Sendable (URL) throws -> Void = {
        try CleanupFileRemover.recoverable($0, module: "stale-projects")
    }

    func inventory() async throws -> StaleProjectInventory {
        let discovery = try await DevArtifactIO.run {
            try DeveloperRepositoryDiscovery.discover(
                searchPaths: searchPaths, homeDirectory: home, maximumEntries: policy.maximumDiscoveryEntries,
                checker: checker(),
            )
        }
        var inventory = StaleProjectInventory(roots: searchPaths, issues: discovery.issues)
        let module = configuredModule()
        let scan = await ScanEngine(modules: [module]).scanWithDiagnostics()
        inventory.issues += scan.failures.map(\.message)
        let deadline = ProcessInfo.processInfo.systemUptime + policy.inventoryTimeLimit
        for root in discovery.roots {
            try Task.checkCancellation()
            guard inventory.projects.count < policy.maximumRepositories,
                  ProcessInfo.processInfo.systemUptime < deadline
            else {
                inventory.issues
                    .append("Project inventory stopped at its repository or time limit; results are partial.")
                break
            }
            let artifacts = scan.items.filter { DevArtifactPaths.contains(
                root.resolvingSymlinksInPath(),
                $0.path.resolvingSymlinksInPath(),
            ) }
            try await inventory.projects.append(inspect(root, artifacts: artifacts))
        }
        return inventory
    }

    private func inspect(_ root: URL, artifacts: [CleanupItem]) async throws -> StaleProject {
        var issues: [String] = []
        let identity = try? await DevArtifactIO.run { try ManagedCleanupEvidence.identity(root) }
        let measurement: DevArtifactContent.Measurement?
        do { measurement = try await DevArtifactIO.run { try DevArtifactContent.measure(root) } } catch {
            measurement = nil
            issues.append("Full checkout sizing is incomplete; source and total estimates are unavailable.")
        }
        let git = await StaleProjectGit.inspect(root)
        if let issue = git.issue {
            issues.append(issue)
        }
        let artifactBytes = artifacts.filter { $0.devArtifactReceipt?.isEligible == true }.estimatedBytes
        let activity = [git.lastCommit, git.lastCheckout, measurement?.modified].compactMap(\.self).max()
        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .month, value: -max(1, min(36, policy.staleMonths)), to: Date(),
        ) ?? Date()
        let age: StaleProjectAge
        if let activity, measurement != nil, git.issue == nil, git.lastCommit != nil {
            age = activity < cutoff ? .stale : .recent
        } else {
            age = .unknown
        }
        let protection = checker().userRules.decision(for: root.path)
        let archiveBlocker: String? = protection != .none
            ? "User protection excludes whole-project actions." : identity == nil ? "Checkout identity unavailable." :
            nil
        return StaleProject(
            path: root, identity: identity, totalBytes: measurement?.size,
            sourceBytes: measurement.map { max(0, $0.size - artifactBytes) }, artifactBytes: artifactBytes,
            lastFileModification: measurement?.modified, git: git, age: age,
            artifacts: artifacts, archiveBlocker: archiveBlocker, issues: issues,
        )
    }

    func sweep(_ items: [CleanupItem], deletionGuard: DeletionGuard = .fromPreferences()) async -> CleanupResult {
        guard !items.isEmpty else { return CleanupResult(itemsProcessed: 0, bytesFreed: 0) }
        let selected = items.withoutOverlappingTargets()
        do {
            guard selected.allSatisfy({ $0.module == "dev-tools" && $0.devArtifactReceipt?.isEligible == true }) else {
                throw DevArtifactSafetyError("Only verified generated artifacts can be swept.")
            }
            // A single engine checks the entire selection before any target dispatch.
            let result = try await ScanEngine(modules: [configuredModule()], deletionGuard: deletionGuard)
                .clean(items: selected, dryRun: false, confirmedLargeDeletion: true)
            recordSweep(selected, result: result)
            return CleanupResult(itemsProcessed: result.itemsProcessed, bytesFreed: 0, errors: result.errors,
                                 historyActions: result.historyActions, accounting: result.accounting)
        } catch {
            let result = failure(items: selected, error: error)
            recordSweep(selected, result: result)
            return result
        }
    }

    func createArchive(_ project: StaleProject, destination: URL) async throws -> StaleArchiveReceipt {
        var archiver = archive
        archiver.policy = policy
        archiver.checker = checker
        do {
            let receipt = try await archiver.create(project, destination: destination)
            history.record(.archive, project: project.path, targets: [project.path], archive: destination,
                           archiveBytes: receipt.archiveBytes, completedCount: 1)
            return receipt
        } catch {
            history.record(.archive, project: project.path, targets: [project.path], archive: destination,
                           completedCount: 0, errors: [error.localizedDescription])
            throw error
        }
    }

    func trashCheckout(
        _ receipt: StaleArchiveReceipt, deletionGuard: DeletionGuard = .fromPreferences(),
    ) async -> CleanupResult {
        let cancellation = StaleProjectCancellation()
        return await withTaskCancellationHandler {
            await trashCheckout(receipt, deletionGuard: deletionGuard, cancellation: cancellation)
        } onCancel: { cancellation.cancel() }
    }

    private func trashCheckout(
        _ receipt: StaleArchiveReceipt, deletionGuard: DeletionGuard, cancellation: StaleProjectCancellation,
    ) async -> CleanupResult {
        let item = checkoutItem(receipt)
        do {
            try cancellation.check()
            guard receipt.trashBlocker == nil else {
                throw DevArtifactSafetyError(receipt.trashBlocker ?? "Checkout retained.")
            }
            try preflight(item, guard: deletionGuard)
            var archiver = archive
            archiver.policy = policy
            archiver.checker = checker
            try await archiver.validate(receipt, cancellation: cancellation)
            let git = await StaleProjectGit.inspect(receipt.project.path)
            if let blocker = git.trashBlocker {
                throw DevArtifactSafetyError(blocker)
            }
            try preflight(item, guard: deletionGuard)
            let snapshot = try await activity()
            if let reason = ManagedCleanupEvidence.activityReason(
                snapshot, blockers: snapshot.blockers(target: item.path, project: item.path),
            ) {
                throw DevArtifactSafetyError(reason)
            }
            try await DevArtifactIO.commit {
                try validateFinal(receipt, cancellation: cancellation)
                try cancellation.check()
                try moveToTrash(item.path)
            }
            let result = CleanupResult(itemsProcessed: 1, bytesFreed: 0, historyActions: [item.id: .moveToTrash])
                .accounting(for: [item])
            CleanupHistoryStore.shared.record(items: [item], result: result)
            recordTrash(receipt, result: result)
            return result
        } catch {
            let result = failure(items: [item], error: error)
            recordTrash(receipt, result: result)
            return result
        }
    }

    private func configuredModule() -> DevToolsModule {
        var module = artifactModule
        module.searchPaths = searchPaths
        module.homeDirectory = home
        module.includesSystemCaches = false
        module.minimumDirectorySize = 0
        module.maximumInspectionTargets = min(4096, max(1, policy.maximumRepositories) * 8)
        module.inspectionTimeLimit = max(1, min(30, policy.inventoryTimeLimit / 3))
        module.safety.processSnapshot = activity
        return module
    }

    private func recordSweep(_ items: [CleanupItem], result: CleanupResult) {
        let roots = Set(items.compactMap { $0.devArtifactReceipt?.project })
        for root in roots {
            let group = items.filter { $0.devArtifactReceipt?.project == root }
            let failures = result.errors.filter { error in group.contains { $0.path == error.path } }
            history.record(.artifactSweep, project: root, targets: group.map(\.path),
                           estimatedTargetBytes: group.estimatedBytes,
                           completedCount: max(0, group.count - failures.count), errors: failures.map(\.message))
        }
    }

    private func recordTrash(_ receipt: StaleArchiveReceipt, result: CleanupResult) {
        history.record(.checkoutTrash, project: receipt.project.path, targets: [receipt.project.path],
                       archive: receipt.destination, archiveBytes: receipt.archiveBytes,
                       estimatedTargetBytes: receipt.manifest.allocatedBytes,
                       completedCount: result.itemsProcessed, errors: result.errors.map(\.message))
    }

    private func checkoutItem(_ receipt: StaleArchiveReceipt) -> CleanupItem {
        CleanupItem(id: UUID(), path: receipt.project.path, size: receipt.manifest.allocatedBytes,
                    type: .directory, module: "stale-projects", moduleName: "Archived checkout")
    }

    private func preflight(_ item: CleanupItem, guard deletionGuard: DeletionGuard) throws {
        if case let .blocked(reason) = deletionGuard.preflightCheck(items: [item]) {
            throw DevArtifactSafetyError(reason)
        }
    }

    private func validateFinal(
        _ receipt: StaleArchiveReceipt, cancellation: StaleProjectCancellation,
    ) throws {
        let root = receipt.project.path
        let freshChecker = checker()
        guard freshChecker.validateForTrash(root).isSafe,
              try ManagedCleanupEvidence.identity(root) == receipt.manifest.identity
        else {
            throw DevArtifactSafetyError("Checkout identity or protection changed; retained.")
        }
        var archiveStatus = stat()
        guard try ManagedCleanupEvidence.identity(receipt.destination) == receipt.archiveIdentity,
            lstat(receipt.destination.path, &archiveStatus) == 0,
            DevArtifactNode(path: receipt.destination.path, status: archiveStatus) == receipt.archiveStamp else {
            throw DevArtifactSafetyError("Verified archive changed immediately before Trash; retained.")
        }
        // Full contents were hashed before the fresh process snapshot. Recheck all vnodes after it.
        try receipt.manifest.validateCurrentMetadata(root, checker: freshChecker, cancellation: cancellation)
    }

    private func failure(items: [CleanupItem], error: Error) -> CleanupResult {
        CleanupResult(itemsProcessed: 0, bytesFreed: 0,
                      errors: items.map { CleanupError(path: $0.path, message: error.localizedDescription) })
    }
}
