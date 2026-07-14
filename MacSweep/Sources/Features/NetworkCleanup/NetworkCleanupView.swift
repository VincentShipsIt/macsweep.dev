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
        FeaturePageShell(
            title: "Network Cleanup",
            subtitle: "Manage saved Wi-Fi, SSH hosts, and DNS caches."
        ) {
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
}

// MARK: - WiFi Networks View

struct WiFiNetworksView: View {
    @State private var networks: [SavedWiFiNetwork] = []
    @State private var selectedNetworks: Set<UUID> = []
    @State private var isLoading = false
    @State private var showingConfirmation = false
    @State private var currentSSID: String?
    @State private var protectedSSIDs: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                MacSweepErrorBanner(message: errorMessage) {
                    self.errorMessage = nil
                }
            }
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
            .glassButton()
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
        .macSweepListSurface()
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
            .glassButton()

            Button("Remove Selected") {
                showingConfirmation = true
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(selectedNetworks.isEmpty)
        }
        .padding()
        .deleteConfirmation(
            "Remove \(selectedNetworks.count) networks?",
            isPresented: $showingConfirmation,
            confirmTitle: "Remove Networks",
            message: removalMessage
        ) {
            Task { await removeSelected() }
        }
    }

    private var removalMessage: String {
        if containsCurrentNetwork {
            return "Warning: You are about to remove the currently connected network. You may lose your connection."
        }
        return "These networks will be removed from your saved networks list. You can reconnect to them later if needed."
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

        var failed: [String] = []
        for ssid in ssidsToRemove {
            do {
                try WiFiNetworkManager.removeNetwork(ssid)
            } catch {
                failed.append(ssid)
            }
        }

        selectedNetworks.removeAll()
        await loadNetworks()

        if failed.isEmpty {
            errorMessage = nil
        } else {
            errorMessage = "Couldn't remove: \(failed.joined(separator: ", ")). Removing saved networks requires administrator privileges."
        }
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
        SelectableItemRow(isSelected: isSelected) {
            // WiFi icon
            Image(systemName: network.isCurrentlyConnected ? "wifi" : "wifi.slash")
                .font(.title3)
                .foregroundStyle(network.isCurrentlyConnected ? .green : .secondary)
                .frame(width: 24)
        } content: {
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
        } trailing: {
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
        .opacity(isProtected ? 0.7 : 1)
    }
}

// MARK: - SSH Hosts View

struct SSHHostsView: View {
    /// One coherent confirmation flow for the two SSH destructive actions. Two
    /// stacked `.deleteConfirmation` modifiers on the same view are fragile (SwiftUI
    /// presents only one presentation modifier of a kind reliably); a single
    /// optional-driven modifier makes the two actions mutually exclusive by
    /// construction and routes both through the shared confirmation UI.
    private enum PendingDeletion: Equatable {
        case removeSelected(count: Int)
        case clearAll

        var title: String {
            switch self {
            case .removeSelected(let count): return "Remove \(count) SSH hosts?"
            case .clearAll: return "Clear all SSH known hosts?"
            }
        }

        var confirmTitle: String {
            switch self {
            case .removeSelected: return "Remove Hosts"
            case .clearAll: return "Clear All (Backup Created)"
            }
        }

        var message: String {
            switch self {
            case .removeSelected:
                return "These hosts will be removed from your known_hosts file. "
                    + "You will need to verify their fingerprints again when reconnecting."
            case .clearAll:
                return "This will remove ALL known SSH hosts. A backup will be created at "
                    + "~/.ssh/known_hosts.backup. You will need to verify fingerprints for all hosts."
            }
        }
    }

    @State private var hosts: [SSHKnownHost] = []
    @State private var selectedHosts: Set<UUID> = []
    @State private var isLoading = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                MacSweepErrorBanner(message: errorMessage) {
                    self.errorMessage = nil
                }
            }
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
            await loadHosts()
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
                    Task { await loadHosts() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .glassButton()
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
        .macSweepListSurface()
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
            .glassButton()

            Button("Clear All Hosts") {
                pendingDeletion = .clearAll
            }
            .glassButton()

            Button("Remove Selected") {
                pendingDeletion = .removeSelected(count: selectedHosts.count)
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(selectedHosts.isEmpty)
        }
        .padding()
        .deleteConfirmation(
            pendingDeletion?.title ?? "",
            isPresented: $pendingDeletion.isPresent(),
            confirmTitle: pendingDeletion?.confirmTitle ?? "",
            message: pendingDeletion?.message ?? ""
        ) {
            // Each action still routes to its own handler; SafetyChecker-equivalent
            // guards inside SSHKnownHostsManager (backup on clear-all) are untouched.
            switch pendingDeletion {
            case .removeSelected:
                removeSelected()
            case .clearAll:
                clearAll()
            case .none:
                break
            }
        }
    }

    // MARK: - Actions

    private func loadHosts() async {
        isLoading = true
        defer { isLoading = false }

        // Read/parse ~/.ssh/known_hosts off the main actor so the spinner can
        // actually render and the UI doesn't block on the file read.
        hosts = await Task.detached(priority: .userInitiated) {
            SSHKnownHostsManager.getKnownHosts()
        }.value
    }

    private func removeSelected() {
        let hostsToRemove = hosts.filter { selectedHosts.contains($0.id) }
        var failed = 0
        for host in hostsToRemove {
            do {
                try SSHKnownHostsManager.removeHost(host)
            } catch {
                failed += 1
            }
        }
        selectedHosts.removeAll()
        Task { await loadHosts() }
        errorMessage = failed == 0
            ? nil
            : "Couldn't remove \(failed) host\(failed == 1 ? "" : "s") from known_hosts."
    }

    private func clearAll() {
        do {
            try SSHKnownHostsManager.clearAll()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't clear known_hosts: \(error.localizedDescription)"
        }
        selectedHosts.removeAll()
        Task { await loadHosts() }
    }
}

// MARK: - SSH Host Row

struct SSHHostRow: View {
    let host: SSHKnownHost
    let isSelected: Bool

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
        } content: {
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
        } trailing: {
            EmptyView()
        }
    }
}

// MARK: - DNS Cache View

struct DNSCacheView: View {
    @State private var isFlushingDNS = false
    @State private var didFlushDNS = false
    @State private var flushErrorMessage: String?
    @State private var cacheItems: [CleanupItem] = []
    @State private var isScanning = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // Inline banner is the default non-blocking error surface, matching the
            // WiFi and SSH tabs; a failed DNS flush leaves the page usable.
            if let flushErrorMessage {
                MacSweepErrorBanner(message: flushErrorMessage) {
                    self.flushErrorMessage = nil
                }
            }

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
                .glassButton()
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
                .glassButton(prominent: true)
                .disabled(isFlushingDNS)
            }

            // Result indicator (failures surface in the shared error alert)
            if didFlushDNS {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("DNS cache flushed successfully")
                        .font(.caption)
                        .foregroundStyle(.green)
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
        didFlushDNS = false
        flushErrorMessage = nil

        defer { isFlushingDNS = false }

        do {
            try await DNSCacheManager.flush()
            didFlushDNS = true
        } catch {
            flushErrorMessage = error.localizedDescription
        }
    }

    private func scanCaches() async {
        isScanning = true
        defer { isScanning = false }

        let module = NetworkModule()
        cacheItems = (try? await module.scan()) ?? []
    }

    private var totalCacheSize: String {
        cacheItems.formattedTotalSize()
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

#if !SWIFT_PACKAGE
#Preview {
    NetworkCleanupView()
        .environmentObject(AppState())
        .frame(width: 700, height: 600)
}

#endif
