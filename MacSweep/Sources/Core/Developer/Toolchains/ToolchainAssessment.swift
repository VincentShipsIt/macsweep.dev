import Darwin
import Foundation

enum ToolchainAssessment {
    struct Context: Sendable {
        let policy: ToolchainPolicy
        let references: ToolchainReferences
        let globals: ToolchainReferences
        let snapshot: DevProcessSnapshot
        let capability: Bool
        let now: Date
        let installedVersions: Set<String>
    }

    private struct Inspection {
        var identity: DevArtifactIdentity?
        var executableIdentity: DevArtifactIdentity?
        var executableStamp: DevArtifactNode?
        var content: [DevArtifactNode] = []
        var size: Int64?
        var signal: Date?
        var reasons: [String] = []
    }

    static func assess(
        _ candidate: ToolchainCandidate, location: ToolchainLocation,
        context: Context
    ) async throws -> ToolchainInstallation {
        let tool = candidate.tool
        let version = candidate.version
        let path = candidate.path
        let checker = SafetyChecker()
        var evidence =
            context.references.evidence(manager: location.manager, tool: tool, version: version)
            + context.globals.evidence(manager: location.manager, tool: tool, version: version)
        let links = (context.references.links + context.globals.links).filter {
            DevArtifactPaths.overlaps(path, $0.destination)
        }
        evidence += links.map { "Linked dependency: " + $0.source.path }
        let blockers = ManagedCleanupEvidence.blockers(context.snapshot, path: path, manager: location.manager.rawValue)
        let active = !evidence.isEmpty || !blockers.isEmpty
        evidence += blockers.map { "Running job: " + $0.label }
        var reasons: [String] = []
        let inspected = try await inspect(path, location: location, checker: checker)
        reasons += inspected.reasons
        reasons += retentionReasons(
            candidate, location: location, context: context,
            signal: inspected.signal, active: active)
        if let signal = inspected.signal {
            evidence.append("Newest executable access / file modification signal: " + signal.formatted())
        }
        evidence += reasons
        let status: ToolchainStatus = active ? .active : (reasons.isEmpty ? .stale : .unknown)
        return ToolchainInstallation(
            manager: location.manager, tool: tool, version: version, path: path,
            size: inspected.size, lastUsedSignal: inspected.signal, status: status, evidence: evidence,
            command: status == .stale
                ? ToolchainDiscovery.command(location: location, tool: tool, version: version) : nil,
            identity: inspected.identity, executableIdentity: inspected.executableIdentity,
            executableStamp: inspected.executableStamp,
            content: inspected.content, witnesses: context.references.witnesses + context.globals.witnesses)
    }

    private static func retentionReasons(
        _ candidate: ToolchainCandidate, location: ToolchainLocation,
        context: Context, signal: Date?, active: Bool
    ) -> [String] {
        var reasons: [String] = []
        let relevant = (context.references.values + context.globals.values).filter {
            $0.manager == location.manager && $0.tool == candidate.tool
        }
        if relevant.contains(where: {
            !ToolchainReferences.matches($0.version, version: candidate.version)
                && !context.installedVersions.contains($0.version)
                && !Self.isExactOrNumericReference($0.version)
        }) {
            reasons.append("An unresolved version alias or dynamic reference requires manual review.")
        }
        if !context.references.issues.isEmpty || context.references.unknownManagers.contains(location.manager)
            || context.globals.unknownManagers.contains(location.manager) {
            reasons.append("Repository or global-selection coverage is incomplete.")
        }
        if let reason = ManagedCleanupEvidence.activityReason(context.snapshot, blockers: []), !active {
            reasons.append(reason)
        }
        if !context.capability {
            reasons.append("A supported native uninstall command is unavailable; inventory only.")
        }
        if !ToolchainReferenceParser.validIdentifier(candidate.tool)
            || !ToolchainReferenceParser.validVersion(candidate.version) {
            reasons.append("The manager identifier is unsupported for native uninstall.")
        }
        let oldEnough = signal.map { $0 < context.policy.cutoff(now: context.now) } ?? false
        if !oldEnough {
            reasons.append("No activity signal older than \(context.policy.staleMonths) months is available.")
        }
        return reasons
    }

    private static func inspect(
        _ path: URL, location: ToolchainLocation,
        checker: SafetyChecker
    ) async throws -> Inspection {
        var result = Inspection()
        do {
            result.identity = try ManagedCleanupEvidence.identity(path)
            guard result.identity?.type == 0o040000 else {
                throw DevArtifactSafetyError("Runtime is not a real directory.")
            }
            let inspected = try await DevArtifactIO.run { try ToolchainEvidence.inspect(path, checker: checker) }
            result.content = inspected.nodes
            result.size = inspected.size
            result.signal = inspected.signal == .distantPast ? nil : inspected.signal
            if let executable = location.executable {
                let resolved = executable.resolvingSymlinksInPath()
                result.executableIdentity = try DevArtifactIdentity.read(resolved)
                var executableInfo = stat()
                guard lstat(resolved.path, &executableInfo) == 0 else {
                    throw DevArtifactSafetyError("Manager executable metadata unavailable.")
                }
                result.executableStamp = .init(path: resolved.path, status: executableInfo)
            }
        } catch is CancellationError { throw CancellationError() } catch {
            result.reasons.append(error.localizedDescription)
            // Preserve honest read-only result.size information even when mutation protection vetoes inspection.
            result.size = try? await DevArtifactIO.run { try DevArtifactContent.measure(path).size }
        }
        return result
    }

    private static func isExactOrNumericReference(_ value: String) -> Bool {
        value == "system" || value.range(of: #"^v?[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil
    }
}
