import SwiftUI

/// Detailed Network view shown in popover
struct NetworkDetailView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(spacing: 16) {
            // Connection status
            connectionStatus

            Divider()

            // Speed meters
            speedMeters

            // Traffic graph
            trafficGraph

            Divider()

            // Connection details
            connectionDetails

            Spacer()
        }
        .padding()
    }

    private var connectionStatus: some View {
        HStack(spacing: 16) {
            // Wi-Fi icon
            ZStack {
                Circle()
                    .fill(monitor.networkUsage.isConnected ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                    .frame(width: 60, height: 60)

                Image(systemName: monitor.networkUsage.isConnected ? "wifi" : "wifi.slash")
                    .font(.title)
                    .foregroundStyle(monitor.networkUsage.isConnected ? .green : .red)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.networkUsage.ssid ?? "Not Connected")
                    .font(.headline)

                if monitor.networkUsage.isConnected {
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("No network connection")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let interface = monitor.networkUsage.interfaceName {
                    Text("Interface: \(interface)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private var speedMeters: some View {
        HStack(spacing: 16) {
            // Download
            SpeedMeter(
                icon: "arrow.down.circle.fill",
                label: "Download",
                speed: monitor.networkUsage.downloadSpeed,
                color: .green
            )

            // Upload
            SpeedMeter(
                icon: "arrow.up.circle.fill",
                label: "Upload",
                speed: monitor.networkUsage.uploadSpeed,
                color: .blue
            )
        }
    }

    private var trafficGraph: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Network Activity")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                // Legend
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                        Text("Up")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DualLineGraph(
                downloadData: monitor.networkDownloadHistory,
                uploadData: monitor.networkUploadHistory
            )
            .frame(height: 80)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Stats")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 16) {
                // Total downloaded
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.title3)
                        .foregroundStyle(.green)
                    Text(formatBytes(monitor.networkUsage.totalDownloaded))
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("Downloaded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                // Total uploaded
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text(formatBytes(monitor.networkUsage.totalUploaded))
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("Uploaded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Speed meter showing download/upload speed
struct SpeedMeter: View {
    let icon: String
    let label: String
    let speed: UInt64
    let color: Color

    private var formattedSpeed: String {
        let kbps = Double(speed) / 1024
        if kbps < 1 {
            return "0 KB/s"
        } else if kbps < 1024 {
            return String(format: "%.1f KB/s", kbps)
        } else {
            return String(format: "%.1f MB/s", kbps / 1024)
        }
    }

    private var speedLevel: SpeedLevel {
        let mbps = Double(speed) / (1024 * 1024)
        if mbps > 10 { return .fast }
        if mbps > 1 { return .moderate }
        return .slow
    }

    enum SpeedLevel {
        case slow, moderate, fast

        var description: String {
            switch self {
            case .slow: return "Slow"
            case .moderate: return "Good"
            case .fast: return "Fast"
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(formattedSpeed)
                .font(.system(.body, design: .rounded))
                .fontWeight(.semibold)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    NetworkDetailView(monitor: SystemMonitor())
        .frame(width: 380, height: 450)
}
