import SwiftUI

/// Reduce-motion-aware animation helpers.
///
/// SwiftUI has no built-in way to make an animation automatically respect the
/// system **Reduce Motion** accessibility setting — every call site has to read
/// `@Environment(\.accessibilityReduceMotion)` and hand-roll a
/// `reduceMotion ? nil : animation` guard (see `CircularScanButton` in
/// `FeaturePageShell.swift` and `ContentView.showFeature`). These helpers move
/// that guard into one place so callers can't forget it: pass an animation, and
/// it silently collapses to *no animation* — an instant, non-animated change —
/// whenever the user has asked for reduced motion.
///
/// Because a SwiftUI transition only plays inside an animated transaction,
/// pairing `.transition(...)` with `.animated(_:value:)` also gets reduce-motion
/// for free: under Reduce Motion the value change isn't animated, so the
/// transition doesn't run and the swap is a plain hard cut — exactly the
/// accessible behaviour we want.

extension View {
    /// Drop-in replacement for `.animation(_:value:)` that disables the
    /// animation under Reduce Motion.
    ///
    /// Equivalent to `.animation(reduceMotion ? nil : animation, value: value)`
    /// but without the caller needing to read the environment. Attach it to a
    /// *stable container* whose descendants change with `value` (for a
    /// transition, the container that owns the swapping branches — not the
    /// branches themselves).
    func animated<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReduceMotionAnimationModifier(animation: animation, value: value))
    }
}

private struct ReduceMotionAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// `withAnimation` that no-ops under Reduce Motion.
///
/// A free function can't read `@Environment`, so the caller passes its own
/// `reduceMotion` value (read from `@Environment(\.accessibilityReduceMotion)`
/// in the enclosing `View`). Use this at imperative call sites that mutate state
/// inside `withAnimation`; prefer `.animated(_:value:)` for declarative ones.
@discardableResult
func withMotion<Result>(_ animation: Animation,
                        reduceMotion: Bool,
                        _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(reduceMotion ? nil : animation, body)
}

extension Animation {
    /// Timing for the scan-flow crossfades (land → scan → results). A single
    /// source of truth so every stage of the core loop shares one curve; an
    /// `easeInOut`, consistent with the app's `easeInOut` convention.
    static let scanCrossfade: Animation = .easeInOut(duration: 0.25)
}

extension AnyTransition {
    /// The scan-flow crossfade: a gentle opacity dissolve with a barely-there
    /// scale so swapped content settles into place instead of snapping.
    ///
    /// Apply to each branch of a landing/progress/results swap and drive the
    /// enclosing container with `.animated(.scanCrossfade, value:)` so it
    /// respects Reduce Motion.
    static var scanCrossfade: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98))
    }
}

/// Which stage of the scan loop a feature page is showing. Feature pages with
/// more than a plain landing⇄results swap (a distinct "nothing found" state, or
/// a separate scanning arm) compute this and drive `.animated(.scanCrossfade,
/// value:)` with it, so *every* arm change crossfades — a bare `items.isEmpty`
/// boolean would miss e.g. landing→empty when a scan finds nothing. Simple
/// two-state pages can drive the crossfade with their own boolean instead.
enum ScanPhase: Equatable {
    case landing
    case scanning
    case empty
    case results
}
