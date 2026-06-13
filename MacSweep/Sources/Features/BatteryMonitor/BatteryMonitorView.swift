import SwiftUI

/// Full-screen battery monitoring view with health, cycles, and maintenance shortcuts.
struct BatteryMonitorView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var monitor = SystemMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 260)),
                    GridItem(.flexible(minimum: 260))
                ], spacing: 16) {
                    batterySummaryCard
                    quickActionsCard
                }

                BatteryDetailView(monitor: monitor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))

                insightsSection
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Battery Monitor")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Track charge state, health, cycle count, and the actions most likely to preserve runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await monitor.refresh()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .glassButton()
        }
    }

    private var batterySummaryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                BatteryGauge(
                    percentage: monitor.batteryInfo.percentage,
                    color: batteryColor
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(monitor.batteryInfo.statusText)
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(powerSourceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let timeRemaining = monitor.batteryInfo.timeRemaining,
                       !monitor.batteryInfo.isPluggedIn {
                        Label(formatTime(timeRemaining), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            HStack(spacing: 12) {
                BatteryStatCard(
                    title: "Health",
                    value: formattedHealth,
                    icon: "heart.fill",
                    tint: healthColor
                )

                BatteryStatCard(
                    title: "Cycles",
                    value: formattedCycles,
                    icon: "arrow.triangle.2.circlepath",
                    tint: cycleColor
                )

                BatteryStatCard(
                    title: "Temperature",
                    value: formattedTemperature,
                    icon: "thermometer.medium",
                    tint: temperatureColor
                )
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Actions")
                .font(.headline)

            Text("Jump to the cleanup and performance tools that matter most when battery life is degrading.")
                .font(.caption)
                .foregroundStyle(.secondary)

            BatteryActionButton(
                title: "Open Maintenance",
                subtitle: "Flush caches and run maintenance tasks",
                icon: "wrench.and.screwdriver.fill",
                tint: .orange
            ) {
                appState.selectedFeature = .maintenance
            }

            BatteryActionButton(
                title: "Open Optimization",
                subtitle: "Inspect memory pressure and heavy processes",
                icon: "slider.horizontal.3",
                tint: .blue
            ) {
                appState.selectedFeature = .optimization
            }

            BatteryActionButton(
                title: "Find Large Files",
                subtitle: "Free storage that can hurt swap-heavy workloads",
                icon: "doc.badge.clock",
                tint: .purple
            ) {
                appState.selectedFeature = .largeOldFiles
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery Health Assistant")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                insightRow(
                    icon: monitor.batteryInfo.isPluggedIn ? "powerplug.fill" : "battery.75",
                    tint: batteryColor,
                    text: monitor.batteryInfo.isPluggedIn
                        ? "Your Mac is on external power. This is a good moment to run heavier cleanup tasks."
                        : "You are on battery power. Avoid large scans if you want to maximize current runtime."
                )

                insightRow(
                    icon: "heart.text.square.fill",
                    tint: healthColor,
                    text: healthInsight
                )

                insightRow(
                    icon: "fan.fill",
                    tint: temperatureColor,
                    text: temperatureInsight
                )
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func insightRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private func formatTime(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m remaining"
        }
        return "\(mins)m remaining"
    }

    private var powerSourceText: String {
        if monitor.batteryInfo.isCharging {
            return "Charging from adapter"
        }
        if monitor.batteryInfo.isPluggedIn {
            return "Running from power adapter"
        }
        return "Running on battery"
    }

    private var formattedHealth: String {
        if let health = monitor.batteryInfo.health {
            return "\(health)%"
        }
        return "--"
    }

    private var formattedCycles: String {
        if let cycles = monitor.batteryInfo.cycleCount {
            return "\(cycles)"
        }
        return "--"
    }

    private var formattedTemperature: String {
        if let temperature = monitor.batteryInfo.temperature {
            return "\(Int(temperature.rounded()))°C"
        }
        return "--"
    }

    private var batteryColor: Color {
        if monitor.batteryInfo.isCharging || monitor.batteryInfo.isPluggedIn {
            return .green
        }
        if monitor.batteryInfo.percentage < 20 {
            return .red
        }
        if monitor.batteryInfo.percentage < 50 {
            return .orange
        }
        return .mint
    }

    private var healthColor: Color {
        guard let health = monitor.batteryInfo.health else { return .secondary }
        if health >= 80 { return .green }
        if health >= 50 { return .orange }
        return .red
    }

    private var cycleColor: Color {
        guard let cycles = monitor.batteryInfo.cycleCount else { return .secondary }
        if cycles < 500 { return .green }
        if cycles < 1000 { return .orange }
        return .red
    }

    private var temperatureColor: Color {
        guard let temperature = monitor.batteryInfo.temperature else { return .secondary }
        if temperature >= 40 { return .red }
        if temperature >= 32 { return .orange }
        return .mint
    }

    private var healthInsight: String {
        guard let health = monitor.batteryInfo.health else {
            return "Battery health details are limited on this Mac, but cycle count and charge state are still available."
        }

        if health >= 80 {
            return "Battery health looks solid. Focus on limiting heat and unnecessary background work to keep it there."
        }
        if health >= 50 {
            return "Battery health is starting to age. It makes sense to reduce heavy background activity and monitor cycles more closely."
        }
        return "Battery health is degraded. Expect shorter runtime and consider service planning if this is your main machine."
    }

    private var temperatureInsight: String {
        guard let temperature = monitor.batteryInfo.temperature else {
            return "No direct battery temperature reading is available, so use CPU temperature and fan noise as rough warning signs."
        }

        if temperature >= 40 {
            return "Battery temperature is elevated. Avoid running deep scans and other sustained heavy tasks until the Mac cools down."
        }
        if temperature >= 32 {
            return "Battery temperature is acceptable but climbing. Keep an eye on it during long cleanup or indexing sessions."
        }
        return "Battery temperature is comfortably within a healthy operating range."
    }
}

private struct BatteryGauge: View {
    let percentage: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.14), lineWidth: 14)

            Circle()
                .trim(from: 0, to: Double(percentage) / 100)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 2) {
                Text("\(percentage)%")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Text("Charge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 132, height: 132)
    }
}

private struct BatteryStatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)

            Text(value)
                .font(.headline)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct BatteryActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    BatteryMonitorView()
        .environmentObject(AppState())
        .frame(width: 900, height: 700)
}

#endif
