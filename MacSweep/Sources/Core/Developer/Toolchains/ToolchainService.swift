import Darwin
import Foundation

struct ToolchainService: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var environment = ProcessInfo.processInfo.environment
    var locationsOverride: [ToolchainLocation]?
    var referenceRootsOverride: [URL]?
    var now: @Sendable () -> Date = { Date() }
    var activity: @Sendable () async throws -> DevProcessSnapshot = { try await DevProcessActivity.snapshot() }
    var commandRunner: ToolchainCommandRunner = { command, timeout in
        try await ProcessRunner.run(
            executable: command.executable, arguments: command.arguments,
            currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
    }

    func inventory(policy: ToolchainPolicy = .init()) async throws -> ToolchainInventory {
        let locations = locationsOverride ?? ToolchainDiscovery.locations(home: home, environment: environment)
        let discovery = try await discover(locations)
        let detected = discovery.detected
        let discoveryIssues = discovery.issues
        guard !detected.isEmpty else { return ToolchainInventory(issues: discoveryIssues) }
        let roots = referenceRootsOverride ?? DeveloperScanRoots.paths(in: home, homeDirectory: home)
        let references = try await DevArtifactIO.run {
            try ToolchainReferenceScanner.scan(
                roots: roots, excluded: locations.map(\.root),
                dependencyRoots: detected.flatMap { $0.1.map(\.path) }, policy: policy)
        }
        let snapshot: DevProcessSnapshot
        do { snapshot = try await activity() } catch is CancellationError { throw CancellationError() } catch {
            snapshot = DevProcessSnapshot(issues: ["Process inspection unavailable."])
        }
        var inventory = ToolchainInventory(issues: references.issues + discoveryIssues, referenceRoots: roots)
        var seen = Set<String>()
        for (location, candidates) in detected {
            try Task.checkCancellation()
            do {
                let globals = ToolchainGlobalSelections.collect(
                    location: location, home: home, environment: environment)
                let capability = await supportsRemoval(location)
                for candidate in candidates where seen.insert(candidate.path.path).inserted {
                    let context = ToolchainAssessment.Context(
                        policy: policy, references: references, globals: globals,
                        snapshot: snapshot, capability: capability, now: now())
                    let item = try await ToolchainAssessment.assess(candidate, location: location, context: context)
                    inventory.installations.append(item)
                }
            } catch is CancellationError { throw CancellationError() } catch {
                inventory.issues.append(
                    "\(location.manager.title) inventory unavailable: \(error.localizedDescription)")
            }
        }
        return inventory
    }

    private func discover(_ locations: [ToolchainLocation]) async throws -> Discovery {
        var detected: [(ToolchainLocation, [ToolchainCandidate])] = []
        var discoveryIssues: [String] = []
        for location in locations {
            do {
                let candidates = try await DevArtifactIO.run { try ToolchainDiscovery.candidates(location) }
                if !candidates.isEmpty { detected.append((location, candidates)) }
            } catch is CancellationError { throw CancellationError() } catch {
                discoveryIssues.append("\(location.manager.title) inventory unavailable.")
            }
        }
        return Discovery(detected: detected, issues: discoveryIssues)
    }

    private struct Discovery {
        let detected: [(ToolchainLocation, [ToolchainCandidate])]
        let issues: [String]
    }

    func remove(
        _ selected: [ToolchainInstallation], policy: ToolchainPolicy = .init(),
        guard deletionGuard: DeletionGuard = .fromPreferences()
    ) async -> CleanupResult {
        let declared = selectedImpact(selected)
        if case .blocked(let reason) = deletionGuard.classify(measuredTotalSize: declared) {
            return CleanupResult(
                itemsProcessed: 0, bytesFreed: 0,
                errors: selected.map { .init(path: $0.path, message: reason) })
        }
        var processed = 0
        var errors: [CleanupError] = []
        var authorizedBytes: Int64 = 0
        var seen = Set<String>()
        for old in selected where seen.insert(old.id).inserted {
            do {
                try Task.checkCancellation()
                guard old.isSelectable else {
                    throw DevArtifactSafetyError("Only verified stale versions can be removed.")
                }
                let current = try await inventory(policy: policy)
                guard let fresh = current.installations.first(where: { $0.id == old.id }), fresh.isSelectable,
                    fresh.identity == old.identity, fresh.executableIdentity == old.executableIdentity,
                    fresh.executableStamp == old.executableStamp,
                    fresh.content == old.content, fresh.command == old.command,
                    let command = fresh.command, let size = fresh.size
                else {
                    throw DevArtifactSafetyError(
                        "Identity, content, selection, references or activity changed. Rescan first.")
                }
                let (cumulative, overflow) = authorizedBytes.addingReportingOverflow(size)
                guard !overflow else { throw DevArtifactSafetyError("Runtime impact overflow.") }
                if case .blocked(let reason) = deletionGuard.classify(measuredTotalSize: cumulative) {
                    throw DevArtifactSafetyError(reason)
                }
                try await validateAtDispatch(fresh)
                // Confirmation is supplied by the dedicated review sheet. Native uninstall is permanent.
                authorizedBytes = cumulative
                let result = try await commandRunner(command, 120)
                guard result.didSucceed else {
                    throw DevArtifactSafetyError(
                        "Native uninstall failed (exit \(result.status)); rescan to inspect partial effects.")
                }
                guard !FileManager.default.fileExists(atPath: old.path.path) else {
                    throw DevArtifactSafetyError("The manager retained the runtime. No removal is credited.")
                }
                processed += 1
            } catch {
                errors.append(.init(path: old.path, message: error.localizedDescription))
                if error is CancellationError { break }
            }
        }
        // Native managers may share files or remove other metadata. Scanned bytes are not claimed as savings.
        return CleanupResult(itemsProcessed: processed, bytesFreed: 0, errors: errors)
    }

    private func selectedImpact(_ selected: [ToolchainInstallation]) -> Int64 {
        selected.reduce(Int64(0)) { total, version in
            let addition = total.addingReportingOverflow(version.size ?? Int64.max)
            return addition.overflow ? Int64.max : addition.partialValue
        }
    }

    private func validateAtDispatch(_ fresh: ToolchainInstallation) async throws {
        let latestActivity = try await activity()
        let blockers = ManagedCleanupEvidence.blockers(
            latestActivity, path: fresh.path,
            manager: fresh.manager.rawValue)
        if let reason = ManagedCleanupEvidence.activityReason(latestActivity, blockers: blockers) {
            throw DevArtifactSafetyError(reason)
        }
        try await DevArtifactIO.run {
            let content = fresh.content.map { ToolchainWitness(path: $0.path, node: $0) }
            try ToolchainEvidence.validate(fresh.witnesses + content)
        }
    }

    private func supportsRemoval(_ location: ToolchainLocation) async -> Bool {
        guard let executable = location.executable, FileManager.default.fileExists(atPath: executable.path),
            location.manager != .java
        else { return false }
        let command: ToolchainCommand
        switch location.manager {
        case .pyenv, .rbenv:
            command = .init(executable: executable.path, arguments: ["help", "uninstall"])
        case .asdf:
            command = .init(executable: executable.path, arguments: ["help"])
        case .rustup:
            command = .init(executable: executable.path, arguments: ["toolchain", "uninstall", "--help"])
        case .nvm:
            // Only the explicit nvm installation script is sourced. Startup hooks are removed.
            command = .init(
                executable: "/usr/bin/env",
                arguments: [
                    "-i", "HOME=" + home.path,
                    "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "NVM_DIR=" + location.root.path,
                    "/bin/bash", "--noprofile", "--norc", "-c",
                    #". "$1/nvm.sh" --no-use || exit 1; nvm --help"#, "macsweep-nvm-help", location.root.path
                ])
        case .mise: command = .init(executable: executable.path, arguments: ["--help"])
        case .java: return false
        }
        do {
            let result = try await commandRunner(command, 5)
            let supported =
                result.didSucceed && result.outputWasValidUTF8 && result.output.utf8.count <= 65_536
                && result.output.contains("uninstall")
            if location.manager == .mise {
                return supported && ["--no-config", "--no-env", "--no-hooks"].allSatisfy(result.output.contains)
            }
            return supported
        } catch { return false }
    }
}
