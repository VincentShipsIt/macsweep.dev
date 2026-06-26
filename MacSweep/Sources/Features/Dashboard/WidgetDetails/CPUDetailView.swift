import SwiftUI

/// Detailed CPU view shown in popover
struct CPUDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var processMonitor = ProcessMonitor()
    @State private var pulseAnimation = false

    private var alertLevel: MetricAlertLevel {
        MetricThresholds.cpu(usage: monitor.cpuUsage.total, temperature: monitor.cpuUsage.temperature)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header with chip name and temperature
            header

            Divider()

            // Real-time graph
            graphSection

            // Usage breakdown
            usageBreakdown

            Divider()

            // Top CPU consumers
            topConsumers
        }
        .padding()
        .task {
            await processMonitor.startMonitoring()
        }
        .onDisappear {
            // Stop the 5s ps-sampling timer when the popover closes, else it leaks
            // and keeps spawning subprocesses after the view is gone.
            processMonitor.stopMonitoring()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.chipName)
                    .font(.headline)
                    .lineLimit(1)

                if let temp = monitor.cpuUsage.formattedTemperature {
                    Text(temp)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(temperatureColor)
                        .opacity(alertLevel == .critical ? (pulseAnimation ? 0.7 : 1.0) : 1.0)
                        .onAppear {
                            if alertLevel == .critical {
                                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                    pulseAnimation = true
                                }
                            }
                        }
                } else {
                    Text("--°C")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Alert badge
            if alertLevel != .normal {
                alertBadge
            }
        }
    }

    private var alertBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: alertLevel == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
            Text(alertLevel == .critical ? "Critical" : "Warning")
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(alertLevel.color, in: Capsule())
    }

    private var graphSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CPU Usage")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text("\(Int(monitor.cpuUsage.total))%")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(alertLevel.color)
            }

            MetricGraph(
                data: monitor.cpuHistory,
                warningThreshold: 70,
                criticalThreshold: 90,
                color: .orange
            )
            .frame(height: 80)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var usageBreakdown: some View {
        HStack(spacing: 16) {
            UsagePill(label: "User", value: monitor.cpuUsage.user, color: .blue)
            UsagePill(label: "System", value: monitor.cpuUsage.system, color: .red)
            UsagePill(label: "Idle", value: monitor.cpuUsage.idle, color: .green)
        }
    }

    private var topConsumers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top CPU Consumers")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(processMonitor.topByCPU(limit: 5)) { process in
                ProcessConsumerRow(process: process, metric: .cpu)
            }

            if processMonitor.processes.isEmpty {
                Text("Loading processes...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    private var temperatureColor: Color {
        guard let temp = monitor.cpuUsage.temperature else { return .primary }
        if temp > 80 { return .red }
        if temp > 60 { return .orange }
        return .green
    }
}

/// Colored pill showing a usage percentage
struct UsagePill: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f%%", value))
                .font(.system(.caption, design: .rounded))
                .fontWeight(.semibold)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Row showing a process's resource usage
struct ProcessConsumerRow: View {
    let process: RunningProcess
    let metric: ProcessMetric

    enum ProcessMetric {
        case cpu, memory
    }

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app")
                    .frame(width: 20, height: 20)
            }

            // Name
            Text(process.name)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            // Usage value
            Text(metric == .cpu ? process.formattedCPU : process.formattedMemory)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(usageColor)

            // Quit button
            Button {
                quitProcess()
            } label: {
                Text("Quit")
                    .font(.caption2)
            }
            .glassButton()
            .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }

    private var usageColor: Color {
        switch metric {
        case .cpu:
            if process.cpuPercent > 50 { return .red }
            if process.cpuPercent > 20 { return .orange }
            return .primary
        case .memory:
            if process.memoryMB > 1024 { return .red }
            if process.memoryMB > 512 { return .orange }
            return .primary
        }
    }

    private func quitProcess() {
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            app.terminate()
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    CPUDetailView(monitor: SystemMonitor())
        .frame(width: 380, height: 450)
}

#endif
