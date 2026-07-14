import Foundation

/// Sparkle update channel: the stable appcast published with each tagged
/// release, or the rolling nightly appcast rebuilt from master by the
/// Nightly App Channel workflow.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case nightly

    /// UserDefaults key backing the Settings picker. Absent until the user
    /// makes an explicit choice, so fresh installs follow the version-derived
    /// default below.
    static let defaultsKey = "updateChannel"

    /// Marker the nightly workflow stamps into the marketing version
    /// (e.g. "1.1.1-nightly.20260713").
    static let nightlyVersionMarker = "-nightly"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return "Stable"
        case .nightly: return "Nightly (master)"
        }
    }

    /// Appcast feed for the channel. Stable returns nil so Sparkle falls back
    /// to the SUFeedURL baked into Info.plist — the production feed stays the
    /// single source of truth for stable updates.
    var feedURLString: String? {
        switch self {
        case .stable:
            return nil
        case .nightly:
            return "https://github.com/VincentShipsIt/macsweep.dev/releases/download/nightly/appcast.xml"
        }
    }

    /// Nightly installs default to the nightly channel so they keep updating
    /// themselves; release builds default to stable.
    static func defaultChannel(forVersion version: String) -> UpdateChannel {
        version.contains(nightlyVersionMarker) ? .nightly : .stable
    }

    /// Effective channel: the user's explicit Settings choice when one is
    /// stored, otherwise the version-derived default.
    static func resolved(
        defaults: UserDefaults = .standard,
        currentVersion: String = MacSweepVersion.current
    ) -> UpdateChannel {
        if let stored = defaults.string(forKey: defaultsKey),
           let choice = UpdateChannel(rawValue: stored) {
            return choice
        }
        return defaultChannel(forVersion: currentVersion)
    }
}
