import Foundation
import CoreWLAN
import SystemConfiguration

/// Module for cleaning network-related data
struct NetworkModule: ScanModule {
    let id = "network"
    let name = "Network"
    let description = "Clean WiFi networks, SSH keys, DNS cache, and network caches"
    let icon = "network"

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Network service proxy cache — a true regenerable cache living under
        // ~/Library/Caches. This is the only thing this module sweeps.
        //
        // Deliberately NOT scanned (these are security/correctness hazards, not
        // disk space, and a cleaner must never touch them automatically):
        //   • ~/.ssh/known_hosts[.old] — host-key pinning state. Wiping it
        //     silently re-trusts every host on the next connection (MITM
        //     exposure). ~/.ssh is in neverDelete; deliberate per-host edits
        //     live in SSHKnownHostsManager, a user-initiated path.
        //   • /var/db/mds/messages — this is the Spotlight metadata server's
        //     state directory, NOT a "Bonjour cache". It is root-owned and
        //     deleting it can corrupt Spotlight indexing.
        //   • ~/Library/Preferences/com.apple.networkextension.cache.plist —
        //     sits under the protected Preferences root; it is a tiny plist and
        //     not worth the risk surface of an explicit carve-out.
        items.append(contentsOf: await scanNetworkServiceProxy())

        return items.sorted { $0.size > $1.size }
    }

    // MARK: - Network Service Proxy Cache

    private func scanNetworkServiceProxy() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let cacheDir = URL.libraryDirectory.appending(path: "Caches/com.apple.networkserviceproxy")
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: cacheDir)) ?? 0
            if size > 1024 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: cacheDir,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Network Service Proxy Cache"
                ))
            }
        }

        return items
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(items, dryRun: dryRun) { item, _ in
            try CleanupFileRemover.permanent(item.path)
        }
    }
}

// MARK: - WiFi Network Management

struct WiFiNetworkManager {
    /// Get the WiFi interface to use
    private static var wifiInterface: String {
        WiFiInterfaceManager.primaryInterface()
    }

    /// Get list of saved WiFi networks on the primary interface.
    /// Delegates to `savedNetworks(interface:)` so there is a single
    /// implementation of the drain-then-reap subprocess handling.
    static func savedNetworks() -> [SavedWiFiNetwork] {
        savedNetworks(interface: wifiInterface)
    }

