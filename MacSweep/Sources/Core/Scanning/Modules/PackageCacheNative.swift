import Darwin
import Foundation

typealias PackageCacheCommandRunner = @Sendable (String, [String]) async throws -> ProcessResult

extension PackageManagerModule {
    func protectUVEnvironments(cache: URL) throws {
        // Native prune also removes cached environments; working environments remain protected.
        for child in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        where child.lastPathComponent.hasPrefix("environments-") {
            throw DevArtifactSafetyError("UV cached environments are retained; native prune would remove them.")
        }
        var roots = [homeDirectory.appendingPathComponent(".local/share/uv/tools")]
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["UV_TOOL_DIR"] {
            guard configured.hasPrefix("/") else { throw DevArtifactSafetyError("Relative UV tool scope is retained.") }
            roots.append(URL(fileURLWithPath: configured))
        }
        if let configured = environment["XDG_DATA_HOME"] {
            guard configured.hasPrefix("/") else {
                throw DevArtifactSafetyError("Relative XDG tool scope is retained.")
            }
            roots.append(URL(fileURLWithPath: configured).appendingPathComponent("uv/tools"))
        }
        for root in Set(roots) where FileManager.default.fileExists(atPath: root.path) {
            try protectUVToolLinks(tools: root, cache: cache)
        }
    }

    private func protectUVToolLinks(tools: URL, cache: URL) throws {
        _ = try ManagedCleanupEvidence.identity(tools)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var failure: Error?
        guard
            let entries = FileManager.default.enumerator(
                at: tools, includingPropertiesForKeys: nil,
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else {
            throw DevArtifactSafetyError("Installed UV tool dependency evidence unavailable.")
        }
        var count = 0
        for case let entry as URL in entries {
            count += 1
            guard count < 100_000, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Installed UV tool inspection exceeded its safety limit.")
            }
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { throw DevArtifactSafetyError("UV tool metadata unavailable.") }
            if info.st_mode & S_IFMT == S_IFLNK, DevArtifactPaths.overlaps(cache, entry.resolvingSymlinksInPath()) {
                throw DevArtifactSafetyError(
                    "Installed UV tool links into this cache; retained to preserve its environment.")
            }
        }
        if let failure { throw failure }
    }

    func nativeOperation(manager: String) async throws -> ManagedCleanupOperation {
        guard let executable = toolPath(manager) else {
            throw DevArtifactSafetyError("\(manager) is missing; native prune unavailable. Cache retained.")
        }
        let versionResult = try await commandRunner(executable, ["--version"])
        let version = versionResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard versionResult.didSucceed, versionResult.outputWasValidUTF8,
            version.count < 128, !version.contains("\n")
        else { throw DevArtifactSafetyError("Manager version unavailable; cache retained.") }
        let help = try await commandRunner(
            executable, manager == "uv" ? ["cache", "prune", "--help"] : ["pm", "--help"])
        let text = help.output + help.error
        if manager == "uv", version.hasPrefix("uv "), help.didSucceed, help.outputWasValidUTF8,
            text.contains("uv cache prune"), text.contains("--cache-dir"), text.contains("--no-config"),
            text.contains("--offline") {
            return .uvPrune(executable: executable, version: version)
        }
        if manager == "bun", help.didSucceed, help.outputWasValidUTF8,
            text.contains("bun pm cache prune"), Self.supportsBunPrune(version) {
            return .bunPrune(executable: executable, version: version)
        }
        throw DevArtifactSafetyError(
            "Unsupported \(manager) version/capabilities (\(version)); cache retained. No directory-removal fallback.")
    }

    static func supportsBunPrune(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 && parts[0] == 1 && (parts[1] > 4 || parts[1] == 4 && parts[2] >= 3)
    }

    func execute(_ operation: ManagedCleanupOperation, path: URL) async throws -> CleanupHistoryAction {
        if let executable = operation.executable {
            let result: ProcessResult
            do {
                result = try await commandRunner(executable, operation.arguments(path: path))
            } catch is CancellationError { throw CancellationError() } catch {
                throw DevArtifactSafetyError(
                    "Native prune failed or timed out; some entries may have changed. "
                        + "Rescan before retrying. No fallback removal.")
            }
            guard result.didSucceed else {
                throw DevArtifactSafetyError(
                    "Native prune exited \(result.status); some entries may have changed. "
                        + "Rescan. No fallback removal.")
            }
            return .runToolCleanup
        }
        try await DevArtifactIO.run { try remove(path) }
        return .moveToTrash
    }
}
