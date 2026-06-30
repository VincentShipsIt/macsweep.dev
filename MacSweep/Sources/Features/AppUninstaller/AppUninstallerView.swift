import SwiftUI

/// View for uninstalling apps and managing leftovers
struct AppUninstallerView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var apps: [InstalledApp] = []
    @State private var orphanedLeftovers: [AppLeftover] = []
    @State private var selectedApp: InstalledApp?
    @State private var searchText = ""
    @State private var showingUninstallConfirmation = false
    @State private var showingCleanOrphansConfirmation = false
    @State private var isCleaningOrphans = false
    @State private var errorMessage: String?
    @State private var sortOrder: SortOrder = .name

    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case size = "Size"
        case lastUsed = "Last Used"
    }

    /// When true, the auto-load `.task` is skipped so injected snapshot data isn't
    /// immediately overwritten by a real disk scan. Always false in production.
    private let disableAutoLoad: Bool

    /// Default production initializer — discovers installed apps on appear.
    init() {
        disableAutoLoad = false
    }

    /// Seeds the data-bearing `@State` (and suppresses the auto-load scan) so the
    /// headless snapshot harness (and Xcode previews) can render the populated and
    /// error layouts without touching the real filesystem. Not used by the app's
    /// normal navigation, which constructs the view with the no-arg initializer.
    init(
        snapshotApps: [InstalledApp],
        snapshotSelectedApp: InstalledApp? = nil,
        snapshotOrphans: [AppLeftover] = [],
        snapshotError: String? = nil
    ) {
        _apps = State(initialValue: snapshotApps)
        _selectedApp = State(initialValue: snapshotSelectedApp)
        _orphanedLeftovers = State(initialValue: snapshotOrphans)
        _errorMessage = State(initialValue: snapshotError)
        disableAutoLoad = true
    }

    var body: some View {
        FeaturePageShell(
            title: "Uninstaller",
            subtitle: "Remove apps and their leftover files completely."
        ) {
            VStack(spacing: 0) {
                if let errorMessage {
                    MacSweepErrorBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                }

                HSplitView {
                    // App list
                    appListPane
                        .frame(minWidth: 300)

                    // Detail pane
                    detailPane
                        .frame(minWidth: 350)
                }
            }
        }
    }

    // MARK: - App List Pane

    private var appListPane: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps...", text: $searchText)
                        .textFieldStyle(.plain)
                    Spacer()
                    Button {
                        Task {
                            await loadApps()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                }
                .padding(8)
                .macSweepPanel(radius: MacSweepTheme.smallRadius)

                // Sort
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding()

            Divider()

            // App list
            if isLoading {
                Spacer()
                ProgressView("Loading apps...")
                Spacer()
            } else {
                List(filteredApps, selection: $selectedApp) { app in
                    AppListRow(app: app)
                        .tag(app)
                }
                .listStyle(.inset)
                .macSweepListSurface()
            }

            // Orphaned leftovers section
            if !orphanedLeftovers.isEmpty {
                Divider()
                orphanedSection
            }
        }
        .task {
            if !disableAutoLoad { await loadApps() }
        }
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        Group {
            if let app = selectedApp {
                AppDetailView(
                    app: app,
                    onUninstall: { includeLeftovers in
                        Task {
                            await uninstallApp(app, includeLeftovers: includeLeftovers)
                        }
                    }
                )
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "xmark.app")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)

                    Text("Select an app")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("Choose an app from the list to view details and uninstall")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Orphaned Section

    private var orphanedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)

                Text("Orphaned Leftovers")
                    .font(.headline)

                Spacer()

                Text("\(orphanedLeftovers.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Text("Files from uninstalled apps")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            // Size summary
            let totalSize = orphanedLeftovers.reduce(0) { $0 + $1.size }
            Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal)

            Button("Clean Orphans") {
                showingCleanOrphansConfirmation = true
            }
            .glassButton(prominent: true)
            .tint(.orange)
            .disabled(isCleaningOrphans || orphanedLeftovers.isEmpty)
            .padding()
        }
        .background(.ultraThinMaterial)
        .confirmationDialog(
            "Move \(orphanedLeftovers.count) orphaned items to Trash?",
            isPresented: $showingCleanOrphansConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await cleanOrphans() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let totalSize = orphanedLeftovers.reduce(0) { $0 + $1.size }
            Text("This will move \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)) of leftover files from uninstalled apps to Trash. You can restore them from Trash if needed.")
        }
    }

    // MARK: - Actions

    private func loadApps() async {
        isLoading = true
        defer { isLoading = false }

        let discovery = AppDiscovery()
        var loadedApps = await discovery.installedApps()

        // Load leftovers for each app
        let scanner = LeftoverScanner()
        for i in loadedApps.indices {
            loadedApps[i].leftovers = await scanner.findLeftovers(for: loadedApps[i])
        }

        apps = loadedApps

        // Find orphaned leftovers
        let installedIDs = Set(apps.map(\.id))
        orphanedLeftovers = await scanner.findOrphanedLeftovers(installedBundleIDs: installedIDs)
    }

    private func uninstallApp(_ app: InstalledApp, includeLeftovers: Bool) async {
        let uninstaller = AppUninstaller()

        do {
            _ = try await uninstaller.uninstall(app, includeLeftovers: includeLeftovers)
            errorMessage = nil

            // Refresh list
            await loadApps()
            selectedApp = nil
        } catch {
            errorMessage = "Couldn't uninstall \(app.name): \(error.localizedDescription)"
        }
    }

    /// Trash the orphaned leftovers through ScanEngine so the full safety pipeline
    /// (per-item SafetyChecker + aggregate DeletionGuard cap) vets each path — the
    /// same route the other GUI cleanups take. A blocked delete throws and surfaces
    /// in the error banner rather than failing silently.
    private func cleanOrphans() async {
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }

        let items = orphanedLeftovers.map { leftover in
            CleanupItem(
                id: leftover.id,
                path: leftover.path,
                size: leftover.size,
                type: .directory,
                module: "app-uninstaller",
                moduleName: "App Uninstaller"
            )
        }

        do {
            _ = try await ScanEngine().clean(items: items, dryRun: false)
            errorMessage = nil
            orphanedLeftovers = []
            // Re-scan so anything the safety pipeline refused stays visible.
            await loadApps()
        } catch {
            errorMessage = "Couldn't clean orphaned leftovers: \(error.localizedDescription)"
        }
    }

    // MARK: - Computed

    private var filteredApps: [InstalledApp] {
        var result = apps

        // Filter by search
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.id.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort
        switch sortOrder {
        case .name:
            result.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .size:
            result.sort { $0.totalSize > $1.totalSize }
        case .lastUsed:
            result.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }

        return result
    }
}

