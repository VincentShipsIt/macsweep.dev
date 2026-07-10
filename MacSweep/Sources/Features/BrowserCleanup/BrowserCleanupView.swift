import SwiftUI

/// View for browser cleanup with per-browser breakdown
struct BrowserCleanupView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var browserResults: [BrowserScanResult] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false
    @State private var errorMessage: String?

    private let browsers: [any BrowserModule] = [
        ChromeModule(),
        SafariModule(),
        FirefoxModule(),
        BraveModule(),
        ArcModule(),
        EdgeModule(),
    ]

    @State private var showSafariFDAWarning = false

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                MacSweepErrorBanner(message: errorMessage) {
                    self.errorMessage = nil
                }
            }
            header

            Divider()

            if isScanning {
                scanningView
            } else if browserResults.isEmpty {
                emptyState
            } else {
                resultsList
            }

            if !browserResults.isEmpty && !isScanning {
                Divider()
                footer
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Browser Cleanup")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Remove caches and service workers from browsers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await scanBrowsers()
                }
            } label: {
                Label("Scan Browsers", systemImage: "magnifyingglass")
            }
            .glassButton(prominent: true)
            .disabled(isScanning)
        }
        .padding()
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning browsers...")
                .font(.headline)

            Text("Finding caches and service workers")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No browser data found")
                .font(.headline)

            Text("Run a scan to find browser caches")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Scan Now") {
                Task {
                    await scanBrowsers()
                }
            }
            .glassButton(prominent: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Safari FDA Warning
                if safariNeedsFDA {
                    SafariFDAWarningBanner()
                }

                ForEach(browserResults) { result in
                    BrowserResultCard(
                        result: result,
                        selectedItems: $selectedItems
                    )
                }

                // Service Workers Section
                if !serviceWorkerItems.isEmpty {
                    ServiceWorkerSection(
                        items: serviceWorkerItems,
                        selectedItems: $selectedItems
                    )
                }
            }
            .padding()
        }
    }

    /// Check if Safari is installed but we don't have FDA
    private var safariNeedsFDA: Bool {
        let safari = SafariModule()
        return safari.isInstalled && !safari.hasFullDiskAccess
    }

    // MARK: - Footer

    private var footer: some View {
        CleanupFooter(
            selectedCount: selectedItems.count,
            countNoun: "items",
            summary: "Will free \(selectedSize)",
            onSelectAll: { selectAll() },
            actionTitle: "Clean",
            actionDisabled: selectedItems.isEmpty,
            onAction: { showingConfirmation = true }
        )
        .deleteConfirmation(
            "Clean browser data?",
            isPresented: $showingConfirmation,
            confirmTitle: "Clean",
            message: "This will remove \(selectedSize) of browser caches and service workers. Browsers will recreate caches as needed."
        ) {
            Task { await cleanSelected() }
        }
    }

    // MARK: - Actions

    private func scanBrowsers() async {
        isScanning = true
        browserResults = []
        selectedItems = []
        errorMessage = nil
        // Clear the previous scan's service-worker items first; otherwise each
        // rescan appends a fresh set and the list (and reported size) doubles.
        appState.scanResults.removeAll { $0.module == "service-workers" }

        defer { isScanning = false }

        var failedBrowsers: [String] = []
        for browser in browsers {
            guard browser.isInstalled else { continue }

            do {
                let items = try await browser.scan()
                if !items.isEmpty {
                    let result = BrowserScanResult(
                        id: UUID(),
                        browserName: browser.name,
                        browserIcon: browser.icon,
                        isRunning: browser.isRunning,
                        items: items
                    )
                    browserResults.append(result)
                }
            } catch {
                failedBrowsers.append(browser.name)
            }
        }

        if !failedBrowsers.isEmpty {
            errorMessage = "Couldn't scan: \(failedBrowsers.joined(separator: ", ")). Other browsers scanned normally."
        }

        // Scan service workers
        let swModule = ServiceWorkerModule()
        if let swItems = try? await swModule.scan(), !swItems.isEmpty {
            // Service worker items are handled separately
            appState.scanResults.append(contentsOf: swItems)
        }
    }

    private func cleanSelected() async {
        let itemsToClean = allItems.filter { selectedItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies. The engine
        // groups items by module id and dispatches to each browser itself.
        let engine = ScanEngine()
        var cleanupError: String?
        do {
            _ = try await engine.clean(items: itemsToClean, dryRun: false, confirmedLargeDeletion: true)
        } catch {
            cleanupError = "Couldn't clean browser data: \(error.localizedDescription)"
        }

        // Rescan (clears errorMessage); restore the cleanup error afterwards so
        // the user still sees why the clean failed.
        await scanBrowsers()
        if let cleanupError {
            errorMessage = cleanupError
        }
    }

    private func selectAll() {
        selectedItems = Set(allItems.map(\.id))
    }

    // MARK: - Computed

    private var allItems: [CleanupItem] {
        browserResults.flatMap(\.items)
    }

    private var serviceWorkerItems: [CleanupItem] {
        appState.scanResults.filter { $0.module == "service-workers" }
    }

    private var selectedSize: String {
        allItems.formattedTotalSize(selected: selectedItems)
    }
}

