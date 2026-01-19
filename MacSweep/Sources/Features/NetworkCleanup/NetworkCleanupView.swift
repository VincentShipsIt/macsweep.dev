import SwiftUI
import CoreWLAN

/// View for managing network cleanup operations
struct NetworkCleanupView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: NetworkTab = .wifi

    enum NetworkTab: String, CaseIterable {
        case wifi = "WiFi Networks"
        case ssh = "SSH Hosts"
        case dns = "DNS & Cache"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(NetworkTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Tab content
            switch selectedTab {
            case .wifi:
                WiFiNetworksView()
            case .ssh:
                SSHHostsView()
            case .dns:
                DNSCacheView()
            }
        }
    }
}

// MARK: - WiFi Networks View

struct WiFiNetworksView: View {
    @State private var networks: [SavedWiFiNetwork] = []
    @State private var selectedNetworks: Set<UUID> = []
    @State private var isLoading = false
    @State private var showingConfirmation = false
    @State private var currentSSID: String?
    @State private var protectedSSIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                loadingView
            } else if networks.isEmpty {
                emptyState
            } else {
                networksList
            }

            if !networks.isEmpty && !isLoading {
                Divider()
                footer
            }
        }
        .task {
            await loadNetworks()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved WiFi Networks")
                    .font(.title2)
                    .fontWeight(.semibold)

                if let current = currentSSID {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .foregroundStyle(.green)
                        Text("Connected to \(current)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                Task {
                    await loadNetworks()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
        .padding()
    }

    // MARK: - Networks List

    private var networksList: some View {
        List(selection: $selectedNetworks) {
            ForEach(networks) { network in
                NetworkRow(
                    network: network,
                    isSelected: selectedNetworks.contains(network.id),
                    isProtected: protectedSSIDs.contains(network.ssid),
                    onToggleProtection: {
                        toggleProtection(network)
                    }
                )
                .tag(network.id)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Saved Networks")
                .font(.headline)

            Text("No saved WiFi networks were found on this system.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Loading saved networks...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedNetworks.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if selectedNetworks.count > 0 && containsCurrentNetwork {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("Includes current network")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button("Select All Except Current") {
                selectAllExceptCurrent()
            }
            .buttonStyle(.bordered)

            Button("Remove Selected") {
                showingConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedNetworks.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Remove \(selectedNetworks.count) networks?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Networks", role: .destructive) {
                Task {
                    await removeSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if containsCurrentNetwork {
                Text("Warning: You are about to remove the currently connected network. You may lose your connection.")
            } else {
                Text("These networks will be removed from your saved networks list. You can reconnect to them later if needed.")
            }
        }
    }

    // MARK: - Actions

    private func loadNetworks() async {
        isLoading = true
        defer { isLoading = false }

        currentSSID = WiFiNetworkManager.getCurrentSSID()
        networks = WiFiNetworkManager.savedNetworks()
    }

    private func toggleProtection(_ network: SavedWiFiNetwork) {
        if protectedSSIDs.contains(network.ssid) {
            protectedSSIDs.remove(network.ssid)
        } else {
            protectedSSIDs.insert(network.ssid)
            selectedNetworks.remove(network.id)
        }
    }

    private func selectAllExceptCurrent() {
        selectedNetworks = Set(
            networks
                .filter { !$0.isCurrentlyConnected && !protectedSSIDs.contains($0.ssid) }
                .map(\.id)
        )
    }

    private func removeSelected() async {
        let ssidsToRemove = networks
            .filter { selectedNetworks.contains($0.id) }
            .map(\.ssid)

        for ssid in ssidsToRemove {
            try? WiFiNetworkManager.removeNetwork(ssid)
        }

        selectedNetworks.removeAll()
        await loadNetworks()
    }

    private var containsCurrentNetwork: Bool {
        networks.first { $0.isCurrentlyConnected && selectedNetworks.contains($0.id) } != nil
    }
}

// MARK: - Network Row

struct NetworkRow: View {
    let network: SavedWiFiNetwork
    let isSelected: Bool
    let isProtected: Bool
    let onToggleProtection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            // WiFi icon
            Image(systemName: network.isCurrentlyConnected ? "wifi" : "wifi.slash")
                .font(.title3)
                .foregroundStyle(network.isCurrentlyConnected ? .green : .secondary)
                .frame(width: 24)

            // Network info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(network.ssid)
                        .font(.body)

                    if network.isCurrentlyConnected {
                        Text("Connected")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }

                    if isProtected {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Protected - won't be removed")
                    }
                }
            }

            Spacer()

            // Protection toggle
            Button {
                onToggleProtection()
            } label: {
                Image(systemName: isProtected ? "lock.fill" : "lock.open")
                    .foregroundStyle(isProtected ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(isProtected ? "Unprotect network" : "Protect network from removal")
        }
        .padding(.vertical, 4)
        .opacity(isProtected ? 0.7 : 1)
    }
}

// MARK: - SSH Hosts View

struct SSHHostsView: View {
    @State private var hosts: [SSHKnownHost] = []
    @State private var selectedHosts: Set<UUID> = []
    @State private var isLoading = false
    @State private var showingConfirmation = false
    @State private var showingClearAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                loadingView
            } else if hosts.isEmpty {
                emptyState
            } else {
                hostsList
            }

            if !hosts.isEmpty && !isLoading {
                Divider()
                footer
            }
        }
        .task {
            loadHosts()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH Known Hosts")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("\(hosts.count) entries in ~/.ssh/known_hosts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    loadHosts()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }

            // Security warning
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)

                Text("Removing SSH known hosts can expose you to man-in-the-middle attacks. Only remove hosts you no longer connect to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }

    // MARK: - Hosts List

    private var hostsList: some View {
        List(selection: $selectedHosts) {
            ForEach(hosts) { host in
                SSHHostRow(host: host, isSelected: selectedHosts.contains(host.id))
                    .tag(host.id)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No SSH Known Hosts")
                .font(.headline)

            Text("Your ~/.ssh/known_hosts file is empty or doesn't exist.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Loading SSH hosts...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(selectedHosts.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Select All") {
                selectedHosts = Set(hosts.map(\.id))
            }
            .buttonStyle(.bordered)

            Button("Clear All Hosts") {
                showingClearAllConfirmation = true
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Button("Remove Selected") {
                showingConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedHosts.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Remove \(selectedHosts.count) SSH hosts?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Hosts", role: .destructive) {
                removeSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These hosts will be removed from your known_hosts file. You will need to verify their fingerprints again when reconnecting.")
        }
        .confirmationDialog(
            "Clear all SSH known hosts?",
            isPresented: $showingClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All (Backup Created)", role: .destructive) {
                clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove ALL known SSH hosts. A backup will be created at ~/.ssh/known_hosts.backup. You will need to verify fingerprints for all hosts.")
        }
    }

    // MARK: - Actions

    private func loadHosts() {
        isLoading = true
        defer { isLoading = false }

        hosts = SSHKnownHostsManager.getKnownHosts()
    }

    private func removeSelected() {
        let hostsToRemove = hosts.filter { selectedHosts.contains($0.id) }
        for host in hostsToRemove {
            try? SSHKnownHostsManager.removeHost(host)
        }
        selectedHosts.removeAll()
        loadHosts()
    }

    private func clearAll() {
        try? SSHKnownHostsManager.clearAll()
        selectedHosts.removeAll()
        loadHosts()
    }
}

// MARK: - SSH Host Row

struct SSHHostRow: View {
    let host: SSHKnownHost
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.host)
                    .font(.body)
                    .fontDesign(.monospaced)

                HStack(spacing: 8) {
                    Text(host.algorithm)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.2), in: Capsule())
                        .foregroundStyle(.blue)

                    if host.isHashed {
                        Text("Hashed")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - DNS Cache View

struct DNSCacheView: View {
    @State private var isFlushingDNS = false
    @State private var flushResult: FlushResult?
    @State private var cacheItems: [CleanupItem] = []
    @State private var isScanning = false

    enum FlushResult {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    dnsFlushSection
                    networkCacheSection
                }
                .padding()
            }
        }
        .task {
            await scanCaches()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("DNS & Network Cache")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    Task {
                        await scanCaches()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isScanning)
            }

            Text("Flush DNS cache and clear network-related caches")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - DNS Flush Section

    private var dnsFlushSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("DNS Cache")
                        .font(.headline)

                    Text("Flush the system DNS cache to resolve connectivity issues")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        await flushDNS()
                    }
                } label: {
                    if isFlushingDNS {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 100)
                    } else {
                        Text("Flush DNS")
                            .frame(width: 100)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFlushingDNS)
            }

            // Result indicator
            if let result = flushResult {
                switch result {
                case .success:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("DNS cache flushed successfully")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                case .failure(let message):
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Info box
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)

                Text("Flushing DNS cache requires administrator privileges. You will be prompted for your password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Network Cache Section

    private var networkCacheSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Network Caches")
                        .font(.headline)

                    Text("Cached network data and preferences")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if isScanning {
                HStack {
                    ProgressView()
                    Text("Scanning...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if cacheItems.isEmpty {
                Text("No cleanable network caches found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical)
            } else {
                ForEach(cacheItems) { item in
                    NetworkCacheRow(item: item)
                }

                HStack {
                    Text("Total: \(totalCacheSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("These caches can be cleaned from the main System Junk scan")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func flushDNS() async {
        isFlushingDNS = true
        flushResult = nil

        defer { isFlushingDNS = false }

        do {
            try await DNSCacheManager.flush()
            flushResult = .success
        } catch {
            flushResult = .failure(error.localizedDescription)
        }
    }

    private func scanCaches() async {
        isScanning = true
        defer { isScanning = false }

        let module = NetworkModule()
        cacheItems = (try? await module.scan()) ?? []
    }

    private var totalCacheSize: String {
        let total = cacheItems.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Network Cache Row

struct NetworkCacheRow: View {
    let item: CleanupItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.type == .directory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body)

                Text(item.path.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            Text(item.formattedSize)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NetworkCleanupView()
        .environmentObject(AppState())
        .frame(width: 700, height: 600)
}
