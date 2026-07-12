import SwiftUI

// SwiftUI presentation layer for the metric-alert model that lives in
// MacSweepCore. Keeping the `Color` mapping and shared views here (out of the
// package) lets the threshold logic stay pure and testable.

extension MetricAlertLevel {
    /// Standard color for this level, used by every metric surface.
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// SF Symbol paired with this level in badges.
    var iconName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    /// Short label ("Warning" / "Critical"). `nil` for `.normal` — nothing to flag.
    var badgeText: String? {
        switch self {
        case .normal: return nil
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

extension View {
    /// Applies the unified critical-state pulse: fades opacity between
    /// `MetricThresholds.Pulse.minOpacity` and 1 while `level` is `.critical`,
    /// steady otherwise. Replaces the four hand-rolled copies that used silently
    /// divergent durations/opacities.
    func criticalPulse(_ level: MetricAlertLevel, isPulsing: Bool) -> some View {
        opacity(level == .critical && isPulsing ? MetricThresholds.Pulse.minOpacity : 1.0)
    }

    /// Starts the shared repeating pulse animation when `level` is `.critical`.
    func startCriticalPulse(_ level: MetricAlertLevel, into flag: Binding<Bool>) -> some View {
        modifier(CriticalPulseAnimationModifier(level: level, flag: flag))
    }
}

private struct CriticalPulseAnimationModifier: ViewModifier {
    let level: MetricAlertLevel
    @Binding var flag: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onAppear {
            updateAnimation()
        }
        .onChange(of: level) {
            updateAnimation()
        }
        .onChange(of: reduceMotion) {
            updateAnimation()
        }
    }

    private func updateAnimation() {
        guard level == .critical, !reduceMotion else {
            flag = false
            return
        }
        withAnimation(
            .easeInOut(duration: MetricThresholds.Pulse.duration).repeatForever(autoreverses: true)
        ) {
            flag = true
        }
    }
}

/// Unified Critical/Warning pill. The single alert-badge implementation shared by
/// the CPU, Memory, and Battery detail views (previously three incompatible
/// inline versions). Renders nothing for `.normal`.
struct AlertBadge: View {
    let level: MetricAlertLevel
    /// Overrides the label (e.g. Battery uses "Low" instead of "Warning").
    var warningText: String? = nil
    /// `.pill` = filled capsule with white text; `.stacked` = icon over text.
    var style: Style = .pill

    enum Style {
        case pill
        case stacked
    }

    var body: some View {
        if let text = displayText {
            switch style {
            case .pill:
                HStack(spacing: 4) {
                    Image(systemName: level.iconName)
                    Text(text)
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(level.color, in: Capsule())
            case .stacked:
                VStack(spacing: 4) {
                    Image(systemName: level.iconName)
                        .foregroundStyle(level.color)
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(level.color)
                }
            }
        }
    }

    private var displayText: String? {
        guard level != .normal else { return nil }
        if level == .warning, let warningText { return warningText }
        return level.badgeText
    }
}

/// Icon-over-value-over-caption stat column. Replaces the inline
/// `VStack { Image; Text; Text }` copied across the battery and network detail
/// views.
struct IconStatColumn: View {
    let icon: String
    let value: String
    let caption: String
    var color: Color = .secondary

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

extension BatteryHealthBand {
    /// Color paired with this health band.
    var color: Color {
        switch self {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }
}
