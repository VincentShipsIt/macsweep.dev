import Foundation

/// System maintenance actions
actor MaintenanceActions {

    // MARK: - Free Up RAM

    /// Purge inactive memory (requires admin for full effect)
    static func freeUpRAM() async throws -> MaintenanceResult {
        let startMemory = await getAvailableMemory()

        // Use purge command (located at /usr/sbin/purge on macOS)
        let process = Process()
        let purgePath = "/usr/sbin/purge"

        guard FileManager.default.fileExists(atPath: purgePath) else {
            throw MaintenanceError.commandFailed("purge", "The purge command is not available on this system")
        }

        process.executableURL = URL(fileURLWithPath: purgePath)

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                throw MaintenanceError.commandFailed("purge", "Exit code: \(process.terminationStatus)")
            }

            // Wait a moment for memory to settle
            try await Task.sleep(nanoseconds: 500_000_000)

            let endMemory = await getAvailableMemory()
            let freed = max(0, endMemory - startMemory)

            return MaintenanceResult(
                success: true,
                message: "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .memory)) of RAM",
                bytesFreed: freed
            )
        } catch {
            throw MaintenanceError.commandFailed("purge", error.localizedDescription)
        }
    }

    private static func getAvailableMemory() async -> Int64 {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Drain the pipe BEFORE reaping: readDataToEndOfFile blocks until the
            // child closes its write end (on exit), so a verbose child can't fill
            // the 64 KB pipe buffer and deadlock against waitUntilExit.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return 0 }

            // Page size is 4 KB on Intel but 16 KB on Apple Silicon — read it
            // dynamically so the byte total isn't 4x wrong on Apple Silicon.
            let pageSize = Int64(sysconf(Int32(_SC_PAGESIZE)))
            let resolvedPageSize = pageSize > 0 ? pageSize : 4096

            return parseVMStatFreeBytes(output, pageSize: resolvedPageSize)
        } catch {
            // Ignore
        }

        return 0
    }

    /// Free bytes from `vm_stat` output ("Pages free: 12345.") for the given
    /// page size; 0 when the marker line is absent or malformed. Split from
    /// `getAvailableMemory` so the parsing is deterministic and testable
    /// without spawning vm_stat.
    static func parseVMStatFreeBytes(_ output: String, pageSize: Int64) -> Int64 {
        for line in output.split(separator: "\n") where line.contains("Pages free") {
            let parts = line.split(separator: ":")
            if let valueStr = parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: " .")),
               let pages = Int64(valueStr) {
                return pages * pageSize
            }
        }
        return 0
    }

    // MARK: - Flush DNS Cache

    /// Flush the DNS resolver cache
    static func flushDNSCache() async throws -> MaintenanceResult {
        // macOS uses different commands depending on version
        let commands = [
            ("/usr/bin/dscacheutil", ["-flushcache"]),
            ("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        ]

        var success = true
        var messages: [String] = []

        for (executable, args) in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    messages.append("\(URL(fileURLWithPath: executable).lastPathComponent) succeeded")
                } else {
                    messages.append("\(URL(fileURLWithPath: executable).lastPathComponent) failed")
                    success = false
                }
            } catch {
                messages.append("\(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)")
                success = false
            }
        }

        return MaintenanceResult(
            success: success,
            message: success ? "DNS cache flushed successfully" : messages.joined(separator: ", ")
        )
    }

    // MARK: - Rebuild Spotlight Index

    /// Rebuild the Spotlight index (requires admin)
    static func rebuildSpotlight() async throws -> MaintenanceResult {
        // First, turn off indexing
        let turnOff = Process()
        turnOff.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        turnOff.arguments = ["-i", "off", "/"]
        turnOff.standardOutput = FileHandle.nullDevice
        turnOff.standardError = FileHandle.nullDevice

        // Then turn it back on to trigger reindex
        let turnOn = Process()
        turnOn.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        turnOn.arguments = ["-i", "on", "/"]
        turnOn.standardOutput = FileHandle.nullDevice
        turnOn.standardError = FileHandle.nullDevice

        do {
            try turnOff.run()
            turnOff.waitUntilExit()

            try await Task.sleep(nanoseconds: 1_000_000_000)

            try turnOn.run()
            turnOn.waitUntilExit()

            return MaintenanceResult(
                success: true,
                message: "Spotlight reindexing started. This may take some time."
            )
        } catch {
            throw MaintenanceError.commandFailed("mdutil", error.localizedDescription)
        }
    }

    // MARK: - Repair Disk Permissions

    /// Run disk repair (First Aid) - Note: Full repair requires Recovery Mode
    static func repairDiskPermissions() async throws -> MaintenanceResult {
        // diskutil verifyVolume is the closest we can do without Recovery
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["verifyVolume", "/"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            // Drain before reaping: a damaged volume can emit thousands of error
            // lines, overflowing the 64 KB pipe buffer and deadlocking a
            // wait-then-read ordering.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""

            let success = process.terminationStatus == 0
            return MaintenanceResult(
                success: success,
                message: success ? "Volume verified successfully" : "Volume verification found issues: \(output.prefix(200))"
            )
        } catch {
            throw MaintenanceError.commandFailed("diskutil", error.localizedDescription)
        }
    }

    // MARK: - Free Purgeable Space

    /// Trigger APFS purgeable space reclamation
    static func freePurgeableSpace() async throws -> MaintenanceResult {
        // Get current purgeable space
        let beforePurgeable = await getPurgeableSpace()

        // Create and delete a large file to trigger reclamation
        let tempFile = FileManager.default.temporaryDirectory.appending(path: "macsweep_purge_\(UUID().uuidString)")

        // Allocate a real 1GB file (NOT sparse) to apply space pressure. The
        // previous "-n" flag created a sparse file that reserves no blocks, so
        // it never forced APFS to reclaim purgeable space — the whole point.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mkfile")
        process.arguments = ["1g", tempFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            // Whether the pressure file was actually allocated. If mkfile failed
            // (e.g. the disk had < 1 GB free), no space pressure was applied and we
            // must not report success as if reclamation was triggered.
            let mkfileSucceeded = process.terminationStatus == 0

            // Delete the file
            try? FileManager.default.removeItem(at: tempFile)

            // Run periodic scripts regardless — a useful side-effect either way.
            let periodic = Process()
            periodic.executableURL = URL(fileURLWithPath: "/usr/sbin/periodic")
            periodic.arguments = ["daily", "weekly", "monthly"]
            periodic.standardOutput = FileHandle.nullDevice
            periodic.standardError = FileHandle.nullDevice

            try? periodic.run()
            // Don't wait - periodic can take a long time

            let afterPurgeable = await getPurgeableSpace()
            let freed = max(0, beforePurgeable - afterPurgeable)

            guard mkfileSucceeded else {
                return MaintenanceResult(
                    success: false,
                    message: "Could not allocate the 1 GB pressure file (disk may already be full); ran periodic scripts only",
                    bytesFreed: freed
                )
            }

            return MaintenanceResult(
                success: true,
                message: freed > 0 ? "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) of purgeable space" : "Purgeable space optimization triggered",
                bytesFreed: freed
            )
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            throw MaintenanceError.commandFailed("mkfile", error.localizedDescription)
        }
    }

    private static func getPurgeableSpace() async -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey, .volumeAvailableCapacityKey])

        let opportunistic = Int64(values?.volumeAvailableCapacityForOpportunisticUsage ?? 0)
        let available = Int64(values?.volumeAvailableCapacity ?? 0)

        return opportunistic - available
    }

    // MARK: - Run Maintenance Scripts

    /// Run macOS periodic maintenance scripts
    static func runMaintenanceScripts() async throws -> MaintenanceResult {
        let scripts = ["daily", "weekly", "monthly"]
        var results: [String] = []

        for script in scripts {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/periodic")
            process.arguments = [script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                // Don't wait - these can take a long time
                results.append("\(script): started")
            } catch {
                results.append("\(script): failed")
            }
        }

        return MaintenanceResult(
            success: true,
            message: "Maintenance scripts running in background"
        )
    }

    // MARK: - Clear Font Caches

    /// Clear font caches
    static func clearFontCaches() async throws -> MaintenanceResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/atsutil")
        process.arguments = ["databases", "-remove"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            return MaintenanceResult(
                success: process.terminationStatus == 0,
                message: process.terminationStatus == 0 ? "Font caches cleared" : "Failed to clear font caches"
            )
        } catch {
            throw MaintenanceError.commandFailed("atsutil", error.localizedDescription)
        }
    }

    // MARK: - Rebuild Launch Services

    /// Rebuild the Launch Services database
    static func rebuildLaunchServices() async throws -> MaintenanceResult {
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

        guard FileManager.default.fileExists(atPath: lsregisterPath) else {
            throw MaintenanceError.commandFailed("lsregister", "Launch Services tool not found at expected location")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        // Use only user domain for sandboxed apps (system/local require elevated privileges)
        process.arguments = ["-kill", "-r", "-domain", "user"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            return MaintenanceResult(
                success: process.terminationStatus == 0,
                message: process.terminationStatus == 0 ? "Launch Services database rebuilt" : "Failed to rebuild Launch Services (may require elevated privileges)"
            )
        } catch {
            throw MaintenanceError.commandFailed("lsregister", error.localizedDescription)
        }
    }
}

