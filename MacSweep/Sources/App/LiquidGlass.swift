import SwiftUI
import AppKit

// Centralized Liquid Glass (macOS 26 "Tahoe") helpers.
//
// MacSweep's minimum deployment target is macOS 26, so the Liquid Glass APIs are
// always available — there is no availability gating or pre-26 fallback here.
// Standard components (NavigationSplitView sidebars, .toolbar, List(.sidebar)
// selection, sheets, default Button) adopt Liquid Glass automatically just by
// building against the macOS 26 SDK; these helpers cover only the cases the
// system does NOT give us for free — genuinely custom controls and the explicit
// primary/secondary button styling.
//
// Design rule (Apple HIG / WWDC25 "Meet Liquid Glass"): glass is the
// navigation/control layer that floats above content, not wallpaper. Reserve it
// for chrome and prominent controls; leave content cards, rows, and result lists
// on standard materials. See `.agents/skills/liquid-glass/SKILL.md` for the full
// guidance.

// MARK: - Glass factory

enum LiquidGlass {
    /// Build a `Glass` value with optional tint / interactivity.
    /// Tint is an accent — use sparingly (tinting everything makes nothing stand
    /// out). `interactive` belongs only on tappable controls.
    static func make(tint: Color? = nil, interactive: Bool = false) -> Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - Button styling

/// Applies the native Liquid Glass button style. `prominent` selects the single
/// primary call-to-action treatment (`.glassProminent`); otherwise the secondary
/// glass treatment (`.glass`).
private struct GlassButtonModifier: ViewModifier {
    let prominent: Bool

    /// Selects the prominent glass style for the single primary action, or the
    /// standard glass style for secondary actions.
    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

// MARK: - Custom-control glass

/// Applies a raw `.glassEffect` clipped to `shape`. For genuinely custom controls
/// (floating pills, circular action buttons) — NOT for content cards, which stay
/// on standard materials.
private struct GlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    /// Applies the configured glass material clipped to `shape`.
    func body(content: Content) -> some View {
        content.glassEffect(
            LiquidGlass.make(tint: tint, interactive: interactive),
            in: shape
        )
    }
}

extension View {
    /// Native Liquid Glass button style. Use `prominent: true` for the one primary
    /// action in a view; leave it `false` for secondary / toolbar actions.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonModifier(prominent: prominent))
    }

    /// Liquid Glass material on a custom control shape. Pass `interactive: true`
    /// only when the control is tappable.
    func glassControl<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(GlassControlModifier(shape: shape, tint: tint, interactive: interactive))
    }
}

// MARK: - App Surface Theme

enum MacSweepTheme {
    static let panel = Color.adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.035),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.045),
        lightHighContrast: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
        darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
    )
    static let panelStrong = Color.adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.055),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.075),
        lightHighContrast: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10),
        darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
    )
    static let cardTint = Color.adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.055),
        lightHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28),
        darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
    )
    static let cardStroke = Color.adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15),
        lightHighContrast: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24),
        darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28)
    )
    static let companionTint = Color.adaptive(
        light: NSColor(srgbRed: 0.50, green: 0.66, blue: 0.72, alpha: 0.16),
        dark: NSColor(srgbRed: 0.08, green: 0.20, blue: 0.24, alpha: 0.18),
        lightHighContrast: NSColor(srgbRed: 0.50, green: 0.66, blue: 0.72, alpha: 0.20),
        darkHighContrast: NSColor(srgbRed: 0.08, green: 0.20, blue: 0.24, alpha: 0.20)
    )
    static let companionCardTint = Color.adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.24),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07),
        lightHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.34),
        darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13)
    )
    static let companionCardStroke = Color.adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06),
        lightHighContrast: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14),
        darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16)
    )
    static let accent = Color(red: 0.22, green: 0.86, blue: 0.58)
    static let accentBlue = Color(red: 0.22, green: 0.52, blue: 0.84)
    static let warningPanel = Color.orange.opacity(0.12)

    /// The single selection accent — the checkmark tint on every selectable row
    /// and the fill behind a selected card. Centralizes the `.blue` that the row
    /// structs and category cards used to hardcode.
    static let selection = Color.blue
    static let selectionFill = Color.blue.opacity(0.1)

    static let smallRadius: CGFloat = 8
    static let mediumRadius: CGFloat = 10
}

struct MacSweepCompanionSurface: View {
    var radius: CGFloat = 16
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        shape
            .fill(reduceTransparency
                  ? Color(nsColor: .windowBackgroundColor)
                  : Color(nsColor: .controlBackgroundColor))
            .overlay {
                if !reduceTransparency {
                    shape.fill(MacSweepTheme.companionTint)
                }
            }
            .overlay {
                LinearGradient(
                    colors: [
                        MacSweepTheme.accentBlue.opacity(reduceTransparency ? 0.06 : 0.14),
                        MacSweepTheme.accent.opacity(0.08),
                        .clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(shape)
            }
            .overlay {
                shape.stroke(MacSweepTheme.cardStroke, lineWidth: 1)
            }
    }
}

private struct MacSweepCardModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background {
                shape.fill(reduceTransparency
                           ? Color(nsColor: .windowBackgroundColor)
                           : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                shape.stroke(MacSweepTheme.cardStroke, lineWidth: 0.6)
            }
    }
}

/// The companion popover has a translucent, tinted shell, so its compact cards
/// use a lighter material surface that lets that context show through. Regular
/// app content continues to use the semantic, non-glass `macSweepCard` fill.
private struct MacSweepCompanionCardModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay {
                if !reduceTransparency {
                    shape.fill(MacSweepTheme.companionCardTint)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.stroke(MacSweepTheme.companionCardStroke, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func macSweepCard(radius: CGFloat = MacSweepTheme.mediumRadius) -> some View {
        modifier(MacSweepCardModifier(radius: radius))
    }

    func macSweepCompanionCard(radius: CGFloat = MacSweepTheme.mediumRadius) -> some View {
        modifier(MacSweepCompanionCardModifier(radius: radius))
    }

    func macSweepListSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}

extension Color {
    static func adaptive(
        light: NSColor,
        dark: NSColor,
        lightHighContrast: NSColor? = nil,
        darkHighContrast: NSColor? = nil
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                switch appearance.bestMatch(from: [
                    .aqua,
                    .darkAqua,
                    .accessibilityHighContrastAqua,
                    .accessibilityHighContrastDarkAqua,
                ]) {
                case .darkAqua:
                    return dark
                case .accessibilityHighContrastAqua:
                    return lightHighContrast ?? light
                case .accessibilityHighContrastDarkAqua:
                    return darkHighContrast ?? dark
                default:
                    return light
                }
            }
        )
    }
}
