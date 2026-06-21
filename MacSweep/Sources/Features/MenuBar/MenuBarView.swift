import SwiftUI
import AppKit

/// Menu bar dropdown view with system stats and quick actions
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    @Environment(\.openWindow) private var openWindow
    @State private var expandedWidget: WidgetType?
    @State private var menuWindow: NSWindow?

    private let shortcutFeatures: [Feature] = [
        .assistant,
        .systemJunk,
        .trashBins,
        .devTools,
        .privacy,
        .optimization,
        .batteryMonitor,
        .cloudCleanup,
        .uninstaller,
        .spaceLens,
        .largeOldFiles,
        .duplicateFiles,
        .similarPhotos,
    ]

    var body: some View {
        // The main overview is a fixed-size window, so it NEVER moves. Tapping a
        // stat card opens the detail in a SEPARATE floating panel to the left
        // (see MenuBarDetailPanel) — CleanMyMac-style — instead of resizing this
        // window, which is what dragged the main panel around before.
        mainColumn
            .frame(width: 320)
            .background(WindowAccessor { menuWindow = $0 })
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

            Divider()
                .padding(.vertical, 6)

            quickActions

            Divider()
                .padding(.vertical, 6)

            moduleShortcuts

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
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            // Storage
            SystemStatCard(
                icon: "internaldrive",
                title: "Macintosh HD",
                subtitle: "Available: \(monitor.diskUsage?.formattedFree ?? "...")",
                accentColor: .blue,
                onTap: { toggleWidget(.storage) }
            )

            // Memory
            SystemStatCard(
                icon: "memorychip",
                title: "Memory",
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

            // Battery
            SystemStatCard(
                icon: monitor.batteryInfo.icon,
                title: "Battery",
                subtitle: monitor.batteryInfo.statusText,
                value: monitor.batteryInfo.hasBattery ? "\(monitor.batteryInfo.percentage)%" : "AC",
                accentColor: batteryColor,
                onTap: { toggleWidget(.battery) }
            )

            // CPU
            SystemStatCard(
                icon: "cpu",
                title: "CPU",
                subtitle: monitor.cpuUsage.formattedLoad,
                value: monitor.cpuUsage.formattedTemperature,
                valueColor: cpuTempColor,
                accentColor: .orange,
                onTap: { toggleWidget(.cpu) }
            )

            // Wi-Fi
            SystemStatCard(
                icon: "wifi",
                title: monitor.networkUsage.ssid ?? "Wi-Fi",
                subtitle: "↓ \(monitor.networkUsage.formattedDownload)",
                secondarySubtitle: "↑ \(monitor.networkUsage.formattedUpload)",
                accentColor: .green,
                onTap: { toggleWidget(.network) }
            )

            // Connected Devices
            SystemStatCard(
                icon: "antenna.radiowaves.left.and.right",
                title: "Devices",
                subtitle: connectedDevicesSubtitle,
                value: lowestDeviceBattery.map { "\($0)%" },
                accentColor: devicesColor,
                onTap: { toggleWidget(.devices) }
            )

            // Quick Scan
            SystemStatCard(
                icon: "magnifyingglass",
                title: "Smart Care",
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

                    Text(ByteCountFormatter.string(fromByteCount: appState.scanResults.reduce(0) { $0 + $1.size }, countStyle: .file))
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

    private var moduleShortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Modules")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Smart Care") {
                    navigateToFeature(.smartScan)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(shortcutFeatures, id: \.self) { feature in
                    ModuleShortcutButton(feature: feature) {
                        navigateToFeature(feature)
                    }
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

    private var memoryColor: Color {
        switch monitor.memoryUsage.pressureLevel {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var batteryColor: Color {
        if !monitor.batteryInfo.hasBattery { return .green }
        if monitor.batteryInfo.isCharging { return .green }
        if monitor.batteryInfo.percentage < 20 { return .red }
        if monitor.batteryInfo.percentage < 50 { return .orange }
        return .green
    }

    private var cpuTempColor: Color {
        guard let temp = monitor.cpuUsage.temperature else { return .primary }
        if temp > 80 { return .red }
        if temp > 60 { return .orange }
        return .primary
    }

    private var connectedDevicesSubtitle: String {
        let count = monitor.connectedDevices.count
        switch count {
        case 0: return "None connected"
        case 1: return monitor.connectedDevices[0].name
        default: return "\(count) connected"
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(accentColor)

                Spacer()

                if let value = value {
                    Text(value)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(valueColor)
                }
            }

            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(accentColor)
                .lineLimit(1)

            if let secondary = secondarySubtitle {
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let label = actionLabel, let action = action {
                Button(label, action: action)
                    .font(.caption2)
                    .glassButton()
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}

struct ModuleShortcutButton: View {
    let feature: Feature
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: feature.icon)
                    .font(.caption)
                    .frame(width: 14)
                    .foregroundStyle(.blue)

                Text(feature.rawValue)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    MenuBarView()
        .environmentObject(AppState())
}

#endif
