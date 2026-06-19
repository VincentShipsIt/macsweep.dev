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
