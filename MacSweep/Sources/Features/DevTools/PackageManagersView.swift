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
    @State private var pendingDockerAction: DockerReviewAction?

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
        .cleanupReview(
            isPresented: Binding(
                get: { pendingDockerAction != nil },
                set: { if !$0 { pendingDockerAction = nil } }
            ),
            items: [],
            disposition: .toolNative(
                pendingDockerAction?.detail ?? "Docker performs this cleanup using its own prune command."
            ),
            additionalCount: pendingDockerAction == nil ? 0 : 1,
            additionalBytes: pendingDockerAction?.estimatedBytes(from: dockerInfo),
            additionalModules: pendingDockerAction == nil ? [] : ["Docker"],
            additionalPaths: pendingDockerAction.map { [$0.presentationURL] } ?? [],
            onConfirm: { await runPendingDockerAction() }
        )
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
                        pendingDockerAction = .containers
                    }

                    DockerActionButton(
                        title: "Prune Images",
                        description: "Remove dangling images",
                        icon: "photo.stack"
                    ) {
                        pendingDockerAction = .images
                    }

                    DockerActionButton(
                        title: "Prune Volumes",
                        description: "Remove unused volumes",
                        icon: "cylinder"
                    ) {
                        pendingDockerAction = .volumes
                    }

                    DockerActionButton(
                        title: "Clear Build Cache",
                        description: "Remove all build cache",
                        icon: "hammer"
                    ) {
                        pendingDockerAction = .buildCache
                    }

                    DockerActionButton(
                        title: "System Prune",
                        description: "Remove all unused data",
                        icon: "trash",
                        isDestructive: true
                    ) {
                        pendingDockerAction = .system
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
        .cleanupReview(
            isPresented: $showingConfirmation,
            items: selectedCacheItems,
            disposition: .permanent,
            note: "Package manager caches are deleted permanently. "
                + "Required packages will be downloaded again on demand.",
            onConfirm: { await cleanSelected() }
        )
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
    private func runPendingDockerAction() async -> CleanupResult? {
        guard let pendingDockerAction else { return nil }
        do {
            let result = try await pendingDockerAction.run()
            if result.itemsProcessed == 0 {
                let message = "\(pendingDockerAction.title) failed. Check that Docker is running and try again."
                errorMessage = message
                await refreshDocker()
                return CleanupResult(
                    itemsProcessed: 0,
                    bytesFreed: 0,
                    errors: [CleanupError(path: pendingDockerAction.presentationURL, message: message)]
                )
            }
            errorMessage = nil
            await refreshDocker()
            return result
        } catch {
            errorMessage = "\(pendingDockerAction.title) failed: \(error.localizedDescription)"
            await refreshDocker()
            return nil
        }
    }

    private func cleanSelected() async -> CleanupResult? {
        let itemsToClean = selectedCacheItems

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete.
        let engine = ScanEngine()
        var cleanupError: String?
        var cleanupResult: CleanupResult?
        do {
            let result = try await engine.clean(items: itemsToClean, dryRun: false, confirmedLargeDeletion: true)
            cleanupResult = result
            cleanupError = result.failureSummaryMessage
        } catch {
            // Total failure (e.g. DeletionGuard cap): nothing was deleted.
            cleanupError = "Cleanup failed: \(error.localizedDescription)"
        }

        // Re-derive the list from disk (ground truth) instead of optimistically
        // removing items that may still be present after a throw/block.
        await scan()
        errorMessage = cleanupError
        return cleanupResult
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

    private var selectedCacheItems: [CleanupItem] {
        cacheItems.filter { selectedItems.contains($0.id) }
    }
}

private enum DockerReviewAction: String, Identifiable {
    case containers
    case images
    case volumes
    case buildCache
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Prune Containers"
        case .images: return "Prune Images"
        case .volumes: return "Prune Volumes"
        case .buildCache: return "Clear Build Cache"
        case .system: return "System Prune"
        }
    }

    var detail: String {
        switch self {
        case .containers:
            return "Runs Docker's container prune command to remove stopped containers. "
                + "MacSweep does not delete Docker storage files directly."
        case .images:
            return "Runs Docker's image prune command to remove dangling images. "
                + "MacSweep does not delete Docker storage files directly."
        case .volumes:
            return "Runs Docker's volume prune command. Unused volume data is permanently removed by Docker."
        case .buildCache:
            return "Runs Docker's builder prune command. Build cache is permanently removed and may need to be rebuilt."
        case .system:
            return "Runs Docker system prune with volumes. Docker permanently removes all unused containers, "
                + "networks, images, build cache, and volumes."
        }
    }

    var presentationURL: URL {
        URL(string: "macsweep-action://docker/\(rawValue)")!
    }

    func estimatedBytes(from info: DockerInfo?) -> Int64? {
        let estimate: Int64
        switch self {
        case .buildCache: estimate = info?.buildCacheSize ?? 0
        case .system: estimate = info?.totalSize ?? 0
        case .containers, .images, .volumes: return nil
        }
        return estimate > 0 ? estimate : nil
    }

    func run() async throws -> CleanupResult {
        switch self {
        case .containers: return try await DockerCleanupActions.pruneContainers()
        case .images: return try await DockerCleanupActions.pruneImages()
        case .volumes: return try await DockerCleanupActions.pruneVolumes()
        case .buildCache: return try await DockerCleanupActions.pruneBuildCache()
        case .system: return try await DockerCleanupActions.systemPrune(includeVolumes: true)
        }
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
