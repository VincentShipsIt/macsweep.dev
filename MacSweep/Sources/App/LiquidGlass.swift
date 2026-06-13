import SwiftUI

// Centralized Liquid Glass (macOS 26 "Tahoe") helpers.
//
// MacSweep deploys to macOS 13 but builds against the macOS 26 SDK, so standard
// components (NavigationSplitView sidebars, .toolbar, List(.sidebar) selection,
// default Button) already adopt Liquid Glass automatically. These helpers cover
// the cases the system does NOT give us for free — genuinely custom controls and
// the explicit primary/secondary button styling — while keeping every
// `if #available(macOS 26.0, *)` gate in this one file.
//
// Design rule (Apple HIG): glass is the navigation/control layer, not wallpaper.
// Use these on chrome and prominent controls; leave content cards on standard
// materials. See `.claude/skills/liquid-glass/SKILL.md` for the full guidance.

// MARK: - Glass factory (26+ only)

@available(macOS 26.0, *)
enum LiquidGlass {
    /// Build a `Glass` value with optional tint / interactivity.
    /// Tint is an accent — use sparingly. `interactive` belongs only on tappables.
    static func make(tint: Color? = nil, interactive: Bool = false) -> Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - Button styling

/// Applies the native Liquid Glass button style on macOS 26+, falling back to the
/// closest bordered style on older systems. `prominent` selects the single primary
/// call-to-action treatment (`.glassProminent` / `.borderedProminent`).
private struct GlassButtonModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Custom-control glass

/// Applies a raw `.glassEffect` clipped to `shape` on macOS 26+, with an
/// `.ultraThinMaterial` fallback below. For genuinely custom controls (floating
/// pills, circular action buttons) — NOT for content cards.
private struct GlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                LiquidGlass.make(tint: tint, interactive: interactive),
                in: shape
            )
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// Native Liquid Glass button style (26+) with a bordered fallback.
    /// Use `prominent: true` for the one primary action in a view.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonModifier(prominent: prominent))
    }

    /// Liquid Glass material on a custom control shape (26+), `.ultraThinMaterial`
    /// fallback below. Pass `interactive: true` only when the control is tappable.
    func glassControl<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(GlassControlModifier(shape: shape, tint: tint, interactive: interactive))
    }
}
