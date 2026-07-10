import Foundation

/// Resolves the `docker` CLI across install layouts. The old code hardcoded
/// `/usr/local/bin/docker` (Intel Homebrew) in several spots, so disk-usage and
/// `docker info` probes silently no-op'd on Apple Silicon, where Homebrew lives
/// at `/opt/homebrew`. Checks each candidate for existence and returns the first.
enum DockerCLI {
    /// Docker Desktop's bundled CLI — the only location outside Homebrew.
    static let dockerDesktopPath = "/Applications/Docker.app/Contents/Resources/bin/docker"

    /// First docker binary that actually exists — Homebrew under either prefix
    /// (Intel `/usr/local` or Apple Silicon `/opt/homebrew`, resolved by the
    /// shared `HomebrewPaths`), else the Docker Desktop bundle — or nil.
    static var path: String? {
        if let brewDocker = HomebrewPaths.toolPath("docker") { return brewDocker }
        return FileManager.default.fileExists(atPath: dockerDesktopPath) ? dockerDesktopPath : nil
    }

    /// Parse a complete Docker size token (e.g. "1.5GB", "256M", "512kB")
    /// into bytes. Docker's SI labels use powers of 1000; explicit IEC labels
    /// use powers of 1024. Unknown, missing, or malformed units fail closed.
    static func parseBytes(_ str: String) -> Int64 {
        parseVerifiedBytes(str) ?? 0
    }

    /// Optional form used when cleanup must distinguish a real `0B` value from
    /// malformed external output before allowing a destructive Docker action.
    static func parseVerifiedBytes(_ str: String) -> Int64? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let unitStart = trimmed.firstIndex { !$0.isNumber && $0 != "." } ?? trimmed.endIndex
        let number = trimmed[..<unitStart]
        let unit = trimmed[unitStart...]
        guard number.first?.isNumber == true,
              number.last?.isNumber == true,
              number.filter({ $0 == "." }).count <= 1,
              !unit.isEmpty,
              unit.allSatisfy(\.isLetter),
              let value = Double(number),
              value.isFinite,
              value >= 0,
              let multiplier = sizeMultipliers[String(unit).uppercased()]
        else { return nil }

        let bytes = value * multiplier
        // Docker output is external input. Reject non-finite/out-of-range values
        // instead of trapping during Double-to-Int64 conversion.
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    private static let sizeMultipliers: [String: Double] = [
        "B": 1,
        "K": 1_000,
        "KB": 1_000,
        "M": 1_000_000,
        "MB": 1_000_000,
        "G": 1_000_000_000,
        "GB": 1_000_000_000,
        "T": 1_000_000_000_000,
        "TB": 1_000_000_000_000,
        "P": 1_000_000_000_000_000,
        "PB": 1_000_000_000_000_000,
        "KIB": 1_024,
        "MIB": 1_048_576,
        "GIB": 1_073_741_824,
        "TIB": 1_099_511_627_776,
        "PIB": 1_125_899_906_842_624,
    ]
}

typealias DockerCommandRunner = @Sendable (_ executable: String, _ arguments: [String]) async throws -> ProcessResult

/// Module for cleaning Docker resources
struct DockerModule: ScanModule {
    let id = "docker"
    let name = "Docker"
    let description = "Clean Docker containers, images, volumes, and build cache"
    let icon = "shippingbox.fill"

    private let dockerPath: @Sendable () -> String?
    private let commandRunner: DockerCommandRunner

    private static let actionCategories: [(action: DockerCleanupAction, dfType: String)] = [
        (.pruneBuildCache, "Build Cache"),
        (.pruneImages, "Images"),
        (.pruneContainers, "Containers"),
        (.pruneVolumes, "Local Volumes"),
    ]

    private static let dockerDFTypeByAction = Dictionary(
        uniqueKeysWithValues: actionCategories.map { ($0.action, $0.dfType) }
    )

