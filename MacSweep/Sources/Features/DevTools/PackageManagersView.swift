import SwiftUI

/// View for cleaning package manager caches
struct PackageManagersView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var cacheItems: [CleanupItem] = []
    @State private var dockerItems: [CleanupItem] = []
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
            } else if cacheItems.isEmpty && dockerItems.isEmpty && dockerInfo?.isInstalled != true {
                emptyState
            } else {
                contentView
            }

            if !allCleanupItems.isEmpty && !isScanning {
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

                Text("Review cache folders and exact Docker prune commands before cleaning")
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
            DockerStatusLabel(isRunning: docker.isRunning)

            if docker.isRunning {
                HStack(spacing: 16) {
                    DockerStatCard(title: "Containers", value: "\(docker.containers)", icon: "cube.box")
                    DockerStatCard(title: "Images", value: "\(docker.images)", icon: "photo.stack")
                    DockerStatCard(title: "Volumes", value: "\(docker.volumes)", icon: "cylinder")
                }

                if dockerItems.isEmpty {
                    Text("Docker reports no reclaimable containers, images, volumes, or build cache.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 8) {
                        ForEach(dockerItems) { item in
                            DockerCleanupRow(
                                item: item,
                                isSelected: selectedItems.contains(item.id),
                                onToggle: { toggleItem(item) }
                            )
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

            Text("No Developer Caches Found")
                .font(.headline)

            Text("No package manager caches or Docker cleanup targets were found")
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

            Text("Scanning developer caches...")
                .font(.headline)

            Text("Checking Homebrew, npm, pip, cargo, Docker, and more")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        CleanupFooter(
            selectedCount: selectedItems.count,
            summary: "Will reclaim \(selectedSize)",
            onSelectAll: { selectedItems = Set(allCleanupItems.map(\.id)) },
            actionTitle: "Clean Selected",
            actionDisabled: selectedItems.isEmpty,
            onAction: { showingConfirmation = true }
        )
        .cleanupReview(
            isPresented: $showingConfirmation,
            items: selectedCleanupItems,
            disposition: .mixed,
            note: cleanConfirmationMessage,
            onConfirm: { await cleanSelected() }
        )
    }

    // MARK: - Actions

    private func scan() async {
        isScanning = true
        cacheItems = []
        dockerItems = []
        selectedItems = []
        errorMessage = nil

        defer { isScanning = false }

        async let cacheScan = PackageManagerModule().scan()
        async let dockerScan = DockerModule().scan()
        async let currentDockerInfo = DockerInfo.current()

        cacheItems = (try? await cacheScan) ?? []
        dockerItems = ((try? await dockerScan) ?? []).filter {
            if case .action(.docker) = $0.target { return true }
            return false
        }
        dockerInfo = await currentDockerInfo
    }

    private func cleanSelected() async -> CleanupResult? {
        let itemsToClean = selectedCleanupItems

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
}

// MARK: - Helpers

private extension PackageManagersView {

    private func extractPackageManager(from moduleName: String) -> String {
        let parts = moduleName.split(separator: " ")
        return String(parts.first ?? "Other")
    }

    private var totalSize: String {
        cacheItems.formattedTotalSize()
    }

    private var allCleanupItems: [CleanupItem] {
        cacheItems + dockerItems
    }

    private var selectedSize: String {
        allCleanupItems.formattedTotalSize(selected: selectedItems)
    }

    private var selectedCleanupItems: [CleanupItem] {
        allCleanupItems.filter { selectedItems.contains($0.id) }
    }

    private var cleanConfirmationMessage: String {
        var sections: [String] = []
        let selectedCaches = cacheItems.filter { selectedItems.contains($0.id) }
        if !selectedCaches.isEmpty {
            let noun = selectedCaches.count == 1 ? "folder" : "folders"
            sections.append(
                "\(selectedCaches.count) package cache \(noun) will move to Trash. " +
                "Package managers recreate them as needed."
            )
        }

        let commands = dockerItems
            .filter { selectedItems.contains($0.id) }
            .compactMap { item -> String? in
                guard case .action(.docker(let action)) = item.target else { return nil }
                return "• \(action.commandPreview)"
            }
        if !commands.isEmpty {
            sections.append(
                "Docker cleanup permanently removes the unused resources reported by Docker " +
                "using these exact commands:\n\(commands.joined(separator: "\n"))"
            )
        }

        sections.append("Total estimated reclaimable space: \(selectedSize).")
        return sections.joined(separator: "\n\n")
    }

    private func toggleItem(_ item: CleanupItem) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
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
                    HStack(spacing: 10) {
                        Image(systemName: selectedItems.contains(item.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedItems.contains(item.id) ? MacSweepTheme.selection : .secondary)
                            .font(.caption)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.moduleName.replacingOccurrences(of: "\(name) ", with: ""))
                                .font(.caption)

                            Text(item.path.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)

                            HStack(spacing: 6) {
                                Text("Moves cache to Trash")

                                if let date = item.lastModified {
                                    Text("•")
                                    Text("Modified \(date, style: .relative)")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(item.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 24)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.moduleName), \(item.formattedSize)")
                .accessibilityHint(selectedItems.contains(item.id) ? "Deselect cache" : "Select cache to move to Trash")
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

struct DockerStatusLabel: View {
    let isRunning: Bool

    var body: some View {
        HStack {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.blue)

            Text("Docker")
                .font(.headline)

            Spacer()

            Circle()
                .fill(isRunning ? .green : .red)
                .frame(width: 8, height: 8)

            Text(isRunning ? "Running" : "Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

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

// MARK: - Docker cleanup row

struct DockerCleanupRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let onToggle: () -> Void

    private var action: DockerCleanupAction? {
        guard case .action(.docker(let action)) = item.target else { return nil }
        return action
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? MacSweepTheme.selection : .secondary)

                Image(systemName: action?.icon ?? "shippingbox")
                    .frame(width: 24)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName)
                        .font(.subheadline)

                    Text(action?.impactDescription ?? "Docker action unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(action?.commandPreview ?? "docker")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                Spacer()

                Text(item.formattedSize)
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .macSweepCard(radius: MacSweepTheme.smallRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.displayName), \(item.formattedSize)")
        .accessibilityHint(isSelected ? "Deselect Docker cleanup command" : "Select Docker cleanup command for review")
    }
}

#if !SWIFT_PACKAGE
#Preview {
    PackageManagersView()
        .environmentObject(AppState())
        .frame(width: 700, height: 600)
}

#endif
