import SwiftUI

/// Widget types for popover expansion
enum WidgetType: String, CaseIterable {
    case storage, memory, battery, cpu, network, devices, system
}

/// Main dashboard view in the native, list-driven house style used by Inbox.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    /// One shared process monitor for the CPU and Memory popovers so they don't
    /// each spin up an independent 5s `ps` sampling loop (issue #103).
    @StateObject private var processMonitor = ProcessMonitor()
    @State private var expandedWidget: WidgetType? = nil
    @State private var isCleanupReviewExpanded = false
    @State private var showFDABanner = true
    @State private var showingConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if !appState.hasFullDiskAccess && showFDABanner {
                fdaBanner
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            List {
                Section("Smart Care") {
                    smartCareHeaderRow

                    if appState.isScanning {
                        ScanProgressStatusView(
                            progress: appState.scanProgress,
                            message: appState.currentScanModule ?? "Scanning",
                            compact: true
                        )
                        .padding(.vertical, 4)
                    }

                    if let lastError = appState.lastError {
                        StatusMessageRow(
                            icon: "exclamationmark.triangle",
                            tint: .orange,
                            title: "Scan Failed",
                            detail: lastError
                        )
                    }

                    if let deletionError = appState.lastDeletionError {
                        StatusMessageRow(
                            icon: "exclamationmark.triangle",
                            tint: .red,
                            title: "Cleanup Failed",
                            detail: deletionError
                        )
                    }

                    if let summary = appState.smartCareSummary, !summary.findings.isEmpty {
                        ForEach(summary.findings.prefix(5)) { finding in
                            SmartCareFindingRow(finding: finding) {
                                if let feature = appState.feature(for: finding.moduleID) {
                                    appState.selectedFeature = feature
                                }
                            }
                        }
                    }

                    cleanupReviewRows
                }

                Section("Recommendations") {
                    recommendationRows
                }

                Section("Mac Overview") {
                    overviewRows
                }

                if appState.lastCleanup != nil || !appState.scanResults.isEmpty {
                    Section("Recent Activity") {
                        recentActivityRows
                    }
                }
            }
            .listStyle(.inset)
            .macSweepListSurface()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .navigationTitle("")
        .navigationSubtitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                rescanButton
                cleanRecommendedButton
            }
        }
        .onChange(of: appState.isScanning) { _, isScanning in
            if !isScanning && !appState.scanResults.isEmpty {
                isCleanupReviewExpanded = false
            }
        }
        .confirmationDialog(
            "Clean \(appState.selectedItems.count) selected item\(appState.selectedItems.count == 1 ? "" : "s")?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean", role: .destructive) {
                Task {
                    // Behind this dialog → confirm the large-deletion gate.
                    _ = try? await appState.deleteSelected(confirmedLargeDeletion: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will free \(ByteCountFormatter.string(fromByteCount: appState.selectedSize, countStyle: .file)). Some items are deleted permanently and can't be recovered.")
        }
    }

    private var rescanButton: some View {
        Button {
            Task {
                await appState.quickScan()
            }
        } label: {
            Image(systemName: appState.isScanning ? "hourglass" : "arrow.clockwise")
        }
        .disabled(appState.isScanning)
        .help(scanButtonTitle)
    }

    private var cleanRecommendedButton: some View {
        Button {
            showingConfirmation = true
        } label: {
            Image(systemName: "trash")
        }
        .disabled(appState.selectedItems.isEmpty || appState.isScanning)
        .help("Clean Selected")
    }

    // MARK: - FDA Banner

    private var fdaBanner: some View {
        FullDiskAccessWarningBanner(scope: .smartCare) {
            withAnimation {
                showFDABanner = false
            }
        }
    }

    // MARK: - Smart Care

    private var smartCareHeaderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardRowIcon(systemName: "sparkles.rectangle.stack", tint: smartCareScoreColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(smartCareHeadline)
                    .font(.headline)

                Text(smartCareDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Button {
                        Task {
                            await appState.quickScan()
                        }
                    } label: {
                        Label(appState.isScanning ? "Scanning" : scanButtonTitle, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(appState.isScanning)

                    Button {
                        showingConfirmation = true
                    } label: {
                        Label("Clean Selected", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.selectedItems.isEmpty || appState.isScanning)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(appState.smartCareSummary?.score ?? 100)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()

                Text("Score")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let summary = appState.smartCareSummary {
                    Text(summary.formattedBytes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var smartCareScoreColor: Color {
        let score = appState.smartCareSummary?.score ?? 100
        if score >= 85 { return .green }
        if score >= 65 { return .orange }
        return .red
    }

    private var scanButtonTitle: String {
        appState.smartCareSummary == nil ? "Run Smart Care" : "Rescan"
    }

    private var smartCareHeadline: String {
        if appState.isScanning {
            return "Scan in progress"
        }
        if let summary = appState.smartCareSummary {
            return summary.score >= 85 ? "Your Mac is in good shape" : "Cleanup opportunities found"
        }
        return "Inspect high-impact cleanup categories"
    }

    private var smartCareDescription: String {
        if appState.isScanning {
            return appState.currentScanModule ?? "macsweep.dev is scanning in the background."
        }
        if let summary = appState.smartCareSummary {
            return "\(summary.issueCount) items across \(summary.findings.count) categories. Recommended safe items are preselected."
        }
        return "Scans junk, large files, duplicates, similar photos, developer artifacts, and cloud storage waste."
    }

    @ViewBuilder
    private var cleanupReviewRows: some View {
        if !appState.scanResults.isEmpty {
            CleanupReviewSummaryRow(
                isExpanded: isCleanupReviewExpanded,
                selectedCount: selectedCleanupItems.count,
                totalCount: appState.scanResults.count,
                selectedSizeText: selectedCleanupSizeText
            ) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isCleanupReviewExpanded.toggle()
                }
            }

            if isCleanupReviewExpanded {
                CleanupReviewBulkActionsRow(
                    selectedCount: selectedCleanupItems.count,
                    totalCount: appState.scanResults.count,
                    selectedSizeText: selectedCleanupSizeText,
                    hasRecommendedItems: !(appState.smartCareSummary?.recommendedCleanupItemIDs.isEmpty ?? true),
                    selectRecommended: appState.selectRecommended,
                    selectAll: appState.selectAll,
                    selectNone: appState.deselectAll
                )

                ForEach(cleanupReviewGroups) { group in
                    CleanupReviewGroupHeader(
                        group: group,
                        toggleSelection: {
                            if group.isFullySelected {
                                appState.deselectItems(withIDs: group.itemIDs)
                            } else {
                                appState.selectItems(withIDs: group.itemIDs)
                            }
                        }
                    )

                    ForEach(group.items) { item in
                        CleanupReviewItemRow(
                            item: item,
                            isSelected: appState.selectedItems.contains(item.id)
                        ) {
                            appState.toggleSelection(for: item)
                        }
                    }
                }
            }
        }
    }

    private var selectedCleanupItems: [CleanupItem] {
        appState.scanResults.filter { appState.selectedItems.contains($0.id) }
    }

    private var selectedCleanupSizeText: String {
        selectedCleanupItems.formattedTotalSize()
    }

    private var cleanupReviewGroups: [CleanupReviewGroup] {
        Dictionary(grouping: appState.scanResults, by: \.module)
            .map { moduleID, items in
                let sortedItems = items.sorted { lhs, rhs in
                    if lhs.size == rhs.size {
                        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                    }
                    return lhs.size > rhs.size
                }
                let selectedItems = sortedItems.filter { appState.selectedItems.contains($0.id) }

                return CleanupReviewGroup(
                    id: moduleID,
                    title: sortedItems.first?.moduleName ?? moduleID.replacingOccurrences(of: "-", with: " ").capitalized,
                    items: sortedItems,
                    selectedCount: selectedItems.count,
                    selectedBytes: selectedItems.reduce(0) { $0 + $1.size },
                    totalBytes: sortedItems.reduce(0) { $0 + $1.size }
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalBytes == rhs.totalBytes {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.totalBytes > rhs.totalBytes
            }
    }

    // MARK: - Recommendations

    @ViewBuilder
    private var recommendationRows: some View {
        RecommendationRow(
            icon: "magnifyingglass",
            title: "Run Deep Scan",
            detail: "Find junk files, caches, and large files.",
            buttonTitle: "Scan",
            isLoading: appState.isScanning
        ) {
            Task {
                await appState.scan()
            }
        }

        if hasSmartCareFinding(for: "large-files") {
            RecommendationRow(
                icon: "doc.badge.clock",
                title: "Large & Old Files",
                detail: "Find files taking up space.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .largeOldFiles
            }
        }

        if hasSmartCareFinding(for: "dev-tools") {
            RecommendationRow(
                icon: "hammer",
                title: "Developer Tools",
                detail: "Clean node_modules, DerivedData, package caches, and stale build artifacts.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .devTools
            }
        }

        if hasSmartCareFinding(for: "duplicates") {
            RecommendationRow(
                icon: "doc.on.doc",
                title: "Duplicate Files",
                detail: "Find redundant copies and recover wasted storage.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .duplicateFiles
            }
        }

        if monitor.batteryInfo.hasBattery {
            RecommendationRow(
                icon: monitor.batteryInfo.icon,
                title: "Battery Monitor",
                detail: "Track health, cycle count, and charge behavior.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .batteryMonitor
            }
        }

        if hasSmartCareFinding(for: "similar-photos") {
            RecommendationRow(
                icon: "photo.stack",
                title: "Similar Photos",
                detail: "Review visually similar images and keep the best shots.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .similarPhotos
            }
        }

        if hasSmartCareFinding(for: "cloud-cleanup") {
            RecommendationRow(
                icon: "icloud",
                title: "Cloud Cleanup",
                detail: "Reclaim local storage from stale cloud copies and caches.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .cloudCleanup
            }
        }
    }

    private func hasSmartCareFinding(for moduleID: String) -> Bool {
        appState.smartCareSummary?.findings.contains { $0.moduleID == moduleID } ?? false
    }

    // MARK: - Mac Overview

    @ViewBuilder
    private var overviewRows: some View {
        Button {
            toggleWidget(.storage)
        } label: {
            SystemStatusRow(
                icon: "internaldrive",
                tint: storageColor,
                title: "Macintosh HD",
                detail: "Available: \(monitor.diskUsage?.formattedFree ?? "...")",
                progress: 1.0 - (monitor.diskUsage?.freePercentage ?? 0.5),
                progressTint: storageColor,
                alertLevel: storageAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .storage), arrowEdge: .trailing) {
            StorageDetailView(monitor: monitor)
                .environmentObject(appState)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.memory)
        } label: {
            SystemStatusRow(
                icon: "memorychip",
                tint: memoryColor,
                title: "Memory",
                detail: "Available: \(monitor.memoryUsage.formattedAvailable)",
                progress: monitor.memoryUsage.usedPercentage,
                progressTint: memoryColor,
                alertLevel: memoryAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .memory), arrowEdge: .trailing) {
            MemoryDetailView(monitor: monitor, processMonitor: processMonitor)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.battery)
        } label: {
            SystemStatusRow(
                icon: monitor.batteryInfo.icon,
                tint: batteryColor,
                title: "Battery",
                detail: monitor.batteryInfo.statusText,
                value: batteryValueText,
                alertLevel: batteryAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .battery), arrowEdge: .trailing) {
            BatteryDetailView(monitor: monitor)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.cpu)
        } label: {
            SystemStatusRow(
                icon: "cpu",
                tint: cpuColor,
                title: "CPU",
                detail: monitor.cpuUsage.formattedLoad,
                value: monitor.cpuUsage.formattedTemperature,
                valueTint: cpuTempColor,
                alertLevel: cpuAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .cpu), arrowEdge: .trailing) {
            CPUDetailView(monitor: monitor, processMonitor: processMonitor)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.network)
        } label: {
            SystemStatusRow(
                icon: "wifi",
                tint: .green,
                title: monitor.networkUsage.ssid ?? "Wi-Fi",
                detail: "Down \(monitor.networkUsage.formattedDownload)  Up \(monitor.networkUsage.formattedUpload)"
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .network), arrowEdge: .trailing) {
            NetworkDetailView(monitor: monitor)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.devices)
        } label: {
            SystemStatusRow(
                icon: "antenna.radiowaves.left.and.right",
                tint: devicesColor,
                title: "Connected Devices",
                detail: connectedDevicesSubtitle,
                value: lowestDeviceBattery.map { "\($0)%" },
                valueTint: devicesColor,
                alertLevel: devicesAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .devices), arrowEdge: .trailing) {
            ConnectedDevicesDetailView(monitor: monitor)
                .dashboardScrollablePopoverContent()
        }

        Button {
            toggleWidget(.system)
        } label: {
            SystemStatusRow(
                icon: "desktopcomputer",
                tint: .secondary,
                title: Host.current().localizedName ?? "Mac",
                detail: systemVersion
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .system), arrowEdge: .trailing) {
            SystemDetailView(monitor: monitor)
                .dashboardPopoverContent()
        }
    }

    private func toggleWidget(_ widget: WidgetType) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedWidget = expandedWidget == widget ? nil : widget
        }
    }

    private func binding(for widget: WidgetType) -> Binding<Bool> {
        Binding(
            get: { expandedWidget == widget },
            set: { if !$0 { expandedWidget = nil } }
        )
    }

    // MARK: - Recent Activity

    @ViewBuilder
    private var recentActivityRows: some View {
        if let cleanup = appState.lastCleanup {
            StatusMessageRow(
                icon: "checkmark.circle",
                tint: .green,
                title: "Last Cleanup",
                detail: "Freed \(cleanup.formattedBytesFreed) \(relativeTimeText(for: cleanup.timestamp))"
            )

            HStack(spacing: 12) {
                DashboardRowIcon(systemName: "square.and.arrow.up", tint: .purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Share your results")
                        .font(.headline)
                    Text("Create a social cleanup card from your cleanup history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Share") {
                    appState.selectedFeature = .share
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }

        if !appState.scanResults.isEmpty {
            HStack(spacing: 12) {
                DashboardRowIcon(systemName: "doc.badge.clock", tint: .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Results")
                        .font(.headline)
                    Text("\(appState.scanResults.count) items • \(scanResultsSizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Review") {
                    appState.selectedFeature = .systemJunk
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private var scanResultsSizeText: String {
        appState.scanResults.formattedTotalSize()
    }

    private var systemVersion: String {
        let version = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func relativeTimeText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Alert Levels

    private var storageAlertLevel: MetricAlertLevel {
        guard let usage = monitor.diskUsage else { return .normal }
        return MetricThresholds.storage(freePercent: usage.freePercentage)
    }

    private var memoryAlertLevel: MetricAlertLevel {
        MetricThresholds.memory(usagePercent: monitor.memoryUsage.usedPercentage)
    }

    private var batteryAlertLevel: MetricAlertLevel {
        MetricThresholds.battery(
            percent: monitor.batteryInfo.percentage,
            isCharging: monitor.batteryInfo.isCharging,
            hasBattery: monitor.batteryInfo.hasBattery
        )
    }

    private var cpuAlertLevel: MetricAlertLevel {
        MetricThresholds.cpu(usage: monitor.cpuUsage.total, temperature: monitor.cpuUsage.temperature)
    }

    // MARK: - Colors

    private var storageColor: Color {
        storageAlertLevel.color
    }

    private var memoryColor: Color {
        memoryAlertLevel.color
    }

    private var batteryColor: Color {
        if !monitor.batteryInfo.hasBattery {
            return .green
        }
        return batteryAlertLevel.color
    }

    private var batteryValueText: String {
        monitor.batteryInfo.hasBattery ? "\(monitor.batteryInfo.percentage)%" : "AC"
    }

    private var cpuColor: Color {
        cpuAlertLevel.color
    }

    private var cpuTempColor: Color {
        guard monitor.cpuUsage.temperature != nil else { return .primary }
        return MetricThresholds.cpuTemperature(monitor.cpuUsage.temperature).color
    }

    // MARK: - Connected Devices (merged from the connected-devices feature)

    private var connectedDevicesSubtitle: String {
        ConnectedDevicesSummary.subtitle(for: monitor.connectedDevices)
    }

    private var lowestDeviceBattery: Int? {
        monitor.connectedDevices.compactMap(\.lowestBattery).min()
    }

    private var devicesAlertLevel: MetricAlertLevel {
        guard let lowest = lowestDeviceBattery else { return .normal }
        if lowest <= 10 { return .critical }
        if lowest <= 20 { return .warning }
        return .normal
    }

    private var devicesColor: Color {
        switch devicesAlertLevel {
        case .normal: return .cyan
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private enum DashboardPopoverLayout {
    static let width: CGFloat = 380
    static let maxScrollableHeight: CGFloat = 620
}

private extension View {
    func dashboardPopoverContent() -> some View {
        frame(width: DashboardPopoverLayout.width)
            .fixedSize(horizontal: false, vertical: true)
    }

    func dashboardScrollablePopoverContent(maxHeight: CGFloat = DashboardPopoverLayout.maxScrollableHeight) -> some View {
        ScrollView {
            self
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(width: DashboardPopoverLayout.width)
        .frame(maxHeight: maxHeight)
    }
}

// MARK: - List Rows

struct DashboardRowIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
    }
}

struct RecommendationRow: View {
    let icon: String
    let title: String
    let detail: String
    let buttonTitle: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DashboardRowIcon(systemName: icon, tint: .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Button {
                action()
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 48)
                } else {
                    Text(buttonTitle)
                        .frame(minWidth: 48)
                }
            }
            .glassButton()
            .disabled(isLoading)
        }
        .padding(.vertical, 4)
    }
}

struct SmartCareFindingRow: View {
    let finding: SmartCareFinding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                DashboardRowIcon(
                    systemName: finding.autoCleanRecommended ? "checkmark.shield" : "doc.text.magnifyingglass",
                    tint: finding.autoCleanRecommended ? .green : .orange
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("\(finding.itemCount) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(finding.formattedBytes)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .monospacedDigit()

                    if finding.autoCleanRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

private struct CleanupReviewGroup: Identifiable {
    let id: String
    let title: String
    let items: [CleanupItem]
    let selectedCount: Int
    let selectedBytes: Int64
    let totalBytes: Int64

    var itemIDs: Set<CleanupItem.ID> {
        Set(items.map(\.id))
    }

    var isFullySelected: Bool {
        selectedCount == items.count && !items.isEmpty
    }

    var formattedSelectedBytes: String {
        ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
    }
}

private struct CleanupReviewSummaryRow: View {
    let isExpanded: Bool
    let selectedCount: Int
    let totalCount: Int
    let selectedSizeText: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                DashboardRowIcon(systemName: "checklist.checked", tint: .accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected for Cleanup")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Text(selectedSizeText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(selectedCount == 0 ? .secondary : .primary)
                    .monospacedDigit()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Selected for cleanup")
        .accessibilityValue(summaryText)
        .help(isExpanded ? "Hide cleanup item details" : "Review cleanup item details")
    }

    private var summaryText: String {
        if selectedCount == 0 {
            return "No items selected. Expand to review \(totalCount) scan results."
        }
        return "\(selectedCount) of \(totalCount) items selected. Expand to review details."
    }
}

private struct CleanupReviewBulkActionsRow: View {
    let selectedCount: Int
    let totalCount: Int
    let selectedSizeText: String
    let hasRecommendedItems: Bool
    let selectRecommended: () -> Void
    let selectAll: () -> Void
    let selectNone: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardRowIcon(systemName: "slider.horizontal.3", tint: .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedCount) of \(totalCount) selected")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Queued cleanup: \(selectedSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Button("Recommended", action: selectRecommended)
                    .disabled(!hasRecommendedItems)

                Button("All", action: selectAll)

                Button("None", action: selectNone)
                    .disabled(selectedCount == 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct CleanupReviewGroupHeader: View {
    let group: CleanupReviewGroup
    let toggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text("\(group.selectedCount) of \(group.items.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            Text(group.formattedSelectedBytes)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(group.selectedCount == 0 ? .secondary : .primary)
                .monospacedDigit()

            Button(group.isFullySelected ? "Clear" : "Select", action: toggleSelection)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct CleanupReviewItemRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                Image(systemName: item.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.path.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.formattedSize)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .monospacedDigit()

                    if let date = item.lastModified {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(isSelected ? "Selected for cleanup" : "Not selected")
        .help(item.path.path)
    }
}

struct StatusMessageRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            DashboardRowIcon(systemName: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SystemStatusRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var value: String? = nil
    var valueTint: Color = .primary
    var progress: Double? = nil
    var progressTint: Color = .accentColor
    var alertLevel: MetricAlertLevel = .normal

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardRowIcon(systemName: icon, tint: tint)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if alertLevel != .normal {
                        Image(systemName: alertLevel == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(alertLevel.color)
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let progress {
                    ProgressView(value: clamped(progress))
                        .tint(progressTint)
                }
            }

            Spacer(minLength: 16)

            if let value {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(valueTint)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct ScanProgressStatusView: View {
    let progress: Double
    let message: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(message)
                    .font(compact ? .caption : .subheadline)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: min(max(progress, 0), 1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scan progress")
        .accessibilityValue("\(Int(progress * 100)) percent, \(message)")
    }
}

#if !SWIFT_PACKAGE
#Preview {
    DashboardView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
#endif
