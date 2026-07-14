import SwiftUI

/// Detailed Storage view shown in popover
struct StorageDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    @EnvironmentObject var appState: AppState
    @State private var pulseAnimation = false

    private var alertLevel: MetricAlertLevel {
        guard let usage = monitor.diskUsage else { return .normal }
        return MetricThresholds.storage(freePercent: usage.freePercentage)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header with disk name
            header

            // Usage visualization
            usageVisualization

            Divider()

            // Stats
            statsSection

            Divider()

            // Cleanup suggestions
            cleanupSuggestions

            Spacer()

            // Actions
            actionButtons
        }
        .padding()
    }

    private var header: some View {
        HStack {
            Image(systemName: "internaldrive.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Macintosh HD")
                    .font(.headline)
                Text("Internal SSD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Alert badge
            if alertLevel != .normal {
                HStack(spacing: 4) {
                    Image(systemName: alertLevel == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    Text(alertLevel == .critical ? "Low Space" : "Warning")
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(alertLevel.color, in: Capsule())
            }
        }
    }

    private var usageVisualization: some View {
        VStack(spacing: 12) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))

                    if let usage = monitor.diskUsage {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [alertLevel.color.opacity(0.8), alertLevel.color],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * (1.0 - usage.freePercentage))
                            .criticalPulse(alertLevel, isPulsing: pulseAnimation)
                            .startCriticalPulse(alertLevel, into: $pulseAnimation)
                    }
                }
            }
            .frame(height: 24)

            // Legend
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(alertLevel.color)
                        .frame(width: 8, height: 8)
                    Text("Used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text("Free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statsSection: some View {
        HStack(spacing: 20) {
            StatItem(
                label: "Used",
                value: monitor.diskUsage?.formattedUsed ?? "...",
                color: alertLevel.color
            )

            StatItem(
                label: "Free",
                value: monitor.diskUsage?.formattedFree ?? "...",
                color: .green
            )

            StatItem(
                label: "Total",
                value: monitor.diskUsage?.formattedTotal ?? "...",
                color: .gray
            )
        }
    }

    private var cleanupSuggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Cleanup")
                .font(.subheadline)
                .fontWeight(.medium)

            CleanupSuggestionRow(
                icon: "trash",
                title: "Empty Trash",
                description: "Clear deleted files",
                color: .red
            ) {
                appState.selectedFeature = .trashBins
            }

            CleanupSuggestionRow(
                icon: "gearshape.2",
                title: "System Caches",
                description: "Clear temporary files",
                color: .orange
            ) {
                appState.selectedFeature = .systemJunk
            }

            CleanupSuggestionRow(
                icon: "doc.badge.clock",
                title: "Large Items",
                description: "Find big files and folders",
                color: .purple
            ) {
                appState.selectedFeature = .largeOldFiles
            }
        }
    }

    private var actionButtons: some View {
        Button {
            appState.selectedFeature = .spaceLens
        } label: {
            Label("Open Space Lens", systemImage: "chart.pie")
                .frame(maxWidth: .infinity)
        }
        .glassButton(prominent: true)
    }
}

/// Stat item showing label and value
struct StatItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(color)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Row for cleanup suggestion
struct CleanupSuggestionRow: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    StorageDetailView(monitor: SystemMonitor())
        .environmentObject(AppState())
        .frame(width: 380, height: 450)
}

#endif
