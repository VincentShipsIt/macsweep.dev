import SwiftUI

/// Widget types for popover expansion
enum WidgetType: String, CaseIterable {
    case storage, memory, battery, cpu, network, system
}

/// Main dashboard view in the native, list-driven house style used by Inbox.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    @State private var expandedWidget: WidgetType? = nil
    @State private var hasFullDiskAccess = FullDiskAccess.hasAccess
    @State private var showFDABanner = true

    var body: some View {
        VStack(spacing: 0) {
            if !hasFullDiskAccess && showFDABanner {
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

                    if let summary = appState.smartCareSummary, !summary.findings.isEmpty {
                        ForEach(summary.findings.prefix(5)) { finding in
                            SmartCareFindingRow(finding: finding) {
                                if let feature = appState.feature(for: finding.moduleID) {
                                    appState.selectedFeature = feature
                                }
                            }
                        }
                    }
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
        .background(Color.clear)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await appState.quickScan()
                    }
                } label: {
                    Image(systemName: appState.isScanning ? "hourglass" : "arrow.clockwise")
                }
                .disabled(appState.isScanning)
                .help(appState.smartCareSummary == nil ? "Run Smart Care" : "Rescan")

                Button {
                    Task {
                        _ = try? await appState.deleteSelected()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(appState.selectedItems.isEmpty || appState.isScanning)
                .help("Clean Recommended")
            }
        }
        .onAppear {
            hasFullDiskAccess = FullDiskAccess.hasAccess
        }
    }

    // MARK: - FDA Banner

    private var fdaBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access Required")
                    .font(.headline)

                Text("MacSweep needs permission to scan protected folders. Some features may be limited.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Grant Access") {
                FullDiskAccess.openSystemPreferences()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)

            Button {
                withAnimation {
                    showFDABanner = false
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(12)
        .background(MacSweepTheme.warningPanel, in: RoundedRectangle(cornerRadius: MacSweepTheme.smallRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MacSweepTheme.smallRadius)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
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
                        Label(appState.isScanning ? "Scanning" : (appState.smartCareSummary == nil ? "Run Smart Care" : "Rescan"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(appState.isScanning)

                    Button {
                        Task {
                            _ = try? await appState.deleteSelected()
                        }
                    } label: {
                        Label("Clean Recommended", systemImage: "trash")
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
            return appState.currentScanModule ?? "MacSweep is scanning in the background."
        }
        if let summary = appState.smartCareSummary {
            return "\(summary.issueCount) items across \(summary.findings.count) categories. Recommended safe items are preselected."
        }
        return "Scans junk, large files, duplicates, similar photos, developer artifacts, and cloud storage waste."
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

        RecommendationRow(
            icon: "xmark.app",
            title: "Uninstall Apps",
            detail: "Remove applications you do not use anymore.",
            buttonTitle: "Open"
        ) {
            appState.selectedFeature = .uninstaller
        }

        RecommendationRow(
            icon: "doc.badge.clock",
            title: "Large & Old Files",
            detail: "Find files taking up space.",
            buttonTitle: "Open"
        ) {
            appState.selectedFeature = .largeOldFiles
        }

        RecommendationRow(
            icon: "hammer",
            title: "Developer Tools",
            detail: "Clean node_modules, DerivedData, package caches, and stale build artifacts.",
            buttonTitle: "Open"
        ) {
            appState.selectedFeature = .devTools
        }

        RecommendationRow(
            icon: "doc.on.doc",
            title: "Duplicate Files",
            detail: "Find redundant copies and recover wasted storage.",
            buttonTitle: "Open"
        ) {
            appState.selectedFeature = .duplicateFiles
        }

        RecommendationRow(
            icon: monitor.batteryInfo.icon,
            title: "Battery Monitor",
            detail: monitor.batteryInfo.hasBattery ? "Track health, cycle count, and charge behavior." : "This Mac is on desktop power.",
            buttonTitle: "Open"
        ) {
            appState.selectedFeature = .batteryMonitor
        }

        RecommendationRow(
            icon: "photo.stack",
            title: "Similar Photos",
            detail: "Review visually similar images and keep the best shots.",
            buttonTitle: "Open"
        ) {
            appState.selectedFeature = .similarPhotos
        }

        RecommendationRow(
            icon: "icloud",
            title: "Cloud Cleanup",
            detail: "Reclaim local storage from stale cloud copies and caches.",
            buttonTitle: "Open"
        ) {
            appState.selectedFeature = .cloudCleanup
        }
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
                .frame(width: 380, height: 450)
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
            MemoryDetailView(monitor: monitor)
                .frame(width: 380, height: 500)
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
                .frame(width: 380, height: 450)
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
            CPUDetailView(monitor: monitor)
                .frame(width: 380, height: 480)
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
                .frame(width: 380, height: 420)
        }

        SystemStatusRow(
            icon: "desktopcomputer",
            tint: .secondary,
            title: Host.current().localizedName ?? "Mac",
            detail: systemVersion
        )
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
        ByteCountFormatter.string(
            fromByteCount: appState.scanResults.reduce(0) { $0 + $1.size },
            countStyle: .file
        )
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
        guard let temp = monitor.cpuUsage.temperature else { return .primary }
        if temp > 80 { return .red }
        if temp > 60 { return .orange }
        return .green
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
