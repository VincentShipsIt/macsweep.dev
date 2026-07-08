import SwiftUI

/// List of connected Bluetooth peripherals and their battery levels.
/// Shared by the dashboard popover, the Battery Monitor page, and the menu bar.
struct ConnectedDevicesDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    /// When false (menu bar / inline use), the internal scroll + header are dropped
    /// so the host view controls layout.
    var showsHeader = true
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                header
            }

            if monitor.connectedDevices.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(monitor.connectedDevices) { device in
                        ConnectedDeviceRow(device: device)
                    }
                }
            }
        }
        .padding(showsHeader ? 16 : 0)
    }

    private var header: some View {
        HStack {
            Text("Connected Devices")
                .font(.headline)

            Spacer()

            Button {
                Task {
                    isRefreshing = true
                    await monitor.refreshConnectedDevices()
                    isRefreshing = false
                }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isRefreshing)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary)
            Text("No connected devices are reporting battery.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }
}

/// One peripheral row: icon, name/type, and per-cell battery gauges.
struct ConnectedDeviceRow: View {
    let device: ConnectedDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.iconName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(device.typeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                if device.batteryLeft != nil || device.batteryRight != nil || device.batteryCase != nil {
                    if let left = device.batteryLeft {
                        BatteryPill(label: "L", percent: left)
                    }
                    if let right = device.batteryRight {
                        BatteryPill(label: "R", percent: right)
                    }
                    if let caseLevel = device.batteryCase {
                        BatteryPill(label: "Case", percent: caseLevel)
                    }
                } else if let single = device.battery {
                    BatteryPill(label: nil, percent: single)
                }
            }
        }
        .padding(10)
        .macSweepCard(radius: 12)
    }
}

/// A small battery gauge: a colored ring with the percentage, optionally labeled
/// (L / R / Case for multi-cell devices like AirPods).
struct BatteryPill: View {
    let label: String?
    let percent: Int

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, Double(percent) / 100))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(width: 34, height: 34)

            if let label {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { "\($0) battery" } ?? "Battery")
        .accessibilityValue("\(percent) percent")
    }

    private var color: Color {
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return .green
    }
}

#if !SWIFT_PACKAGE
#Preview {
    ConnectedDevicesDetailView(monitor: SystemMonitor())
        .frame(width: 380, height: 300)
}
#endif
