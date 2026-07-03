import SwiftUI

/// Detailed Battery view shown in popover
struct BatteryDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var pulseAnimation = false

    private var alertLevel: MetricAlertLevel {
        MetricThresholds.battery(
            percent: monitor.batteryInfo.percentage,
            isCharging: monitor.batteryInfo.isCharging,
            hasBattery: monitor.batteryInfo.hasBattery
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

    @ViewBuilder
    private var batteryIndicator: some View {
        if !monitor.batteryInfo.hasBattery {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.35), lineWidth: 3)
                        .frame(width: 120, height: 60)

                    Image(systemName: "powerplug.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.green)
                }

                Text("Desktop Power")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
        } else {
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
                        .criticalPulse(alertLevel, isPulsing: pulseAnimation)
                        .startCriticalPulse(alertLevel, into: $pulseAnimation)

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
    }

    private var statusSection: some View {
        HStack(spacing: 20) {
            // Time remaining
            if let time = monitor.batteryInfo.timeRemaining {
                IconStatColumn(
                    icon: "clock",
                    value: formatTime(time),
                    caption: "Remaining"
                )
            }

            // Power source
            IconStatColumn(
                icon: monitor.batteryInfo.isPluggedIn ? "powerplug.fill" : "battery.100",
                value: monitor.batteryInfo.hasBattery ? (monitor.batteryInfo.isPluggedIn ? "AC Power" : "Battery") : "AC Power",
                caption: "Power Source",
                color: monitor.batteryInfo.isPluggedIn ? .green : .orange
            )

            // Alert indicator
            if alertLevel != .normal {
                IconStatColumn(
                    icon: "exclamationmark.triangle.fill",
                    value: alertLevel == .critical ? "Critical" : "Low",
                    caption: "Battery",
                    color: alertLevel.color
                )
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
            if !monitor.batteryInfo.hasBattery {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.green)

                    Text("This Mac has no internal battery, so health and cycle metrics do not apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.top, 4)
            } else if let health = monitor.batteryInfo.health {
                let band = BatteryHealthBand(health: health)
                HStack {
                    Image(systemName: band.iconName)
                        .foregroundStyle(band.color)

                    Text(band.conditionText)
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
            if !monitor.batteryInfo.hasBattery {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.green)
                    Text("Mac Studio runs from external power, so battery runtime warnings are hidden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else if alertLevel == .critical {
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
        monitor.batteryInfo.health.map { BatteryHealthBand(health: $0).color } ?? .gray
    }

    private var cycleColor: Color {
        guard let cycles = monitor.batteryInfo.cycleCount else { return .gray }
        if cycles < 500 { return .green }
        if cycles < 1000 { return .orange }
        return .red
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
