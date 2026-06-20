import SwiftUI

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
    static let backgroundTop = Color(red: 0.080, green: 0.086, blue: 0.084)
    static let backgroundMid = Color(red: 0.052, green: 0.058, blue: 0.056)
    static let backgroundBottom = Color(red: 0.034, green: 0.038, blue: 0.038)
    static let panel = Color.white.opacity(0.050)
    static let panelStrong = Color.white.opacity(0.078)
    static let divider = Color.white.opacity(0.095)
    static let accent = Color(red: 0.22, green: 0.86, blue: 0.58)
    static let accentBlue = Color(red: 0.22, green: 0.52, blue: 0.84)
    static let warningPanel = Color.orange.opacity(0.12)

    static let smallRadius: CGFloat = 8
    static let mediumRadius: CGFloat = 10
}

struct MacSweepDetailBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    MacSweepTheme.backgroundTop,
                    MacSweepTheme.backgroundMid,
                    MacSweepTheme.backgroundBottom,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        MacSweepTheme.accent.opacity(0.13),
                        MacSweepTheme.accentBlue.opacity(0.04),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)

                Spacer()
            }
        }
    }
}

private struct MacSweepPanelModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(MacSweepTheme.panel, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(MacSweepTheme.divider, lineWidth: 1)
            }
    }
}

extension View {
    func macSweepDetailSurface() -> some View {
        background(MacSweepDetailBackground().ignoresSafeArea())
    }

    func macSweepPanel(radius: CGFloat = MacSweepTheme.mediumRadius) -> some View {
        modifier(MacSweepPanelModifier(radius: radius))
    }

    func macSweepListSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}

struct MacSweepEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(22)
        .frame(width: 320)
        .macSweepPanel()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