    /// Get list of saved WiFi networks for a specific interface
    static func savedNetworks(interface: String) -> [SavedWiFiNetwork] {
        var networks: [SavedWiFiNetwork] = []

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listpreferredwirelessnetworks", interface]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Drain the pipe before reaping: reading first guarantees the child
            // can't wedge on a full pipe buffer while we block in waitUntilExit.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            let lines = output.split(separator: "\n").dropFirst()
            for line in lines {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    networks.append(SavedWiFiNetwork(
                        ssid: name,
                        isCurrentlyConnected: false
                    ))
                }
            }
        } catch {
            // Ignore
        }

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

    /// Get current connection security type
    static func getCurrentSecurityType() -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        return securityTypeString(interface.security())
    }

    /// Convert CWSecurity enum to readable string
    private static func securityTypeString(_ security: CWSecurity) -> String {
        switch security {
        case .none: return "None"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA Personal Mixed"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA Enterprise Mixed"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA3 Transition"
        case .OWE: return "Enhanced Open (OWE)"
        case .oweTransition: return "Enhanced Open Transition"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    /// Remove a saved WiFi network
    static func removeNetwork(_ ssid: String) throws {
        try removeNetwork(ssid, interface: wifiInterface)
    }

    /// Remove a saved WiFi network from a specific interface
    static func removeNetwork(_ ssid: String, interface: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-removepreferredwirelessnetwork", interface, ssid]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NetworkError.removeNetworkFailed(ssid)
        }
    }

    /// Remove multiple networks
    static func removeNetworks(_ ssids: [String]) throws {
        for ssid in ssids {
            try removeNetwork(ssid)
        }
    }

    /// Remove all saved networks except current and protected
    static func removeAllExceptCurrent(protectedSSIDs: Set<String> = []) throws {
        let current = getCurrentSSID()
        let networks = savedNetworks()

        for network in networks {
            if network.ssid != current && !protectedSSIDs.contains(network.ssid) {
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

// MARK: - DNS Cache Manager

struct DNSCacheManager {
    /// Check if we can flush DNS
    static var canFlush: Bool {
        return FileManager.default.fileExists(atPath: "/usr/bin/dscacheutil")
    }

    /// Flush the DNS cache
    /// Note: Full DNS flush (mDNSResponder restart) requires admin privileges.
    /// This method performs a partial flush that doesn't require elevation.
    static func flush() async throws {
        // First, try dscacheutil which doesn't require admin
        let dscacheutil = Process()
        dscacheutil.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        dscacheutil.arguments = ["-flushcache"]
        dscacheutil.standardOutput = FileHandle.nullDevice
        dscacheutil.standardError = FileHandle.nullDevice

        do {
            try dscacheutil.run()
            dscacheutil.waitUntilExit()

            if dscacheutil.terminationStatus != 0 {
                throw DNSError.flushFailed
            }
        } catch {
            throw DNSError.flushFailed
        }

        // Note: killall -HUP mDNSResponder requires root/admin privileges
        // and cannot be done from a sandboxed app without user elevation.
        // The dscacheutil flush above handles most DNS cache clearing needs.
    }

    /// Flush DNS with admin privileges (prompts user)
    /// Note: May not work in sandboxed apps
    static func flushWithAdmin() async throws {
        let script = """
        do shell script "dscacheutil -flushcache; killall -HUP mDNSResponder" with administrator privileges
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                throw DNSError.flushFailed
            }
        } catch {
            throw DNSError.flushFailed
        }
    }
}

enum DNSError: LocalizedError {
    case flushFailed

    var errorDescription: String? {
        switch self {
        case .flushFailed:
            return "Failed to flush DNS cache"
        }
    }
}

// MARK: - WiFi Interface Manager

struct WiFiInterfaceManager {
    /// Get all available WiFi interfaces
    static func availableInterfaces() -> [String] {
        var interfaces: [String] = []

        // Use networksetup to list hardware ports
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return ["en0"] }

            // Parse output to find WiFi interfaces
            let lines = output.split(separator: "\n")
            var isWiFi = false

            for line in lines {
                let lineStr = String(line)
                if lineStr.contains("Wi-Fi") || lineStr.contains("AirPort") {
                    isWiFi = true
                } else if isWiFi && lineStr.hasPrefix("Device:") {
                    let device = lineStr.replacingOccurrences(of: "Device: ", with: "").trimmingCharacters(in: .whitespaces)
                    interfaces.append(device)
                    isWiFi = false
                } else if lineStr.hasPrefix("Hardware Port:") {
                    isWiFi = false
                }
            }
        } catch {
            // Default to en0 if detection fails
        }

        return interfaces.isEmpty ? ["en0"] : interfaces
    }

    /// Get the primary WiFi interface
    static func primaryInterface() -> String {
        // Try CoreWLAN first
        if let interface = CWWiFiClient.shared().interface() {
            return interface.interfaceName ?? "en0"
        }

        // Fall back to first available
        return availableInterfaces().first ?? "en0"
    }

    /// Check if WiFi is enabled
    static var isWiFiEnabled: Bool {
        guard let interface = CWWiFiClient.shared().interface() else { return false }
        return interface.powerOn()
    }

    /// Get current WiFi info
    static func currentNetworkInfo() -> (ssid: String?, bssid: String?, rssi: Int?) {
        guard let interface = CWWiFiClient.shared().interface() else {
            return (nil, nil, nil)
        }
        return (interface.ssid(), interface.bssid(), interface.rssiValue())
    }
}

// MARK: - Network Cleanup Summary

struct NetworkCleanupSummary {
    var savedNetworks: Int = 0
    var knownHosts: Int = 0
    var cacheSize: Int64 = 0
    var canFlushDNS: Bool = true

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }

    static func current() async -> NetworkCleanupSummary {
        var summary = NetworkCleanupSummary()

        // Count saved WiFi networks
        summary.savedNetworks = WiFiNetworkManager.savedNetworks().count

        // Count SSH known hosts
        summary.knownHosts = SSHKnownHostsManager.getKnownHosts().count

        // Calculate total cache size
        let networkCachePaths: [URL] = [
            URL.libraryDirectory.appending(path: "Caches/com.apple.networkserviceproxy"),
            URL.libraryDirectory.appending(path: "Preferences/com.apple.networkextension.cache.plist")
        ]

        for path in networkCachePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                let size = (try? await DiskAnalyzer.size(of: path)) ?? 0
                summary.cacheSize += size
            }
        }

        return summary
    }
}
