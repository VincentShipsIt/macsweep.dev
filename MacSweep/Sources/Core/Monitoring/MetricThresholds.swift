import Foundation

/// Semantic alert level for a system metric. The single source of truth for
/// "is this value normal / warning / critical", shared by every surface
/// (menu-bar cards, dashboard rows, detail popovers) so a metric can't flip to
/// "critical" at one boundary here and a different boundary there.
///
/// Pure logic — no SwiftUI. The `Color` mapping lives in the view layer so this
/// stays inside the testable package graph (see issue #120). Boundary constants
/// and the critical-pulse animation constants live here too, so the numbers are
/// unit-testable and defined exactly once.
public enum MetricAlertLevel: String, Sendable {
    case normal
    case warning
    case critical
}

public enum MetricThresholds {

    // MARK: - Boundary constants (the intended, unified values)

    public enum CPU {
        /// Usage % at/above which the CPU is critical / warning.
        public static let criticalUsage: Double = 90
        public static let warningUsage: Double = 70
        /// Temperature °C above which the CPU is critical / warning.
        public static let criticalTemperature: Double = 80
        public static let warningTemperature: Double = 60
    }

    public enum Memory {
        /// Used fraction (0...1) at/above which memory is critical / warning.
        public static let criticalUsedFraction: Double = 0.90
        public static let warningUsedFraction: Double = 0.75
    }

    public enum Storage {
        /// Free fraction (0...1) below which storage is critical / warning.
        public static let criticalFreeFraction: Double = 0.10
        public static let warningFreeFraction: Double = 0.20
    }

    public enum Battery {
        /// Charge % below which the battery is critical / warning (when discharging).
        public static let criticalPercent: Int = 20
        public static let warningPercent: Int = 50
    }

    public enum Score {
        /// Aggregate 0...100 health score (higher is better) at/above which the
        /// state is good (normal) / fair (warning).
        public static let goodScore: Int = 85
        public static let fairScore: Int = 65
    }

    public enum Capacity {
        /// Remaining charge % at/below which a battery-backed device is critical /
        /// warning (higher is better). Used for the lowest connected-device battery.
        public static let criticalPercent: Int = 10
        public static let warningPercent: Int = 20
    }

    /// Critical-state "pulse" animation, unified across every detail view (the
    /// pulse was previously copy-pasted with silently divergent duration/opacity).
    public enum Pulse {
        public static let duration: Double = 0.6
        public static let minOpacity: Double = 0.7
    }

    // MARK: - Level functions

    public static func cpu(usage: Double, temperature: Double?) -> MetricAlertLevel {
        let temp = temperature ?? 0
        if usage >= CPU.criticalUsage || temp > CPU.criticalTemperature { return .critical }
        if usage >= CPU.warningUsage || temp > CPU.warningTemperature { return .warning }
        return .normal
    }

    /// Alert level for a CPU temperature alone (used where only the temperature
    /// readout is colored, e.g. the menu-bar CPU card and dashboard CPU row).
    public static func cpuTemperature(_ temperature: Double?) -> MetricAlertLevel {
        guard let temp = temperature else { return .normal }
        if temp > CPU.criticalTemperature { return .critical }
        if temp > CPU.warningTemperature { return .warning }
        return .normal
    }

    public static func memory(usagePercent: Double) -> MetricAlertLevel {
        if usagePercent >= Memory.criticalUsedFraction { return .critical }
        if usagePercent >= Memory.warningUsedFraction { return .warning }
        return .normal
    }

    public static func storage(freePercent: Double) -> MetricAlertLevel {
        if freePercent < Storage.criticalFreeFraction { return .critical }
        if freePercent < Storage.warningFreeFraction { return .warning }
        return .normal
    }

    public static func battery(percent: Int, isCharging: Bool, hasBattery: Bool = true) -> MetricAlertLevel {
        guard hasBattery else { return .normal }
        if isCharging { return .normal }
        if percent < Battery.criticalPercent { return .critical }
        if percent < Battery.warningPercent { return .warning }
        return .normal
    }

    /// Alert level for an aggregate 0...100 health score (higher is better), e.g.
    /// the Smart Care dashboard score. Shares boundaries with every score readout
    /// so "healthy" means the same everywhere.
    public static func score(_ value: Int) -> MetricAlertLevel {
        if value >= Score.goodScore { return .normal }
        if value >= Score.fairScore { return .warning }
        return .critical
    }

    /// Alert level for remaining charge % (higher is better), e.g. the lowest
    /// connected-device battery in the menu-bar companion.
    public static func capacity(percent: Int) -> MetricAlertLevel {
        if percent <= Capacity.criticalPercent { return .critical }
        if percent <= Capacity.warningPercent { return .warning }
        return .normal
    }
}

/// Battery-health banding, derived once from the health percentage. Replaces the
/// three separate re-derivations (color, icon, condition text) that previously
/// each hard-coded the >=80 / >=50 boundaries in BatteryDetailView.
public enum BatteryHealthBand: Sendable {
    case good      // >= 80%
    case fair      // >= 50%
    case poor      // < 50%

    public static let goodThreshold: Int = 80
    public static let fairThreshold: Int = 50

    public init(health: Int) {
        if health >= Self.goodThreshold {
            self = .good
        } else if health >= Self.fairThreshold {
            self = .fair
        } else {
            self = .poor
        }
    }

    public var iconName: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .fair: return "exclamationmark.circle.fill"
        case .poor: return "xmark.circle.fill"
        }
    }

    public var conditionText: String {
        switch self {
        case .good: return "Battery condition is normal"
        case .fair: return "Battery may need service soon"
        case .poor: return "Battery needs service"
        }
    }
}
