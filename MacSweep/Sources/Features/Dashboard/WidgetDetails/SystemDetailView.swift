import SwiftUI

/// Detailed Mac-overview view shown in popover
struct SystemDetailView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(spacing: 16) {
            header

            Divider()

            overviewBoxes

            Divider()

            detailRows

            Spacer(minLength: 0)
        }
        .padding()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(Host.current().localizedName ?? "Mac")
                    .font(.headline)
                    .lineLimit(1)

                Text(macOSVersion)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
            }

            Spacer()

            Image(systemName: "desktopcomputer")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    private var overviewBoxes: some View {
        HStack(spacing: 16) {
            DetailBox(
                icon: "memorychip",
                title: "Memory",
                value: formattedMemoryTotal,
                color: .blue
            )

            DetailBox(
                icon: "internaldrive",
                title: "Storage",
                value: monitor.diskUsage?.formattedTotal ?? "--",
                color: .purple
            )
        }
    }

    private var detailRows: some View {
        VStack(spacing: 8) {
            SystemInfoRow(label: "Chip", value: monitor.chipName)
            SystemInfoRow(label: "macOS", value: Foundation.ProcessInfo.processInfo.operatingSystemVersionString)
            if let free = monitor.diskUsage?.formattedFree {
                SystemInfoRow(label: "Storage Available", value: free)
            }
            SystemInfoRow(label: "Uptime", value: formattedUptime)
        }
    }

    private var macOSVersion: String {
        let version = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var formattedMemoryTotal: String {
        guard monitor.memoryUsage.total > 0 else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(monitor.memoryUsage.total), countStyle: .memory)
    }

    private var formattedUptime: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: Foundation.ProcessInfo.processInfo.systemUptime) ?? "--"
    }
}

/// Simple label/value row for static system facts
private struct SystemInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    SystemDetailView(monitor: SystemMonitor())
        .frame(width: 380, height: 450)
}

#endif
