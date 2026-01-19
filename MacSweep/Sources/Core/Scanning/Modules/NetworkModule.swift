import Foundation
import CoreWLAN
import SystemConfiguration

/// Module for cleaning network-related data
struct NetworkModule: ScanModule {
    let id = "network"
    let name = "Network"
    let description = "Clean WiFi networks, SSH keys, and network caches"
    let icon = "network"

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        // SSH known_hosts
        items.append(contentsOf: await scanSSH())

        // Network preferences
        items.append(contentsOf: await scanNetworkPreferences())

        // Bonjour cache
        items.append(contentsOf: await scanBonjourCache())

        return items.sorted { $0.size > $1.size }
    }

    // MARK: - SSH

    private func scanSSH() async -> [CleanupItem] {
        var items: [CleanupItem] = []
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")

        // known_hosts
        let knownHosts = sshDir.appending(path: "known_hosts")
        if FileManager.default.fileExists(atPath: knownHosts.path) {
            let size = (try? await DiskAnalyzer.size(of: knownHosts)) ?? 0
            let hostCount = countLines(at: knownHosts)

            items.append(CleanupItem(
                id: UUID(),
                path: knownHosts,
                size: size,
                type: .file,
                module: id,
                moduleName: "SSH Known Hosts (\(hostCount) entries)"
            ))
        }

        // known_hosts.old
        let knownHostsOld = sshDir.appending(path: "known_hosts.old")
        if FileManager.default.fileExists(atPath: knownHostsOld.path) {
            let size = (try? await DiskAnalyzer.size(of: knownHostsOld)) ?? 0
            items.append(CleanupItem(
                id: UUID(),
                path: knownHostsOld,
                size: size,
                type: .file,
                module: id,
                moduleName: "SSH Known Hosts (Old)"
            ))
        }

        return items
    }

    // MARK: - Network Preferences

    private func scanNetworkPreferences() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Network interface cache
        let networkCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/com.apple.networkextension.cache.plist")

        if FileManager.default.fileExists(atPath: networkCache.path) {
            let size = (try? await DiskAnalyzer.size(of: networkCache)) ?? 0
            items.append(CleanupItem(
                id: UUID(),
                path: networkCache,
                size: size,
                type: .file,
                module: id,
                moduleName: "Network Extension Cache"
            ))
        }

        return items
    }

    // MARK: - Bonjour

    private func scanBonjourCache() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let bonjourCache = URL(fileURLWithPath: "/var/db/mds/messages")
        if FileManager.default.fileExists(atPath: bonjourCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: bonjourCache)) ?? 0
            if size > 1024 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: bonjourCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Bonjour Cache"
                ))
            }
        }

        return items
    }

    private func countLines(at url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return content.split(separator: "\n").count
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
            } else {
                do {
                    // For known_hosts, we might want to keep a backup
                    if item.moduleName.contains("Known Hosts") && !item.moduleName.contains("Old") {
                        let backupPath = item.path.deletingLastPathComponent().appending(path: "known_hosts.old")
                        try? FileManager.default.removeItem(at: backupPath)
                        try FileManager.default.copyItem(at: item.path, to: backupPath)
                    }

                    try FileManager.default.removeItem(at: item.path)
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(
                        path: item.path,
                        message: error.localizedDescription,
                        underlyingError: error
                    ))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - WiFi Network Management

struct WiFiNetworkManager {
    /// Get list of saved WiFi networks
    static func savedNetworks() -> [SavedWiFiNetwork] {
        var networks: [SavedWiFiNetwork] = []

        // Use networksetup to get preferred networks
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listpreferredwirelessnetworks", "en0"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            // Parse output - format: "\tNetworkName"
            let lines = output.split(separator: "\n").dropFirst()  // Skip header
            for line in lines {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    networks.append(SavedWiFiNetwork(
                        ssid: name,
                        isCurrentlyConnected: false  // Would need to check separately
                    ))
                }
            }
        } catch {
            // Ignore
        }

        // Mark currently connected network
        if let currentSSID = getCurrentSSID() {
            for i in networks.indices {
                if networks[i].ssid == currentSSID {
                    networks[i].isCurrentlyConnected = true
                    break
                }
            }
        }

        return networks
    }

    /// Get currently connected WiFi SSID
    static func getCurrentSSID() -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        return interface.ssid()
    }

    /// Remove a saved WiFi network
    static func removeNetwork(_ ssid: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-removepreferredwirelessnetwork", "en0", ssid]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NetworkError.removeNetworkFailed(ssid)
        }
    }

    /// Remove all saved networks except current
    static func removeAllExceptCurrent() throws {
        let current = getCurrentSSID()
        let networks = savedNetworks()

        for network in networks {
            if network.ssid != current {
                try? removeNetwork(network.ssid)
            }
        }
    }
}

struct SavedWiFiNetwork: Identifiable {
    let id = UUID()
    let ssid: String
    var isCurrentlyConnected: Bool
}

enum NetworkError: LocalizedError {
    case removeNetworkFailed(String)

    var errorDescription: String? {
        switch self {
        case .removeNetworkFailed(let ssid):
            return "Failed to remove network: \(ssid)"
        }
    }
}

// MARK: - SSH Known Hosts Management

struct SSHKnownHostsManager {
    private static var knownHostsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/known_hosts")
    }

    /// Get list of known hosts
    static func getKnownHosts() -> [SSHKnownHost] {
        guard let content = try? String(contentsOf: knownHostsPath, encoding: .utf8) else {
            return []
        }

        var hosts: [SSHKnownHost] = []

        for line in content.split(separator: "\n") {
            let lineStr = String(line)
            guard !lineStr.isEmpty, !lineStr.hasPrefix("#") else { continue }

            // Format: hostname algorithm key [comment]
            let parts = lineStr.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { continue }

            let hostPart = String(parts[0])
            let algorithm = String(parts[1])

            // Handle hashed hosts
            let displayHost: String
            if hostPart.hasPrefix("|1|") {
                displayHost = "[hashed]"
            } else {
                displayHost = hostPart.split(separator: ",").first.map(String.init) ?? hostPart
            }

            hosts.append(SSHKnownHost(
                host: displayHost,
                rawLine: lineStr,
                algorithm: algorithm,
                isHashed: hostPart.hasPrefix("|1|")
            ))
        }

        return hosts
    }

    /// Remove a specific host entry
    static func removeHost(_ host: SSHKnownHost) throws {
        guard var content = try? String(contentsOf: knownHostsPath, encoding: .utf8) else {
            return
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let filteredLines = lines.filter { String($0) != host.rawLine }
        content = filteredLines.joined(separator: "\n")

        try content.write(to: knownHostsPath, atomically: true, encoding: .utf8)
    }

    /// Clear all known hosts (creates backup)
    static func clearAll() throws {
        let backupPath = knownHostsPath.deletingLastPathComponent().appending(path: "known_hosts.backup")

        // Create backup
        try? FileManager.default.removeItem(at: backupPath)
        try FileManager.default.copyItem(at: knownHostsPath, to: backupPath)

        // Clear file
        try "".write(to: knownHostsPath, atomically: true, encoding: .utf8)
    }
}

struct SSHKnownHost: Identifiable {
    let id = UUID()
    let host: String
    let rawLine: String
    let algorithm: String
    let isHashed: Bool
}
