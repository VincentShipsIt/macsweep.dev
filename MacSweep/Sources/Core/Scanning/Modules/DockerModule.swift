import Foundation

/// Resolves the `docker` CLI across install layouts. The old code hardcoded
/// `/usr/local/bin/docker` (Intel Homebrew) in several spots, so disk-usage and
/// `docker info` probes silently no-op'd on Apple Silicon, where Homebrew lives
/// at `/opt/homebrew`. Checks each candidate for existence and returns the first.
enum DockerCLI {
    static let candidatePaths = [
        "/usr/local/bin/docker",                                   // Intel Homebrew
        "/opt/homebrew/bin/docker",                                // Apple Silicon Homebrew
        "/Applications/Docker.app/Contents/Resources/bin/docker",  // Docker Desktop bundle
    ]

    /// First docker binary that actually exists, or nil if none is installed.
    static var path: String? {
        candidatePaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Parse a Docker size token (e.g. "1.5GB", "256M", "512kB") into bytes.
    /// Accepts both the two-letter (`GB`) and bare (`G`) unit forms Docker emits
    /// across subcommands/versions. Single source of truth for both call sites.
    static func parseBytes(_ str: String) -> Int64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed.filter { $0.isNumber || $0 == "." }) else { return 0 }
        let upper = trimmed.uppercased()
        if upper.hasSuffix("GB") || upper.hasSuffix("G") {
            return Int64(value * 1_073_741_824)
        } else if upper.hasSuffix("MB") || upper.hasSuffix("M") {
            return Int64(value * 1_048_576)
        } else if upper.hasSuffix("KB") || upper.hasSuffix("K") {
            return Int64(value * 1024)
        }
        return Int64(value)
    }
}

/// Module for cleaning Docker resources
struct DockerModule: ScanModule {
    let id = "docker"
    let name = "Docker"
    let description = "Clean Docker containers, images, volumes, and build cache"
    let icon = "shippingbox.fill"

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
        DockerCLI.path != nil ||
        FileManager.default.fileExists(atPath: "/Applications/Docker.app")
    }

    private func getDockerDiskUsage() async -> [CleanupItem]? {
        guard let dockerPath = DockerCLI.path else { return nil }

        // Run docker off the cooperative pool so waitUntilExit doesn't pin a
        // concurrency thread. Only the captured String crosses in; parsing happens
        // back here so `self` isn't captured by the detached task.
        let data: Data? = await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: dockerPath)
            // Summary form (no `-v`) prints one JSON object per resource type,
            // each carrying a human-readable `Reclaimable` field we parse into
            // real per-category byte estimates.
            process.arguments = ["system", "df", "--format", "{{json .}}"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Drain before reaping to avoid a full-pipe deadlock.
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return out
            } catch {
                return nil
            }
        }.value

        guard let data else { return nil }
        return parseDockerDF(data)
    }

    private func parseDockerDF(_ data: Data) -> [CleanupItem] {
        guard !data.isEmpty else { return [] }

        // Real reclaimable bytes per resource type, parsed from `docker system df`.
        // Sizing the sentinel items with these (instead of a synthetic 0) makes
        // the dry-run estimate and DeletionGuard's byte-cap honest about what a
        // subsequent `prune` would reclaim. The paths remain nominal sentinels:
        // reclamation happens via category-scoped `docker ... prune -f` in
        // clean() (Docker's own "unused only" semantics), not by real file paths.
        let reclaimableByType = Self.parseReclaimableByType(data)

        let categories: [(name: String, itemId: String, dfType: String)] = [
            ("Docker Build Cache", "docker-build-cache", "Build Cache"),
            ("Docker Images", "docker-images", "Images"),
            ("Docker Containers", "docker-containers", "Containers"),
            ("Docker Volumes", "docker-volumes", "Local Volumes"),
        ]

        var items: [CleanupItem] = []
        for category in categories {
            let reclaimable = reclaimableByType[category.dfType] ?? 0
            guard reclaimable > 0 else { continue }  // nothing to reclaim — don't surface
            items.append(CleanupItem(
                id: UUID(),
                path: URL(fileURLWithPath: "/var/lib/docker/\(category.itemId)"),  // sentinel
                size: reclaimable,
                type: .directory,
                module: id,
                moduleName: category.name,
                lastModified: nil
            ))
        }

        return items
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
            result[type] = DockerCLI.parseBytes(sizeToken)
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

        for item in items where item.module == id {
            if dryRun {
                // item.size is the real reclaimable estimate from `docker system
                // df` (see parseDockerDF), so this is an honest preview, not a
                // synthetic echo. Actual runs below report the bytes Docker says
                // it reclaimed.
                processed += 1
                freed += item.size
                continue
            }

            // Handle different cleanup types
            switch item.moduleName {
            case "Docker Build Cache":
                let result = await runDockerCommand(["builder", "prune", "-f"])
                if result.success {
                    processed += 1
                    freed += result.bytesFreed
                }

            case "Docker Images":
                // Remove dangling images
                let result = await runDockerCommand(["image", "prune", "-f"])
                if result.success {
                    processed += 1
                    freed += result.bytesFreed
                }

            case "Docker Containers":
                // Remove stopped containers
                let result = await runDockerCommand(["container", "prune", "-f"])
                if result.success {
                    processed += 1
                    freed += result.bytesFreed
                }

            case "Docker Volumes":
                // Remove unused volumes
                let result = await runDockerCommand(["volume", "prune", "-f"])
                if result.success {
                    processed += 1
                    freed += result.bytesFreed
                }

            case "Docker VM Disk":
                // Can't clean VM disk directly - would need Docker Desktop reset
                errors.append(CleanupError(
                    path: item.path,
                    message: "Docker VM disk requires Docker Desktop reset to reclaim space"
                ))

            default:
                break
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }

    private func runDockerCommand(_ args: [String]) async -> (success: Bool, bytesFreed: Int64) {
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

            // Parse reclaimed space from output
            // Format: "Total reclaimed space: 1.234GB"
            if let range = output.range(of: "reclaimed space: "),
               let endRange = output.range(of: "B", range: range.upperBound..<output.endIndex) {
                let sizeStr = String(output[range.upperBound..<endRange.lowerBound])
                let bytes = DockerCLI.parseBytes(sizeStr)
                return (process.terminationStatus == 0, bytes)
            }

            return (process.terminationStatus == 0, 0)
        } catch {
            return (false, 0)
        }
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