// MARK: - Result Types

struct MaintenanceResult {
    let success: Bool
    let message: String
    var bytesFreed: Int64 = 0

    var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }
}

enum MaintenanceError: LocalizedError {
    case commandFailed(String, String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let reason):
            return "\(command) failed: \(reason)"
        case .permissionDenied(let action):
            return "Permission denied for \(action). Administrator access may be required."
        }
    }
}

// MARK: - Maintenance Task Definition

struct MaintenanceTask: Identifiable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let action: () async throws -> MaintenanceResult
    let requiresAdmin: Bool

    static let allTasks: [MaintenanceTask] = [
        MaintenanceTask(
            id: "free-ram",
            name: "Free Up RAM",
            icon: "memorychip",
            description: "Clear inactive memory to free up RAM",
            action: { try await MaintenanceActions.freeUpRAM() },
            requiresAdmin: false
        ),
        MaintenanceTask(
            id: "flush-dns",
            name: "Flush DNS Cache",
            icon: "network",
            description: "Reset the DNS resolver cache",
            action: { try await MaintenanceActions.flushDNSCache() },
            requiresAdmin: false
        ),
        MaintenanceTask(
            id: "rebuild-spotlight",
            name: "Rebuild Spotlight",
            icon: "magnifyingglass",
            description: "Reindex the Spotlight database",
            action: { try await MaintenanceActions.rebuildSpotlight() },
            requiresAdmin: true
        ),
        MaintenanceTask(
            id: "verify-disk",
            name: "Verify Disk",
            icon: "externaldrive",
            description: "Check the boot volume for errors",
            action: { try await MaintenanceActions.repairDiskPermissions() },
            requiresAdmin: false
        ),
        MaintenanceTask(
            id: "free-purgeable",
            name: "Free Purgeable Space",
            icon: "arrow.3.trianglepath",
            description: "Reclaim purgeable disk space",
            action: { try await MaintenanceActions.freePurgeableSpace() },
            requiresAdmin: false
        ),
        MaintenanceTask(
            id: "maintenance-scripts",
            name: "Run Maintenance Scripts",
            icon: "terminal",
            description: "Run daily, weekly, and monthly scripts",
            action: { try await MaintenanceActions.runMaintenanceScripts() },
            requiresAdmin: true
        ),
        MaintenanceTask(
            id: "clear-font-cache",
            name: "Clear Font Caches",
            icon: "textformat",
            description: "Clear font caches to fix font issues",
            action: { try await MaintenanceActions.clearFontCaches() },
            requiresAdmin: false
        ),
        MaintenanceTask(
            id: "rebuild-launchservices",
            name: "Rebuild Launch Services",
            icon: "app.badge",
            description: "Fix app associations and duplicates",
            action: { try await MaintenanceActions.rebuildLaunchServices() },
            requiresAdmin: false
        ),
    ]
}