// MARK: - App List Row

struct AppListRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            // App icon
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app")
                    .font(.title)
                    .frame(width: 32, height: 32)
            }

            // App info
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(app.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !app.leftovers.isEmpty {
                        Text("+\(app.leftovers.count) leftovers")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - App Detail View

struct AppDetailView: View {
    let app: InstalledApp
    let onUninstall: (Bool) -> Void

    @State private var includeLeftovers = true
    @State private var showingConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App header
                VStack(spacing: 12) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 80, height: 80)
                    }

                    Text(app.name)
                        .font(.title)
                        .fontWeight(.bold)

                    if let version = app.version {
                        Text("Version \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(app.id)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top)

                // Size breakdown
                VStack(spacing: 12) {
                    SizeRow(label: "Application", size: app.bundleSize)

                    if !app.leftovers.isEmpty {
                        SizeRow(label: "Leftovers", size: app.leftoverSize, color: .orange)
                    }

                    Divider()

                    SizeRow(label: "Total", size: app.totalSize, isTotal: true)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Leftovers list
                if !app.leftovers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Leftovers")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(app.leftovers) { leftover in
                            LeftoverRow(leftover: leftover)
                        }
                    }
                }

                Spacer()

                // Uninstall section
                VStack(spacing: 12) {
                    if !app.leftovers.isEmpty {
                        Toggle("Remove leftovers", isOn: $includeLeftovers)
                            .padding(.horizontal)
                    }

                    Button {
                        showingConfirmation = true
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .tint(.red)
                    .controlSize(.large)
                    .padding(.horizontal)
                }
                .padding(.bottom)
            }
        }
        .confirmationDialog(
            "Uninstall \(app.name)?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                onUninstall(includeLeftovers)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if includeLeftovers && !app.leftovers.isEmpty {
                Text("This will move \(app.name) and \(app.leftovers.count) leftover items to Trash, freeing \(app.formattedSize).")
            } else {
                Text("This will move \(app.name) to Trash, freeing \(app.formattedBundleSize).")
            }
        }
    }
}

// MARK: - Size Row

struct SizeRow: View {
    let label: String
    let size: Int64
    var color: Color = .primary
    var isTotal: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(isTotal ? .headline : .body)
                .foregroundStyle(color)

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .font(isTotal ? .headline : .body)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Leftover Row

struct LeftoverRow: View {
    let leftover: AppLeftover

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(leftover.path.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(leftover.type.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)

                    Text(leftover.path.deletingLastPathComponent().path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text(leftover.formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    AppUninstallerView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}

#endif
