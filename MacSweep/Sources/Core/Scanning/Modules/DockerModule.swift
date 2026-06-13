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

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = ["system", "df", "-v", "--format", "{{json .}}"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return parseDockerDF(data)
        } catch {
            return nil
        }
    }

    private func parseDockerDF(_ data: Data) -> [CleanupItem] {
        // Docker df output is complex, so we'll use simpler approach
        // by scanning the actual Docker directories

        var items: [CleanupItem] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Docker data root (Docker Desktop)
        let dockerData = home.appending(path: "Library/Containers/com.docker.docker/Data")

        // Check for build cache info from docker system df
        if let output = String(data: data, encoding: .utf8) {
            // Parse the output to extract sizes
            // This is a simplified version - full JSON parsing would be better

            // For now, add general Docker cleanup items
            let dockerItems: [(String, String)] = [
                ("Docker Build Cache", "docker-build-cache"),
                ("Docker Images", "docker-images"),
                ("Docker Containers", "docker-containers"),
                ("Docker Volumes", "docker-volumes"),
            ]

            for (name, itemId) in dockerItems {
                items.append(CleanupItem(
                    id: UUID(),
                    path: URL(fileURLWithPath: "/var/lib/docker/\(itemId)"),  // Placeholder
                    size: 0,  // Will be updated by actual cleanup
                    type: .directory,
                    module: id,
                    moduleName: name,
                    lastModified: nil
                ))
            }
        }

        return items
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
                let bytes = parseSize(sizeStr)
                return (process.terminationStatus == 0, bytes)
            }

            return (process.terminationStatus == 0, 0)
        } catch {
            return (false, 0)
        }
    }

    private func parseSize(_ str: String) -> Int64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed.filter { $0.isNumber || $0 == "." }) else { return 0 }

        if trimmed.contains("G") {
            return Int64(value * 1_073_741_824)
        } else if trimmed.contains("M") {
            return Int64(value * 1_048_576)
        } else if trimmed.contains("K") {
            return Int64(value * 1024)
        }
        return Int64(value)
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
                    bytesFreed = parseDockerSize(sizeStr)
                }
            }

            return (process.terminationStatus == 0, bytesFreed)
        } catch {
            return (false, 0)
        }
    }

    private static func parseDockerSize(_ str: String) -> Int64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        let numStr = trimmed.filter { $0.isNumber || $0 == "." }
        guard let value = Double(numStr) else { return 0 }

        if trimmed.hasSuffix("GB") {
            return Int64(value * 1_073_741_824)
        } else if trimmed.hasSuffix("MB") {
            return Int64(value * 1_048_576)
        } else if trimmed.hasSuffix("KB") || trimmed.hasSuffix("kB") {
            return Int64(value * 1024)
        }
        return Int64(value)
    }
}
