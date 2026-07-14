import SwiftUI

struct OptimizationSystemStats: View {
    @ObservedObject var systemMonitor: SystemMonitor
    let processCount: Int
    let isFreeingRAM: Bool
    let onFreeUpRAM: () -> Void

    private var memoryAlertLevel: MetricAlertLevel {
        systemMonitor.memoryUsage.pressureLevel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                memoryGauge
                memoryDetails

                Divider()
                    .frame(height: 80)

                cpuGauge
                cpuDetails

                Spacer()
                processCountAndMemoryAction
            }

            HStack(alignment: .top, spacing: 8) {
                Label(memoryPressureTitle, systemImage: memoryAlertLevel.iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(memoryAlertLevel.color)

                Text(memoryPressureGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var memoryGauge: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: systemMonitor.memoryUsage.usedPercentage)
                    .stroke(memoryAlertLevel.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))

                Text("\(Int(systemMonitor.memoryUsage.usedPercentage * 100))%")
                    .font(.headline)
            }

            Text("Memory Pressure")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var memoryDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            MemoryStatRow(label: "Used", value: systemMonitor.memoryUsage.formattedUsed, color: .blue)
            MemoryStatRow(label: "Wired", value: systemMonitor.memoryUsage.formattedWired, color: .red)
            MemoryStatRow(label: "Compressed", value: systemMonitor.memoryUsage.formattedCompressed, color: .orange)
            MemoryStatRow(label: "Free", value: systemMonitor.memoryUsage.formattedFree, color: .green)
        }
    }

    private var cpuGauge: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: min(1.0, systemMonitor.cpuUsage.total / 100))
                    .stroke(cpuColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))

                Text("\(Int(systemMonitor.cpuUsage.total))%")
                    .font(.headline)
            }

            Text("CPU")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cpuDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            CPUStatRow(label: "User", value: systemMonitor.cpuUsage.user, color: .blue)
            CPUStatRow(label: "System", value: systemMonitor.cpuUsage.system, color: .red)
            CPUStatRow(label: "Idle", value: systemMonitor.cpuUsage.idle, color: .green)
        }
    }

    private var processCountAndMemoryAction: some View {
        VStack(spacing: 8) {
            Text("\(processCount)")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Processes")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: onFreeUpRAM) {
                Label(isFreeingRAM ? "Freeing RAM" : "Free Up RAM", systemImage: "memorychip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacSweepTheme.accent)
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .glassButton()
            .controlSize(.small)
            .disabled(isFreeingRAM)
            .help("Requests administrator approval to purge inactive memory. Running apps stay open.")
        }
        .frame(minWidth: 132, alignment: .trailing)
    }

    private var memoryPressureTitle: String {
        switch memoryAlertLevel {
        case .normal: return "Memory pressure is normal"
        case .warning: return "Memory pressure is elevated"
        case .critical: return "Memory pressure is critical"
        }
    }

    private var memoryPressureGuidance: String {
        switch memoryAlertLevel {
        case .normal:
            return "No action is needed. macOS is managing available memory normally."
        case .warning:
            return "Quit an app only after saving its work, or purge inactive memory without closing apps."
        case .critical:
            return "Save work before quitting heavy apps; Force Quit can discard unsaved changes."
        }
    }

    private var cpuColor: Color {
        let usage = systemMonitor.cpuUsage.total
        if usage > 80 { return .red }
        if usage > 50 { return .orange }
        return .green
    }
}