// MARK: - Browser Scan Result

struct BrowserScanResult: Identifiable {
    let id: UUID
    let browserName: String
    let browserIcon: String
    let isRunning: Bool
    let items: [CleanupItem]

    var totalSize: Int64 {
        items.totalSize()
    }

    var formattedSize: String {
        items.formattedTotalSize()
    }
}

// MARK: - Browser Result Card

struct BrowserResultCard: View {
    let result: BrowserScanResult
    @Binding var selectedItems: Set<UUID>
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: result.browserIcon)
                        .font(.title2)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(result.browserName)
                                .font(.headline)

                            if result.isRunning {
                                Text("Running")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }

                        Text("\(result.items.count) items • \(result.formattedSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding()

            // Expanded items
            if isExpanded {
                Divider()

                VStack(spacing: 0) {
                    ForEach(result.items) { item in
                        BrowserItemRow(
                            item: item,
                            isSelected: selectedItems.contains(item.id)
                        ) {
                            if selectedItems.contains(item.id) {
                                selectedItems.remove(item.id)
                            } else {
                                selectedItems.insert(item.id)
                            }
                        }

                        if item.id != result.items.last?.id {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .macSweepCard(radius: 12)
    }
}

// MARK: - Browser Item Row

struct BrowserItemRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                SelectionCheckmark(isSelected: isSelected)

                Image(systemName: item.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.moduleName)
                        .font(.subheadline)

                    Text(item.path.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Service Worker Section

struct ServiceWorkerSection: View {
    let items: [CleanupItem]
    @Binding var selectedItems: Set<UUID>
    @State private var isExpanded = false

    var totalSize: String {
        items.formattedTotalSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "app.badge.checkmark")
                        .font(.title2)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Service Workers")
                            .font(.headline)

                        Text("\(items.count) apps • \(totalSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding()

            if isExpanded {
                Divider()

                VStack(spacing: 0) {
                    ForEach(items) { item in
                        BrowserItemRow(
                            item: item,
                            isSelected: selectedItems.contains(item.id)
                        ) {
                            if selectedItems.contains(item.id) {
                                selectedItems.remove(item.id)
                            } else {
                                selectedItems.insert(item.id)
                            }
                        }

                        if item.id != items.last?.id {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .macSweepCard(radius: 12)
    }
}

// MARK: - Safari FDA Warning Banner

struct SafariFDAWarningBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access Required for Safari")
                    .font(.headline)

                Text("macsweep.dev needs Full Disk Access to clean Safari data. Open System Settings > Privacy & Security > Full Disk Access and enable macsweep.dev.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Settings") {
                openFDASettings()
            }
            .glassButton()
        }
        .padding()
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func openFDASettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Risk Warning Banner

struct RiskWarningBanner: View {
    let riskLevel: BrowserDataRiskLevel

    var body: some View {
        if let message = riskLevel.warningMessage {
            HStack(spacing: 12) {
                Image(systemName: riskLevel >= .high ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(riskLevel >= .high ? .red : .orange)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .background(
                (riskLevel >= .high ? Color.red : Color.orange).opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    BrowserCleanupView()
        .environmentObject(AppState())
        .frame(width: 600, height: 500)
}

#endif
