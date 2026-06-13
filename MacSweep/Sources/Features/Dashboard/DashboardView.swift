import SwiftUI

/// Widget types for popover expansion
enum WidgetType: String, CaseIterable {
    case storage, memory, battery, cpu, network, system
}

/// Main dashboard view matching CleanMyMac style
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    @State private var expandedWidget: WidgetType? = nil
    @State private var hasFullDiskAccess = FullDiskAccess.hasAccess
    @State private var showFDABanner = true

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // FDA Warning Banner
                if !hasFullDiskAccess && showFDABanner {
                    fdaBanner
                }

                smartCareSection

                // Recommendations Section
                recommendationsSection

                // Mac Overview Section
                macOverviewSection

                // Recent Activity
                if appState.lastCleanup != nil || !appState.scanResults.isEmpty {
                    recentActivitySection
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            hasFullDiskAccess = FullDiskAccess.hasAccess
        }
    }

    // MARK: - FDA Banner

    private var fdaBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)

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
            .glassButton(prominent: true)
            .tint(.orange)

            Button {
                withAnimation {
                    showFDABanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Recommendations Section

    private var smartCareSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Smart Care")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.16), lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: Double((appState.smartCareSummary?.score ?? 100)) / 100)
                            .stroke(smartCareScoreColor.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))

                        VStack(spacing: 2) {
                            Text("\(appState.smartCareSummary?.score ?? 100)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Text("Score")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 120, height: 120)

                    if let summary = appState.smartCareSummary {
                        Text("\(summary.formattedBytes) reclaimable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(smartCareHeadline)
                        .font(.headline)

                    Text(smartCareDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await appState.quickScan()
                            }
                        } label: {
                            Label(appState.smartCareSummary == nil ? "Run Smart Care" : "Rescan", systemImage: "sparkles")
                        }
                        .glassButton(prominent: true)
                        .disabled(appState.isScanning)

                        Button {
                            Task {
                                _ = try? await appState.deleteSelected()
                            }
                        } label: {
                            Label("Clean Recommended", systemImage: "trash")
                        }
                        .glassButton()
                        .disabled(appState.selectedItems.isEmpty || appState.isScanning)
                    }

                    if let summary = appState.smartCareSummary, !summary.findings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(summary.findings.prefix(4)) { finding in
                                Button {
                                    if let feature = appState.feature(for: finding.moduleID) {
                                        appState.selectedFeature = feature
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(finding.title)
                                                .font(.subheadline)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.primary)
                                            Text("\(finding.itemCount) items • \(finding.formattedBytes)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        if finding.autoCleanRecommended {
                                            Text("Recommended")
                                                .font(.caption2)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(.green.opacity(0.12), in: Capsule())
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .padding(12)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recommendations")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    RecommendationCard(
                        icon: "magnifyingglass.circle.fill",
                        iconColor: .purple,
                        title: "Run Deep Scan",
                        description: "Find junk files, caches, and large files",
                        buttonTitle: "Scan Now",
                        isLoading: appState.isScanning
                    ) {
                        Task {
                            await appState.scan()
                        }
                    }

                    RecommendationCard(
                        icon: "trash.circle.fill",
                        iconColor: .red,
                        title: "Uninstall Apps",
                        description: "Remove apps you don't use anymore",
                        buttonTitle: "Go to Apps"
                    ) {
                        appState.selectedFeature = .uninstaller
                    }

                    RecommendationCard(
                        icon: "doc.badge.ellipsis",
                        iconColor: .orange,
                        title: "Large Files",
                        description: "Find files taking up space",
                        buttonTitle: "Find Files"
                    ) {
                        appState.selectedFeature = .largeOldFiles
                    }

                    RecommendationCard(
                        icon: "hammer.circle.fill",
                        iconColor: .blue,
                        title: "Developer Tools",
                        description: "Clean node_modules, DerivedData",
                        buttonTitle: "Clean Dev"
                    ) {
                        appState.selectedFeature = .devTools
                    }

                    RecommendationCard(
                        icon: "doc.on.doc.fill",
                        iconColor: .pink,
                        title: "Duplicate Files",
                        description: "Find redundant copies and recover wasted storage",
                        buttonTitle: "Review Duplicates"
                    ) {
                        appState.selectedFeature = .duplicateFiles
                    }

                    RecommendationCard(
                        icon: "battery.100.circle.fill",
                        iconColor: .green,
                        title: "Battery Monitor",
                        description: "Track health, cycle count, and current charge behavior",
                        buttonTitle: "Open Battery"
                    ) {
                        appState.selectedFeature = .batteryMonitor
                    }

                    RecommendationCard(
                        icon: "photo.stack.fill",
                        iconColor: .mint,
                        title: "Similar Photos",
                        description: "Review visually similar images and keep the best shots",
                        buttonTitle: "Review Photos"
                    ) {
                        appState.selectedFeature = .similarPhotos
                    }

                    RecommendationCard(
                        icon: "icloud.fill",
                        iconColor: .cyan,
                        title: "Cloud Cleanup",
                        description: "Reclaim local storage from stale cloud copies and caches",
                        buttonTitle: "Open Cloud"
                    ) {
                        appState.selectedFeature = .cloudCleanup
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var smartCareScoreColor: Color {
        let score = appState.smartCareSummary?.score ?? 100
        if score >= 85 { return .green }
        if score >= 65 { return .orange }
        return .red
    }

    private var smartCareHeadline: String {
        if let summary = appState.smartCareSummary {
            return summary.score >= 85 ? "Your Mac is in good shape." : "Your Mac has cleanup opportunities."
        }
        return "Run Smart Care to inspect the highest-impact cleanup categories."
    }

    private var smartCareDescription: String {
        if let summary = appState.smartCareSummary {
            return "\(summary.issueCount) items found across \(summary.findings.count) categories. Recommended items are preselected for a safer one-click cleanup."
        }
        return "MacSweep will scan junk, large files, duplicates, similar photos, developer artifacts, and cloud storage waste, then preselect the safest items to clean."
    }

    // MARK: - Mac Overview Section

    private var macOverviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mac Overview")
                .font(.title2)
                .fontWeight(.semibold)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                // Storage Card
                OverviewCard(
                    icon: "internaldrive.fill",
                    iconColor: storageColor,
                    title: "Macintosh HD",
                    subtitle: "Available: \(monitor.diskUsage?.formattedFree ?? "...")",
                    progress: 1.0 - (monitor.diskUsage?.freePercentage ?? 0.5),
                    progressColor: storageColor,
                    alertLevel: storageAlertLevel
                )
                .onTapGesture { toggleWidget(.storage) }
                .popover(isPresented: binding(for: .storage), arrowEdge: .bottom) {
                    StorageDetailView(monitor: monitor)
                        .environmentObject(appState)
                        .frame(width: 380, height: 450)
                }

                // Memory Card
                OverviewCard(
                    icon: "memorychip.fill",
                    iconColor: memoryColor,
                    title: "Memory",
                    subtitle: "Available: \(monitor.memoryUsage.formattedAvailable)",
                    progress: monitor.memoryUsage.usedPercentage,
                    progressColor: memoryColor,
                    alertLevel: memoryAlertLevel
                )
                .onTapGesture { toggleWidget(.memory) }
                .popover(isPresented: binding(for: .memory), arrowEdge: .bottom) {
                    MemoryDetailView(monitor: monitor)
                        .frame(width: 380, height: 500)
                }

                // Battery Card
                OverviewCard(
                    icon: monitor.batteryInfo.icon,
                    iconColor: batteryColor,
                    title: "Battery",
                    subtitle: monitor.batteryInfo.statusText,
                    value: "\(monitor.batteryInfo.percentage)%",
                    alertLevel: batteryAlertLevel
                )
                .onTapGesture { toggleWidget(.battery) }
                .popover(isPresented: binding(for: .battery), arrowEdge: .bottom) {
                    BatteryDetailView(monitor: monitor)
                        .frame(width: 380, height: 450)
                }

                // CPU Card
                OverviewCard(
                    icon: "cpu.fill",
                    iconColor: cpuColor,
                    title: "CPU",
                    subtitle: monitor.cpuUsage.formattedLoad,
                    value: monitor.cpuUsage.formattedTemperature,
                    valueColor: cpuTempColor,
                    alertLevel: cpuAlertLevel
                )
                .onTapGesture { toggleWidget(.cpu) }
                .popover(isPresented: binding(for: .cpu), arrowEdge: .bottom) {
                    CPUDetailView(monitor: monitor)
                        .frame(width: 380, height: 480)
                }

                // Wi-Fi Card
                OverviewCard(
                    icon: "wifi",
                    iconColor: .green,
                    title: monitor.networkUsage.ssid ?? "Wi-Fi",
                    subtitle: "↓ \(monitor.networkUsage.formattedDownload)  ↑ \(monitor.networkUsage.formattedUpload)"
                )
                .onTapGesture { toggleWidget(.network) }
                .popover(isPresented: binding(for: .network), arrowEdge: .bottom) {
                    NetworkDetailView(monitor: monitor)
                        .frame(width: 380, height: 420)
                }

                // System Info Card
                OverviewCard(
                    icon: "desktopcomputer",
                    iconColor: .gray,
                    title: Host.current().localizedName ?? "Mac",
                    subtitle: systemVersion
                )
            }
        }
    }

    // MARK: - Popover Helpers

    private func toggleWidget(_ widget: WidgetType) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            expandedWidget = expandedWidget == widget ? nil : widget
        }
    }

    private func binding(for widget: WidgetType) -> Binding<Bool> {
        Binding(
            get: { expandedWidget == widget },
            set: { if !$0 { expandedWidget = nil } }
        )
    }

    // MARK: - Recent Activity Section

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent Activity")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 12) {
                if let cleanup = appState.lastCleanup {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        VStack(alignment: .leading) {
                            Text("Last Cleanup")
                                .font(.headline)
                            Text("Freed \(cleanup.formattedBytesFreed) • \(cleanup.timestamp, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if !appState.scanResults.isEmpty {
                    HStack {
                        Image(systemName: "doc.badge.clock")
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading) {
                            Text("Scan Results")
                                .font(.headline)
                            Text("\(appState.scanResults.count) items • \(ByteCountFormatter.string(fromByteCount: appState.scanResults.reduce(0) { $0 + $1.size }, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Review") {
                            appState.selectedFeature = .systemJunk
                        }
                        .glassButton(prominent: true)
                        .controlSize(.small)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Helpers

    private var systemVersion: String {
        let version = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
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
        MetricThresholds.battery(percent: monitor.batteryInfo.percentage, isCharging: monitor.batteryInfo.isCharging)
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
        batteryAlertLevel.color
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

// MARK: - Recommendation Card

struct RecommendationCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let buttonTitle: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(iconColor)

            Text(title)
                .font(.headline)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            Button {
                action()
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(buttonTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            .glassButton(prominent: true)
            .tint(iconColor)
            .disabled(isLoading)
        }
        .padding()
        .frame(width: 180, height: 180)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Overview Card

struct OverviewCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    var progress: Double? = nil
    var progressColor: Color = .blue
    var value: String? = nil
    var valueColor: Color = .primary
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var alertLevel: MetricAlertLevel = .normal

    @State private var pulseAnimation = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(iconColor)

                Spacer()

                if let value = value {
                    Text(value)
                        .font(.headline)
                        .foregroundStyle(valueColor)
                }

                // Alert indicator
                if alertLevel != .normal {
                    Image(systemName: alertLevel == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(alertLevel.color)
                        .opacity(alertLevel == .critical ? (pulseAnimation ? 0.5 : 1.0) : 1.0)
                }
            }

            Text(title)
                .font(.headline)
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let progress = progress {
                ProgressView(value: progress)
                    .tint(progressColor)
            }

            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .glassButton()
                    .controlSize(.small)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            alertLevel == .critical ? alertLevel.color.opacity(pulseAnimation ? 0.3 : 0.6) : Color.clear,
                            lineWidth: 2
                        )
                )
        )
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onAppear {
            if alertLevel == .critical {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            }
        }
        .onChange(of: alertLevel) { newLevel in
            if newLevel == .critical {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            } else {
                pulseAnimation = false
            }
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    DashboardView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}

#endif
