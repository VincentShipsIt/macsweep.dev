import SwiftUI
import AppKit

/// Menu bar dropdown view with system stats and quick actions
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    @Environment(\.openWindow) private var openWindow
    @State private var expandedWidget: WidgetType?
    @State private var menuWindow: NSWindow?
    @AppStorage(CompanionToolbarPreferences.storageCardVisible) private var storageCardVisible = true
    @AppStorage(CompanionToolbarPreferences.memoryCardVisible) private var memoryCardVisible = true
    @AppStorage(CompanionToolbarPreferences.batteryCardVisible) private var batteryCardVisible = true
    @AppStorage(CompanionToolbarPreferences.cpuCardVisible) private var cpuCardVisible = true
    @AppStorage(CompanionToolbarPreferences.networkCardVisible) private var networkCardVisible = true
    @AppStorage(CompanionToolbarPreferences.devicesCardVisible) private var devicesCardVisible = true
    @AppStorage(CompanionToolbarPreferences.smartCareCardVisible) private var smartCareCardVisible = true

    var body: some View {
        // The main overview is a fixed-size window, so it NEVER moves. Tapping a
        // stat card opens the detail in a SEPARATE floating panel to the left
        // (see MenuBarDetailPanel) — CleanMyMac-style — instead of resizing this
        // window, which is what dragged the main panel around before.
        mainColumn
            .frame(width: 320)
            .background(MacSweepCompanionSurface(radius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(WindowAccessor { window in
                menuWindow = window
                configureMenuWindow(window)
            })
            .onDisappear {
                // Menu-bar dropdown was dismissed → tear down the detail panel too.
                MenuBarDetailPanel.shared.dismiss()
                expandedWidget = nil
            }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .padding(.vertical, 6)

            systemOverviewGrid

            if showsQuickActions {
                Divider()
                    .padding(.vertical, 6)

                quickActions
            }

            Divider()
                .padding(.vertical, 6)

            footer
        }
        .padding(16)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.purple)

            Text("MacSweep")
                .font(.headline)

            Spacer()

            if appState.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - System Overview Grid

    private var systemOverviewGrid: some View {
        Group {
            if visibleToolbarCards.isEmpty {
                Label("No companion cards enabled", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: MenuBarStatCardLayout.gridSpacing),
                    GridItem(.flexible())
                ], spacing: MenuBarStatCardLayout.gridSpacing) {
                    ForEach(visibleToolbarCards) { card in
                        companionToolbarCard(card)
                    }
                }
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        VStack(spacing: 8) {
            if appState.isScanning {
                ScanProgressStatusView(
                    progress: appState.scanProgress,
                    message: appState.currentScanModule ?? "Scanning",
                    compact: true
                )
                .padding(.horizontal, 4)
            }

            if !appState.scanResults.isEmpty {
                HStack {
                    Text("\(appState.scanResults.count) items found")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(appState.scanResults.formattedTotalSize())
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 4)
            }

            if let lastCleanup = appState.lastCleanup {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)

                    Text("Last cleanup: \(lastCleanup.formattedBytesFreed) freed")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                openMainWindow()
            } label: {
                Label("Open MacSweep", systemImage: "macwindow")
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var visibleToolbarCards: [CompanionToolbarCard] {
        CompanionToolbarCard.allCases.filter { card in
            switch card {
            case .storage: return storageCardVisible
            case .memory: return memoryCardVisible
            case .battery: return batteryCardVisible
            case .cpu: return cpuCardVisible
            case .network: return networkCardVisible
            case .devices: return devicesCardVisible
            case .smartCare: return smartCareCardVisible
            }
        }
    }

    private var showsQuickActions: Bool {
        appState.isScanning || !appState.scanResults.isEmpty || appState.lastCleanup != nil
    }

    @ViewBuilder
    private func companionToolbarCard(_ card: CompanionToolbarCard) -> some View {
        switch card {
        case .storage:
            SystemStatCard(
                icon: card.icon,
                title: card.title,
                subtitle: "Available: \(monitor.diskUsage?.formattedFree ?? "...")",
                accentColor: .blue,
                onTap: { toggleWidget(.storage) }
            )
        case .memory:
            SystemStatCard(
                icon: card.icon,
                title: card.title,
                subtitle: "Available: \(monitor.memoryUsage.formattedAvailable)",
                accentColor: memoryColor,
                actionLabel: "Free Up",
                action: {
                    Task {
                        try? await monitor.freeUpMemory()
                    }
                },
                onTap: { toggleWidget(.memory) }
            )
        case .battery:
            SystemStatCard(
                icon: monitor.batteryInfo.icon,
                title: card.title,
                subtitle: monitor.batteryInfo.statusText,
                value: monitor.batteryInfo.hasBattery ? "\(monitor.batteryInfo.percentage)%" : "AC",
                accentColor: batteryColor,
                onTap: { toggleWidget(.battery) }
            )
        case .cpu:
            SystemStatCard(
                icon: card.icon,
                title: card.title,
                subtitle: monitor.cpuUsage.formattedLoad,
                value: monitor.cpuUsage.formattedTemperature,
                valueColor: cpuTempColor,
                accentColor: .orange,
                onTap: { toggleWidget(.cpu) }
            )
        case .network:
            SystemStatCard(
                icon: card.icon,
                title: monitor.networkUsage.ssid ?? card.title,
                subtitle: "↓ \(monitor.networkUsage.formattedDownload)",
                secondarySubtitle: "↑ \(monitor.networkUsage.formattedUpload)",
                accentColor: .green,
                onTap: { toggleWidget(.network) }
            )
        case .devices:
            SystemStatCard(
                icon: card.icon,
                title: card.title,
                subtitle: connectedDevicesSubtitle,
                value: lowestDeviceBattery.map { "\($0)%" },
                accentColor: devicesColor,
                onTap: { toggleWidget(.devices) }
            )
        case .smartCare:
            SystemStatCard(
                icon: card.icon,
                title: card.title,
                subtitle: appState.isScanning ? "\(Int(appState.scanProgress * 100))% complete" : "Run one-click cleanup",
                accentColor: .purple,
                actionLabel: appState.isScanning ? nil : "Scan",
                action: {
                    Task {
                        await appState.quickScan()
                    }
                },
                onTap: { navigateToFeature(.smartScan) }
            )
        }
    }

    private func toggleWidget(_ widget: WidgetType) {
        // Toggle the SEPARATE detail panel. The main window is never resized, so
        // it never moves — only the side panel shows/hides.
        if expandedWidget == widget {
            expandedWidget = nil
            MenuBarDetailPanel.shared.dismiss()
            return
        }
        // Guard the window first so expandedWidget never desyncs from the panel
        // (setting it before a failed open would leave a "selected" card with no panel).
        guard let window = menuWindow else { return }
        expandedWidget = widget
        MenuBarDetailPanel.shared.present(
            anchor: window,
            preferredHeight: MenuBarDetailContent.preferredHeight(for: widget, monitor: monitor),
            content: AnyView(
                MenuBarDetailContent(widget: widget, monitor: monitor, appState: appState) { feature in
                    appState.selectedFeature = feature
                    openMainWindow()
                    expandedWidget = nil
                    MenuBarDetailPanel.shared.dismiss()
                }
            )
        )
    }

    private func navigateToFeature(_ feature: Feature) {
        appState.selectedFeature = feature
        openMainWindow()
    }

    private func openMainWindow() {
        if !AppDelegate.focusMainWindow() {
            openWindow(id: "main")
        }

        DispatchQueue.main.async {
            AppDelegate.focusMainWindow()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AppDelegate.focusMainWindow()
        }
    }

    private func configureMenuWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
    }

    // Colors routed through the shared MetricThresholds so the menu bar can't
    // flip a metric to warning/critical at a different boundary than the
    // dashboard or the detail popovers (issue #102).
    private var memoryColor: Color {
        MetricThresholds.memory(usagePercent: monitor.memoryUsage.usedPercentage).color
    }

    private var batteryColor: Color {
        if !monitor.batteryInfo.hasBattery { return .green }
        return MetricThresholds.battery(
            percent: monitor.batteryInfo.percentage,
            isCharging: monitor.batteryInfo.isCharging,
            hasBattery: monitor.batteryInfo.hasBattery
        ).color
    }

    private var cpuTempColor: Color {
        guard monitor.cpuUsage.temperature != nil else { return .primary }
        return MetricThresholds.cpuTemperature(monitor.cpuUsage.temperature).color
    }

    private var connectedDevicesSubtitle: String {
        ConnectedDevicesSummary.subtitle(for: monitor.connectedDevices)
    }

    private var lowestDeviceBattery: Int? {
        monitor.connectedDevices.compactMap(\.lowestBattery).min()
    }

    private var devicesColor: Color {
        guard let lowest = lowestDeviceBattery else { return .cyan }
        if lowest <= 10 { return .red }
        if lowest <= 20 { return .orange }
        return .cyan
    }
}

// MARK: - System Stat Card

private enum MenuBarStatCardLayout {
    static let height: CGFloat = 92
    static let gridSpacing: CGFloat = 12
    static let footerHeight: CGFloat = 20
}

struct SystemStatCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var secondarySubtitle: String? = nil
    var value: String? = nil
    var valueColor: Color = .primary
    var accentColor: Color = .blue
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accentColor)

                Spacer()

                if let value = value {
                    Text(value)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(valueColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(subtitle)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: MenuBarStatCardLayout.height, maxHeight: MenuBarStatCardLayout.height, alignment: .topLeading)
        .background(MacSweepTheme.panelStrong, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MacSweepTheme.divider, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let secondary = secondarySubtitle {
            Text(secondary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: MenuBarStatCardLayout.footerHeight, alignment: .leading)
        } else if let label = actionLabel, let action = action {
            Button(label, action: action)
                .font(.caption2)
                .glassButton()
                .controlSize(.small)
                .frame(height: MenuBarStatCardLayout.footerHeight, alignment: .leading)
        } else {
            Color.clear
                .frame(height: MenuBarStatCardLayout.footerHeight)
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    MenuBarView()
        .environmentObject(AppState())
}

#endif
