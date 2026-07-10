import SwiftUI

/// View for cleaning package manager caches
struct PackageManagersView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var cacheItems: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false
    @State private var dockerInfo: DockerInfo?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isScanning {
                scanningView
            } else if cacheItems.isEmpty && dockerInfo == nil {
                emptyState
            } else {
                contentView
            }

            if !cacheItems.isEmpty && !isScanning {
                Divider()
                footer
            }
        }
        .background(Color.clear)
        .task {
            await scan()
        }
        .errorAlert("Cleanup Failed", message: $errorMessage)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Package Managers & Docker")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Clean development caches and containers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await scan()
                }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .glassButton(prominent: true)
            .disabled(isScanning)
        }
        .padding()
        .background(MacSweepTheme.panelStrong)
    }

    // MARK: - Content View

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Package managers section
                if !cacheItems.isEmpty {
                    packageManagersSection
                }

                // Docker section
                if let docker = dockerInfo, docker.isInstalled {
                    dockerSection(docker)
                }
            }
            .padding()
        }
        .background(Color.clear)
    }

    private var packageManagersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Package Manager Caches")
                    .font(.headline)

                Spacer()

                Text(totalSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Group by package manager
            let grouped = Dictionary(grouping: cacheItems, by: { extractPackageManager(from: $0.moduleName) })

            ForEach(Array(grouped.keys.sorted()), id: \.self) { manager in
                PackageManagerCard(
                    name: manager,
                    items: grouped[manager] ?? [],
                    selectedItems: $selectedItems
                )
            }
        }
    }

    private func dockerSection(_ docker: DockerInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.blue)

                Text("Docker")
                    .font(.headline)

                Spacer()

                if docker.isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if docker.isRunning {
                HStack(spacing: 16) {
                    DockerStatCard(title: "Containers", value: "\(docker.containers)", icon: "cube.box")
                    DockerStatCard(title: "Images", value: "\(docker.images)", icon: "photo.stack")
                    DockerStatCard(title: "Volumes", value: "\(docker.volumes)", icon: "cylinder")
                }

                // Docker cleanup actions
                VStack(spacing: 8) {
                    DockerActionButton(
                        title: "Prune Containers",
                        description: "Remove stopped containers",
                        icon: "cube.box"
                    ) {
                        await runDockerAction("Prune Containers") {
                            try await DockerCleanupActions.pruneContainers()
                        }
                    }

                    DockerActionButton(
                        title: "Prune Images",
                        description: "Remove dangling images",
                        icon: "photo.stack"
                    ) {
                        await runDockerAction("Prune Images") {
                            try await DockerCleanupActions.pruneImages()
                        }
                    }

                    DockerActionButton(
                        title: "Prune Volumes",
                        description: "Remove unused volumes",
                        icon: "cylinder"
                    ) {
                        await runDockerAction("Prune Volumes") {
                            try await DockerCleanupActions.pruneVolumes()
                        }
                    }

                    DockerActionButton(
                        title: "Clear Build Cache",
                        description: "Remove all build cache",
                        icon: "hammer"
                    ) {
                        await runDockerAction("Clear Build Cache") {
                            try await DockerCleanupActions.pruneBuildCache()
                        }
                    }

                    DockerActionButton(
                        title: "System Prune",
                        description: "Remove all unused data",
                        icon: "trash",
                        isDestructive: true
                    ) {
                        await runDockerAction("System Prune") {
                            try await DockerCleanupActions.systemPrune(includeVolumes: true)
                        }
                    }
                }
            } else {
                Text("Start Docker Desktop to manage containers and images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .padding()
        .macSweepCard()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No Package Manager Caches Found")
                .font(.headline)

            Text("Scan to find npm, pip, cargo, and other caches")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Start Scan") {
                Task {
                    await scan()
                }
            }
            .glassButton(prominent: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning package managers...")
                .font(.headline)

            Text("Checking Homebrew, npm, pip, cargo, and more")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        CleanupFooter(
            selectedCount: selectedItems.count,
            summary: "Will free \(selectedSize)",
            onSelectAll: { selectedItems = Set(cacheItems.map(\.id)) },
            actionTitle: "Clean Selected",
            actionDisabled: selectedItems.isEmpty,
            onAction: { showingConfirmation = true },
            showsPanelBackground: true
        )
        .deleteConfirmation(
            "Clean \(selectedItems.count) Caches?",
            isPresented: $showingConfirmation,
            confirmTitle: "Clean",
            message: "This will delete \(selectedSize) of package manager caches. Packages will be re-downloaded as needed."
        ) {
            Task { await cleanSelected() }
        }
    }

    // MARK: - Actions

    private func scan() async {
        isScanning = true
        cacheItems = []
        selectedItems = []

        defer { isScanning = false }

        // Scan package managers
        let module = PackageManagerModule()
        cacheItems = (try? await module.scan()) ?? []

        // Get Docker info
        dockerInfo = await DockerInfo.current()
    }

    private func refreshDocker() async {
        dockerInfo = await DockerInfo.current()
    }

    /// Runs a Docker cleanup action and surfaces failures in the shared error
    /// alert instead of dropping them. The prune helpers signal failure via
    /// `itemsProcessed == 0` (e.g. Docker CLI missing or the daemon stopped)
    /// rather than throwing.
    private func runDockerAction(
        _ title: String,
        _ action: () async throws -> CleanupResult
    ) async {
        do {
            let result = try await action()
            if result.itemsProcessed == 0 {
                errorMessage = "\(title) failed. Check that Docker is running and try again."
            }
        } catch {
            errorMessage = "\(title) failed: \(error.localizedDescription)"
        }
        await refreshDocker()
    }

    private func cleanSelected() async {
        let itemsToClean = cacheItems.filter { selectedItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete.
        let engine = ScanEngine()
        var cleanupError: String?
        do {
            let result = try await engine.clean(items: itemsToClean, dryRun: false, confirmedLargeDeletion: true)
            cleanupError = result.failureSummaryMessage
        } catch {
            // Total failure (e.g. DeletionGuard cap): nothing was deleted.
            cleanupError = "Cleanup failed: \(error.localizedDescription)"
        }

        // Re-derive the list from disk (ground truth) instead of optimistically
        // removing items that may still be present after a throw/block.
        await scan()
        errorMessage = cleanupError
    }

    // MARK: - Helpers

    private func extractPackageManager(from moduleName: String) -> String {
        let parts = moduleName.split(separator: " ")
        return String(parts.first ?? "Other")
    }

    private var totalSize: String {
        cacheItems.formattedTotalSize()
    }

    private var selectedSize: String {
        cacheItems.formattedTotalSize(selected: selectedItems)
    }
}

// MARK: - Package Manager Card

struct PackageManagerCard: View {
    let name: String
    let items: [CleanupItem]
    @Binding var selectedItems: Set<UUID>

    private var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    private var allSelected: Bool {
        items.allSatisfy { selectedItems.contains($0.id) }
    }

    private var icon: String {
        switch name.lowercased() {
        case "homebrew": return "cup.and.saucer"
        case "npm": return "cube.box"
        case "yarn": return "cube.box.fill"
        case "pnpm": return "shippingbox"
        case "bun": return "bolt"
        case "pip", "pipx": return "cube"
        case "cargo": return "gearshape.2"
        case "go": return "figure.run"
        case "composer": return "music.note"
        case "rubygems": return "diamond"
        case "cocoapods": return "leaf"
        case "carthage": return "cart"
        case "gradle": return "elephant"
        case "maven": return "m.circle"
        default: return "shippingbox"
        }
    }

    private var color: Color {
        switch name.lowercased() {
        case "homebrew": return .orange
        case "npm": return .red
        case "yarn": return .blue
        case "pnpm": return .yellow
        case "bun": return .pink
        case "pip", "pipx": return .blue
        case "cargo": return .orange
        case "go": return .cyan
        case "rubygems": return .red
        case "cocoapods": return .red
        case "carthage": return .blue
        case "gradle": return .green
        case "maven": return .red
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            Button {
                toggleAll()
            } label: {
                HStack {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(allSelected ? MacSweepTheme.selection : .secondary)

                    Image(systemName: icon)
                        .foregroundStyle(color)

                    Text(name)
                        .font(.headline)

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Items
            ForEach(items) { item in
                Button {
                    toggleItem(item)
                } label: {
                    HStack {
                        Image(systemName: selectedItems.contains(item.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedItems.contains(item.id) ? MacSweepTheme.selection : .secondary)
                            .font(.caption)

                        Text(item.moduleName.replacingOccurrences(of: "\(name) ", with: ""))
                            .font(.caption)

                        Spacer()

                        Text(item.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .macSweepCard()
    }

    private func toggleAll() {
        if allSelected {
            for item in items {
                selectedItems.remove(item.id)
            }
        } else {
            for item in items {
                selectedItems.insert(item.id)
            }
        }
    }

    private func toggleItem(_ item: CleanupItem) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
    }
}

// MARK: - Docker Stat Card

struct DockerStatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)

            Text(value)
                .font(.title)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .macSweepCard(radius: MacSweepTheme.smallRadius)
    }
}

// MARK: - Docker Action Button

struct DockerActionButton: View {
    let title: String
    let description: String
    let icon: String
    var isDestructive: Bool = false
    let action: () async -> Void

    @State private var isLoading = false

    var body: some View {
        Button {
            Task {
                isLoading = true
                await action()
                isLoading = false
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .macSweepCard(radius: MacSweepTheme.smallRadius)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDestructive ? .red : .primary)
        .disabled(isLoading)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    PackageManagersView()
        .environmentObject(AppState())
        .frame(width: 700, height: 600)
}

#endif
