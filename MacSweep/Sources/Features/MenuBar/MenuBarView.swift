import SwiftUI
import AppKit

/// Menu bar dropdown view with system stats and quick actions
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    @Environment(\.openWindow) private var openWindow
    @State private var expandedWidget: WidgetType?

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
        ScrollView {
            VStack(spacing: 0) {
                header

                Divider()
                    .padding(.vertical, 8)

                systemOverviewGrid

                if expandedWidget != nil {
                    Divider()
                        .padding(.vertical, 8)

                    expandedDetailPanel
                }

                Divider()
                    .padding(.vertical, 8)

                quickActions

                Divider()
                    .padding(.vertical, 8)

                moduleShortcuts

                Divider()
                    .padding(.vertical, 8)

                footer
            }
            .padding(16)
        }
        // MenuBarExtra(.window) sizes the panel to the content's ideal size; a
        // ScrollView has no intrinsic height, so without an explicit height the
        // panel collapses to ~0pt tall (the "invisible box"). Pin a real height.
        .frame(width: 320, height: 560)
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
                value: "\(monitor.batteryInfo.percentage)%",
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

    private var expandedDetailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(detailTitle(for: expandedWidget))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                if let widget = expandedWidget {
                    Button("Open Full View") {
                        navigateToFeature(feature(for: widget))
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }

            Group {
                switch expandedWidget {
                case .storage:
                    StorageDetailView(monitor: monitor)
                        .environmentObject(appState)
                        .frame(height: 290)
                case .memory:
                    MemoryDetailView(monitor: monitor)
                        .frame(height: 340)
                case .battery:
                    BatteryDetailView(monitor: monitor)
                        .frame(height: 320)
                case .cpu:
                    CPUDetailView(monitor: monitor)
                        .frame(height: 320)
                case .network:
                    NetworkDetailView(monitor: monitor)
                        .frame(height: 280)
                case .system, .none:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .transition(.opacity.combined(with: .move(edge: .top)))
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
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedWidget = expandedWidget == widget ? nil : widget
        }
    }

    private func navigateToFeature(_ feature: Feature) {
        appState.selectedFeature = feature
        openMainWindow()
    }

    private func feature(for widget: WidgetType) -> Feature {
        switch widget {
        case .storage:
            return .spaceLens
        case .memory, .cpu:
            return .optimization
        case .battery:
            return .batteryMonitor
        case .network:
            return .networkCleanup
        case .system:
            return .smartScan
        }
    }

    private func detailTitle(for widget: WidgetType?) -> String {
        switch widget {
        case .storage:
            return "Macintosh HD"
        case .memory:
            return "Memory"
        case .battery:
            return "Battery"
        case .cpu:
            return "CPU"
        case .network:
            return monitor.networkUsage.ssid ?? "Wi-Fi"
        case .system:
            return "System"
        case .none:
            return ""
        }
    }

    private func openMainWindow() {
        // Show dock icon first
        AppDelegate.showDockIcon()

        // Find existing main window (not menu bar panel)
        let mainWindow = NSApplication.shared.windows.first { window in
            guard window.level == .normal else { return false }
            guard window.styleMask.contains(.titled) else { return false }
            return true
        }

        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            // No main window exists - open one using SwiftUI's openWindow
            openWindow(id: "main")
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