    init(
        dockerPath: @escaping @Sendable () -> String? = { DockerCLI.path },
        commandRunner: @escaping DockerCommandRunner = { executable, arguments in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: 300
            )
        }
    ) {
        self.dockerPath = dockerPath
        self.commandRunner = commandRunner
    }

    func scan() async throws -> [CleanupItem] {
        // Check if Docker is installed
        guard isDockerInstalled() else { return [] }

        var items: [CleanupItem] = []

        // Get Docker disk usage
        if let usage = await getDockerDiskUsage() {
            items.append(contentsOf: usage)
        }

        // Docker Desktop VM disk
        let dockerVM = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.docker.docker/Data/vms")

        if FileManager.default.fileExists(atPath: dockerVM.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: dockerVM)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: dockerVM,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Docker VM Disk",
                    lastModified: nil
                ))
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    private func isDockerInstalled() -> Bool {
        dockerPath() != nil ||
        FileManager.default.fileExists(atPath: "/Applications/Docker.app")
    }

    private func getDockerDiskUsage() async -> [CleanupItem]? {
        guard let reclaimableByType = await getDockerReclaimableByType() else { return nil }
        return Self.actionCategories.compactMap { category in
            let reclaimable = reclaimableByType[category.dfType] ?? 0
            guard reclaimable > 0 else { return nil }
            return CleanupItem(
                id: UUID(),
                action: .docker(category.action),
                size: reclaimable,
                lastModified: nil
            )
        }
    }

    private func getDockerReclaimableByType() async -> [String: Int64]? {
        guard let executable = dockerPath() else { return nil }

        // Summary form (no `-v`) prints one JSON object per resource type,
        // each carrying a human-readable `Reclaimable` field we parse into real
        // per-category byte estimates. ProcessRunner keeps this argv-only and
        // bounded; the injectable runner makes the exact command testable.
        guard let result = try? await commandRunner(
            executable,
            ["system", "df", "--format", "{{json .}}"]
        ), result.didSucceed else { return nil }

        return Self.parseReclaimableByType(Data(result.output.utf8))
    }

    /// Parse `docker system df --format "{{json .}}"` output — one JSON object
    /// per line per resource type — into reclaimable bytes keyed by `Type`.
    /// The `Reclaimable` field looks like `"1.2GB (80%)"` or `"0B"`; we take the
    /// leading size token.
    static func parseReclaimableByType(_ data: Data) -> [String: Int64] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["Type"] as? String,
                  let reclaimable = object["Reclaimable"] as? String else { continue }
            let sizeToken = reclaimable.split(separator: " ").first.map(String.init) ?? reclaimable
            guard let byteCount = DockerCLI.parseVerifiedBytes(sizeToken) else { continue }
            result[type] = byteCount
        }
        return result
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        guard isDockerInstalled() else {
            return CleanupResult(itemsProcessed: 0, bytesFreed: 0)
        }

        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []

        let requiresFreshImpact = !dryRun && items.contains { item in
            guard item.module == id, item.size > 0,
                  case .action(.docker) = item.target else { return false }
            return true
        }
        // A prune acts on execution-time Docker state, not the earlier scan
        // snapshot. Refresh once immediately before the allowlisted commands;
        // every current category must remain at or below its guarded declaration.
        // Docker can still change in the narrow interval after this query, but
        // refusing any observed growth removes the long scan-to-clean stale window.
        let freshReclaimable = requiresFreshImpact ? await getDockerReclaimableByType() : nil

        var executedActions: Set<DockerCleanupAction> = []
        for item in items where item.module == id {
            guard case .action(.docker(let action)) = item.target else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Unsupported Docker cleanup target"
                ))
                continue
            }
            guard item.size > 0 else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Docker cleanup action has no verified reclaimable impact"
                ))
                continue
            }

            if dryRun {
                // item.size is the real reclaimable estimate from `docker system
                // df` (see parseDockerDF), so this is an honest preview, not a
                // synthetic echo. Actual runs below report the bytes Docker says
                // it reclaimed.
                processed += 1
                freed += item.size
                continue
            }

            guard let dfType = Self.dockerDFTypeByAction[action],
                  let currentReclaimable = freshReclaimable?[dfType]
            else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Unable to verify current Docker cleanup impact; rescan before cleaning"
                ))
                continue
            }
            guard currentReclaimable <= item.size else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Docker cleanup impact increased after scanning; rescan before cleaning"
                ))
                continue
            }

            // A duplicated finding must not run the same destructive command
            // twice. It still contributed to DeletionGuard's conservative sum.
            guard executedActions.insert(action).inserted else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Duplicate Docker cleanup action"
                ))
                continue
            }

            let result = await runDockerCommand(action)
            if result.success {
                processed += 1
                freed += result.bytesFreed
            } else {
                errors.append(CleanupError(
                    path: item.path,
                    message: result.error ?? "Docker cleanup command failed"
                ))
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }

    private func runDockerCommand(
        _ action: DockerCleanupAction
    ) async -> (success: Bool, bytesFreed: Int64, error: String?) {
        guard let executable = dockerPath() else {
            return (false, 0, "Docker CLI is unavailable")
        }
        do {
            let result = try await commandRunner(executable, action.arguments)

            // Parse reclaimed space from output
            // Format: "Total reclaimed space: 1.234GB"
            let bytes = Self.parseReclaimedBytes(result.output)
            let error = result.didSucceed
                ? nil
                : (result.error.isEmpty ? "Docker cleanup command failed" : result.error)
            return (result.didSucceed, bytes, error)
        } catch {
            return (false, 0, error.localizedDescription)
        }
    }

    private static func parseReclaimedBytes(_ output: String) -> Int64 {
        guard let range = output.range(of: "reclaimed space: ", options: .caseInsensitive) else {
            return 0
        }
        let token = output[range.upperBound...]
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        return DockerCLI.parseBytes(token)
    }
}

