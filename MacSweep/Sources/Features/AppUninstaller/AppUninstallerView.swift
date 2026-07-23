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
    @State private var sortOrder: AppUninstallerSortOrder = .name
    // Follow-up: adopt the shared `animated(_:value:)` reduce-motion helper from
    // App/Motion.swift once the "Animate scan lifecycle" work merges it in.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // Edge-to-edge master–detail, matching the other feature pages.
            // Floating card panes with their own gutters made this the one page
            // with a different content margin convention.
            VStack(spacing: 0) {
                if let errorMessage {
                    MacSweepErrorBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                }

                HSplitView {
                    appListPane
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)

                    detailPane
                        .frame(minWidth: 420, maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .macSweepCard(radius: MacSweepTheme.smallRadius)

                // Sort
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(AppUninstallerSortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding()

            Divider()

            // App list — crossfade the first-load spinner into the populated list
            // instead of hard-cutting when discovery finishes.
            ZStack {
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Loading apps...")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    List(filteredApps, selection: $selectedApp) { app in
                        AppListRow(app: app)
                            .tag(app)
                    }
                    .listStyle(.inset)
                    .macSweepListSurface()
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isLoading)

            // Orphaned leftovers section
            if !orphanedLeftovers.isEmpty {
                Divider()
                orphanedSection
            }
        }
        .frame(maxHeight: .infinity)
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
                        await uninstallApp(app, includeLeftovers: includeLeftovers)
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
        // Crossfade detail <-> empty state on every selection change — the most
        // frequent interaction in this view. `.id` gives each app (and the empty
        // state) a distinct identity so the swap triggers the opacity transition.
        .id(selectedApp?.id)
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selectedApp?.id)
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
            Text(totalSize.formattedFileSize)
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
        .background(MacSweepTheme.panel)
        .cleanupReview(
            isPresented: $showingCleanOrphansConfirmation,
            items: orphanCleanupItems,
            disposition: .trash,
            note: "These files were attributed to apps that are no longer installed.",
            onConfirm: { await cleanOrphans() }
        )
    }

    // MARK: - Actions

    private func loadApps() async {
        isLoading = true
        defer { isLoading = false }

        let discovery = AppDiscovery()
        var loadedApps = await discovery.installedApps()

        // Load leftovers for each app
        let scanner = LeftoverScanner()
        for appIndex in loadedApps.indices {
            loadedApps[appIndex].leftovers = await scanner.findLeftovers(
                for: loadedApps[appIndex],
                among: loadedApps
            )
        }

        apps = loadedApps

        // Find orphaned leftovers
        let installedIDs = Set(apps.map(\.id))
        orphanedLeftovers = await scanner.findOrphanedLeftovers(installedBundleIDs: installedIDs)
    }

    private func uninstallApp(_ app: InstalledApp, includeLeftovers: Bool) async -> CleanupResult? {
        let uninstaller = AppUninstaller()

        do {
            let result = try await uninstaller.uninstall(app, includeLeftovers: includeLeftovers)
            errorMessage = nil

            // Refresh list
            await loadApps()
            selectedApp = nil
            return result
        } catch {
            errorMessage = "Couldn't uninstall \(app.name): \(error.localizedDescription)"
            return nil
        }
    }

    /// Trash the orphaned leftovers through ScanEngine so the full safety pipeline
    /// (per-item SafetyChecker + aggregate DeletionGuard cap) vets each path — the
    /// same route the other GUI cleanups take. A blocked delete throws and surfaces
    /// in the error banner rather than failing silently.
    private func cleanOrphans() async -> CleanupResult? {
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }

        do {
            let result = try await ScanEngine().clean(
                items: orphanCleanupItems,
                dryRun: false,
                confirmedLargeDeletion: true
            )
            errorMessage = nil
            orphanedLeftovers = []
            // Re-scan so anything the safety pipeline refused stays visible.
            await loadApps()
            return result
        } catch {
            errorMessage = "Couldn't clean orphaned leftovers: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Computed

    private var filteredApps: [InstalledApp] {
        apps.appList(matching: searchText, sortedBy: sortOrder)
    }

    private var orphanCleanupItems: [CleanupItem] {
        orphanedLeftovers.map { leftover in
            CleanupItem(
                id: leftover.id,
                path: leftover.path,
                size: leftover.size,
                type: .directory,
                module: "app-uninstaller",
                moduleName: "App Uninstaller"
            )
        }
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
    let onUninstall: (Bool) async -> CleanupResult?

    @State private var includeLeftovers = true
    @State private var showingConfirmation = false
    @State private var appBundleItemID = UUID()

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
                .macSweepCard(radius: 12)
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
        .cleanupReview(
            isPresented: $showingConfirmation,
            items: uninstallItems,
            disposition: .trash,
            note: includeLeftovers
                ? "The app bundle and selected support files move to Trash. "
                    + "Running and protected apps are refused at execution."
                : "Only the app bundle moves to Trash; its support files remain.",
            onConfirm: { await onUninstall(includeLeftovers) }
        )
    }

    private var uninstallItems: [CleanupItem] {
        var items = [CleanupItem(
            id: appBundleItemID,
            path: app.bundlePath,
            size: app.bundleSize,
            type: .directory,
            module: "app-uninstaller",
            moduleName: "App Uninstaller"
        )]
        if includeLeftovers {
            items.append(contentsOf: app.leftovers.map { leftover in
                CleanupItem(
                    id: leftover.id,
                    path: leftover.path,
                    size: leftover.size,
                    type: .directory,
                    module: "app-uninstaller",
                    moduleName: "App Uninstaller"
                )
            })
        }
        return items
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

            Text(size.formattedFileSize)
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
                    TagBadge(leftover.type.rawValue, role: .warning)

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
