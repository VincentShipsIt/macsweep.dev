import SwiftUI
import AppKit

/// Menu bar dropdown view with system stats and quick actions
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()
                .padding(.vertical, 8)

            // System Overview Grid
            systemOverviewGrid

            Divider()
                .padding(.vertical, 8)

            // Quick Actions
            quickActions

            Divider()
                .padding(.vertical, 8)

            // Footer
            footer
        }
        .padding(16)
        .frame(width: 320)
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
                onTap: { navigateToFeature(.spaceLens) }
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
                onTap: { navigateToFeature(.optimization) }
            )

            // Battery
            SystemStatCard(
                icon: monitor.batteryInfo.icon,
                title: "Battery",
                subtitle: monitor.batteryInfo.statusText,
                value: "\(monitor.batteryInfo.percentage)%",
                accentColor: batteryColor,
                onTap: { navigateToFeature(.maintenance) }
            )

            // CPU
            SystemStatCard(
                icon: "cpu",
                title: "CPU",
                subtitle: monitor.cpuUsage.formattedLoad,
                value: monitor.cpuUsage.formattedTemperature,
                valueColor: cpuTempColor,
                accentColor: .orange,
                onTap: { navigateToFeature(.optimization) }
            )

            // Wi-Fi
            SystemStatCard(
                icon: "wifi",
                title: monitor.networkUsage.ssid ?? "Wi-Fi",
                subtitle: "↓ \(monitor.networkUsage.formattedDownload)",
                secondarySubtitle: "↑ \(monitor.networkUsage.formattedUpload)",
                accentColor: .green,
                onTap: { navigateToFeature(.privacy) }
            )

            // Quick Scan
            SystemStatCard(
                icon: "magnifyingglass",
                title: "Quick Scan",
                subtitle: appState.isScanning ? "Scanning..." : "Find junk files",
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

    private func navigateToFeature(_ feature: Feature) {
        appState.selectedFeature = feature
        openMainWindow()
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
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
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

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
