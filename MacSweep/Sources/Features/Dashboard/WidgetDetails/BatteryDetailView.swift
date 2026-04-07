import SwiftUI

/// Detailed Battery view shown in popover
struct BatteryDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var pulseAnimation = false

    private var alertLevel: MetricAlertLevel {
        MetricThresholds.battery(
            percent: monitor.batteryInfo.percentage,
            isCharging: monitor.batteryInfo.isCharging
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            // Battery indicator
            batteryIndicator

            // Status
            statusSection

            Divider()

            // Details
            detailsSection

            Spacer()

            // Tips
            tipsSection
        }
        .padding()
    }

    private var batteryIndicator: some View {
        VStack(spacing: 12) {
            // Large battery icon
            ZStack {
                // Battery outline
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                    .frame(width: 120, height: 60)

                // Battery fill
                HStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(alertLevel.color)
                        .frame(
                            width: max(4, 112 * (Double(monitor.batteryInfo.percentage) / 100)),
                            height: 52
                        )
                        .opacity(alertLevel == .critical ? (pulseAnimation ? 0.6 : 1.0) : 1.0)
                        .onAppear {
                            if alertLevel == .critical {
                                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                    pulseAnimation = true
                                }
                            }
                        }

                    Spacer(minLength: 0)
                }
                .frame(width: 112)

                // Percentage text
                Text("\(monitor.batteryInfo.percentage)%")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(monitor.batteryInfo.percentage > 20 ? .white : .primary)

                // Battery tip
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 4, height: 24)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 2)
                    )
                    .offset(x: 62)

                // Charging bolt
                if monitor.batteryInfo.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .offset(x: 40)
                }
            }

            // Status text
            Text(monitor.batteryInfo.statusText)
                .font(.headline)
                .foregroundStyle(alertLevel.color)
        }
    }

    private var statusSection: some View {
        HStack(spacing: 20) {
            // Time remaining
            if let time = monitor.batteryInfo.timeRemaining {
                VStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(formatTime(time))
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            // Power source
            VStack(spacing: 4) {
                Image(systemName: monitor.batteryInfo.isPluggedIn ? "powerplug.fill" : "battery.100")
                    .font(.title3)
                    .foregroundStyle(monitor.batteryInfo.isPluggedIn ? .green : .orange)
                Text(monitor.batteryInfo.isPluggedIn ? "AC Power" : "Battery")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("Power Source")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            // Alert indicator
            if alertLevel != .normal {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(alertLevel.color)
                    Text(alertLevel == .critical ? "Critical" : "Low")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("Battery")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var detailsSection: some View {
        VStack(spacing: 12) {
            Text("Battery Health")
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                // Health
                DetailBox(
                    icon: "heart.fill",
                    title: "Health",
                    value: monitor.batteryInfo.health != nil ? "\(monitor.batteryInfo.health!)%" : "--",
                    color: healthColor
                )

                // Cycle count
                DetailBox(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Cycles",
                    value: monitor.batteryInfo.cycleCount != nil ? "\(monitor.batteryInfo.cycleCount!)" : "--",
                    color: cycleColor
                )
            }

            // Condition
            if let health = monitor.batteryInfo.health {
                HStack {
                    Image(systemName: conditionIcon(for: health))
                        .foregroundStyle(healthColor)

                    Text(conditionText(for: health))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if alertLevel == .critical {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                    Text("Connect to power soon to avoid unexpected shutdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else if !monitor.batteryInfo.isPluggedIn && alertLevel == .warning {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.orange)
                    Text("Consider connecting to power to extend battery life.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func formatTime(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
    }

    private var healthColor: Color {
        guard let health = monitor.batteryInfo.health else { return .gray }
        if health >= 80 { return .green }
        if health >= 50 { return .orange }
        return .red
    }

    private var cycleColor: Color {
        guard let cycles = monitor.batteryInfo.cycleCount else { return .gray }
        if cycles < 500 { return .green }
        if cycles < 1000 { return .orange }
        return .red
    }

    private func conditionIcon(for health: Int) -> String {
        if health >= 80 { return "checkmark.circle.fill" }
        if health >= 50 { return "exclamationmark.circle.fill" }
        return "xmark.circle.fill"
    }

    private func conditionText(for health: Int) -> String {
        if health >= 80 { return "Battery condition is normal" }
        if health >= 50 { return "Battery may need service soon" }
        return "Battery needs service"
    }
}

/// Box showing a detail value
struct DetailBox: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#if !SWIFT_PACKAGE
#Preview {
    BatteryDetailView(monitor: SystemMonitor())
        .frame(width: 380, height: 450)
}

#endif
