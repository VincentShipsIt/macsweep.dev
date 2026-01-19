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
            .buttonStyle(.borderedProminent)
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
                }
                .padding(.horizontal, 2)
            }
        }
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
                        .buttonStyle(.borderedProminent)
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
            .buttonStyle(.borderedProminent)
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
                    .buttonStyle(.bordered)
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

#Preview {
    DashboardView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
