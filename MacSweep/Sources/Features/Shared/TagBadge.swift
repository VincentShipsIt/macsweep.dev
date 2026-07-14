import SwiftUI

// The one capsule "tag / status label" used across the feature pages. Before
// this, every page hand-rolled its own `Text(...).padding().background(color
// .opacity(0.x), in: Capsule())` with slightly different padding, opacity, and
// corner treatment. `TagBadge` unifies the *styling mechanism* and snaps the
// colors to `MacSweepTheme` semantic tints, while preserving each badge's
// meaning (danger stays red, warning orange, success green, …).
//
// These are STATIC status labels, not controls — so they stay on standard
// materials, never Liquid Glass. Glass is the navigation/control layer; a
// tappable chip would use `.glassControl(...)` instead (see
// `.agents/skills/liquid-glass/SKILL.md`). Keep `TagBadge` non-interactive.

// MARK: - Role

/// Semantic meaning of a badge, mapped to a `MacSweepTheme` tint in one place so
/// "danger" is always the same red, "success" the same green, etc. Callers with
/// a genuinely categorical / dynamic color (per-mail-client, per-threat-level)
/// use the explicit-`tint` initializer instead of forcing a role.
enum TagRole {
    case neutral
    case info
    case success
    case warning
    case danger

    var tint: Color {
        switch self {
        case .neutral: MacSweepTheme.neutralTint
        case .info:    MacSweepTheme.infoTint
        case .success: MacSweepTheme.successTint
        case .warning: MacSweepTheme.warningTint
        case .danger:  MacSweepTheme.dangerTint
        }
    }
}

// MARK: - Prominence

/// Visual weight of a badge.
enum TagProminence {
    /// Translucent tint fill + tinted text. The default, used by most status
    /// labels ("Connected", algorithm tags, leftover types).
    case soft
    /// Solid tint fill + white text. For the loud, attention-grabbing badges
    /// (outdated counts, "Breaking" warnings).
    case strong
    /// No fill — just the tinted icon + text as an inline label (the old
    /// `InfoBadge`). Reads as annotation, not a pill.
    case plain
}

// MARK: - Badge

/// A compact status label: optional SF Symbol + optional text, tinted by a
/// semantic `TagRole` (or an explicit color) at one consistent size, padding,
/// corner radius, and opacity.
struct TagBadge: View {
    var text: String?
    var icon: String?
    var tint: Color
    var prominence: TagProminence

    /// Consistent capsule tokens shared by every badge.
    private static let font = Font.caption2.weight(.semibold)
    private static let hPadding: CGFloat = 7
    private static let vPadding: CGFloat = 2
    private static let softFillOpacity: Double = 0.18
    private static let strongFillOpacity: Double = 0.9

    /// Semantic badge: pick a `TagRole` and it resolves to the themed tint.
    init(
        _ text: String? = nil,
        icon: String? = nil,
        role: TagRole = .neutral,
        prominence: TagProminence = .soft
    ) {
        self.text = text
        self.icon = icon
        self.tint = role.tint
        self.prominence = prominence
    }

    /// Explicit-tint badge, for categorical/dynamic colors that don't map to a
    /// single semantic role (e.g. per-mail-client source colors, a
    /// `ThreatLevel.color`). Prefer the role initializer where a role fits.
    init(
        _ text: String? = nil,
        icon: String? = nil,
        tint: Color,
        prominence: TagProminence = .soft
    ) {
        self.text = text
        self.icon = icon
        self.tint = tint
        self.prominence = prominence
    }

    var body: some View {
        let label = HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            if let text { Text(text) }
        }
        .font(Self.font)
        .accessibilityElement(children: .combine)

        switch prominence {
        case .soft:
            label
                .foregroundStyle(tint)
                .padding(.horizontal, Self.hPadding)
                .padding(.vertical, Self.vPadding)
                .background(tint.opacity(Self.softFillOpacity), in: Capsule())
        case .strong:
            label
                .foregroundStyle(.white)
                .padding(.horizontal, Self.hPadding)
                .padding(.vertical, Self.vPadding)
                .background(tint.opacity(Self.strongFillOpacity), in: Capsule())
        case .plain:
            label.foregroundStyle(tint)
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
            TagBadge("Connected", role: .success)
            TagBadge("ed25519", role: .info)
            TagBadge("Hashed", role: .warning)
            TagBadge("Cache", role: .neutral)
        }
        HStack(spacing: 8) {
            TagBadge("12 outdated", role: .warning, prominence: .strong)
            TagBadge("Breaking", icon: "exclamationmark.triangle.fill",
                     role: .danger, prominence: .strong)
        }
        HStack(spacing: 8) {
            TagBadge("Cannot be undone", icon: "exclamationmark.triangle",
                     role: .warning, prominence: .plain)
            TagBadge("Use FileVault", icon: "lock.shield",
                     role: .success, prominence: .plain)
        }
        HStack(spacing: 8) {
            TagBadge("Spark", tint: .orange)
            TagBadge("Images", tint: .green)
        }
    }
    .padding()
}
#endif