// MARK: - Docker Info

struct DockerInfo {
    var isInstalled: Bool = false
    var isRunning: Bool = false
    var containers: Int = 0
    var images: Int = 0
    var volumes: Int = 0
    var buildCacheSize: Int64 = 0
    var totalSize: Int64 = 0

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    static func current() async -> DockerInfo {
        var info = DockerInfo()

        // Check if Docker is installed
        guard let dockerPath = DockerCLI.path else { return info }
        info.isInstalled = true

        // Check if Docker is running
        let pingProcess = Process()
        pingProcess.executableURL = URL(fileURLWithPath: dockerPath)
        pingProcess.arguments = ["info"]
        pingProcess.standardOutput = FileHandle.nullDevice
        pingProcess.standardError = FileHandle.nullDevice

        do {
            try pingProcess.run()
            pingProcess.waitUntilExit()
            info.isRunning = pingProcess.terminationStatus == 0
        } catch {
            info.isRunning = false
        }

        guard info.isRunning else { return info }

        // Get counts
        info.containers = await getDockerCount("container", "ls", "-aq")
        info.images = await getDockerCount("image", "ls", "-q")
        info.volumes = await getDockerCount("volume", "ls", "-q")

        return info
    }

    private static func getDockerCount(_ args: String...) async -> Int {
        guard let dockerPath = DockerCLI.path else { return 0 }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = Array(args)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(separator: "\n").count
        } catch {
            return 0
        }
    }
}

// MARK: - Docker Cleanup Actions

struct DockerCleanupActions {
    /// Run docker system prune (removes all unused data)
    static func systemPrune(includeVolumes: Bool = false) async throws -> CleanupResult {
        var args = ["system", "prune", "-f"]
        if includeVolumes {
            args.append("--volumes")
        }

        let result = await runDocker(args)
        return CleanupResult(
            itemsProcessed: result.success ? 1 : 0,
            bytesFreed: result.bytesFreed
        )
    }

    /// Remove all stopped containers
    static func pruneContainers() async throws -> CleanupResult {
        let result = await runDocker(["container", "prune", "-f"])
        return CleanupResult(
            itemsProcessed: result.success ? 1 : 0,
            bytesFreed: result.bytesFreed
        )
    }

    /// Remove dangling images
    static func pruneImages(all: Bool = false) async throws -> CleanupResult {
        var args = ["image", "prune", "-f"]
        if all {
            args.append("-a")
        }

        let result = await runDocker(args)
        return CleanupResult(
            itemsProcessed: result.success ? 1 : 0,
            bytesFreed: result.bytesFreed
        )
    }

    /// Remove unused volumes
    static func pruneVolumes() async throws -> CleanupResult {
        let result = await runDocker(["volume", "prune", "-f"])
        return CleanupResult(
            itemsProcessed: result.success ? 1 : 0,
            bytesFreed: result.bytesFreed
        )
    }

    /// Clear build cache
    static func pruneBuildCache() async throws -> CleanupResult {
        let result = await runDocker(["builder", "prune", "-f", "--all"])
        return CleanupResult(
            itemsProcessed: result.success ? 1 : 0,
            bytesFreed: result.bytesFreed
        )
    }

    private static func runDocker(_ args: [String]) async -> (success: Bool, bytesFreed: Int64) {
        guard let dockerPath = DockerCLI.path else { return (false, 0) }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Parse reclaimed space
            var bytesFreed: Int64 = 0
            if let range = output.range(of: "reclaimed space: ") {
                let afterRange = output[range.upperBound...]
                if let endIndex = afterRange.firstIndex(of: "\n") ?? afterRange.firstIndex(of: " ") {
                    let sizeStr = String(afterRange[..<endIndex])
                    bytesFreed = DockerCLI.parseBytes(sizeStr)
                }
            }

            return (process.terminationStatus == 0, bytesFreed)
        } catch {
            return (false, 0)
        }
    }

}
