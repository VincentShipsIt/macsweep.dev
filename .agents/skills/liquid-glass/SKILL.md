---
name: liquid-glass
description: >-
  Adopt Apple's Liquid Glass design language (macOS 26 / iOS 26 "Tahoe") correctly
  in SwiftUI. Use when asked to apply "glass", "liquid glass", "Apple glass design",
  or modernize an app's chrome to the macOS 26 look. Covers glassEffect,
  GlassEffectContainer, .glass / .glassProminent button styles, availability gating
  for older OS targets, and — critically — the restraint rules (glass is the
  navigation/control layer, NOT a coat of paint for every view).
---

# Liquid Glass adoption (macOS 26 / iOS 26)

Liquid Glass is the translucent, dynamic material introduced at WWDC25 for the
macOS 26 "Tahoe" / iOS 26 generation. It sits on the **navigation and control
layer** — sidebars, toolbars, tab bars, floating action controls, prominent
buttons — refracting and sampling the content scrolling behind it. It is **not**
a background texture for content cards, lists, or whole screens.

The single most common mistake is over-application: coating every card, row, and
panel in glass. That produces a muddy, low-contrast UI and is explicitly against
Apple's guidance. **Restraint is the design.**

## The one rule that fixes most "ugly glass" bugs

When an app is built against the **macOS 26 SDK**, standard components —
`NavigationSplitView` sidebars, `.toolbar`, `List(.sidebar)` selection, default
`Button` — **adopt Liquid Glass automatically**. You get it for free.

Therefore: **stop fighting the system.** The usual cause of a broken-looking
selection chip or muddy sidebar is *custom* styling layered on top of the native
component:

- A custom `RoundedRectangle().fill(Color.accentColor)` selection pill drawn
  inside a `List(.sidebar)` row → double selection, wrong insets, clipped shadow.
  **Fix: delete the custom pill.** Native sidebar selection already renders glass.
- `.scrollContentBackground(.hidden)` + `.background(Color.clear)` on a sidebar so
  a full-bleed gradient shows through → the glass material never renders.
  **Fix: remove those, let the system draw the sidebar material.**
- A heavy full-window gradient behind the whole `NavigationSplitView` → glass has
  nothing neutral to refract and looks flat. **Fix: remove or make it a subtle,
  low-saturation accent behind content only.**

Audit for custom chrome styling and *remove* it before adding any `.glassEffect`.

## API reference

### Built-in button styles (prefer these)
```swift
Button("Primary")   { } .buttonStyle(.glassProminent)  // primary CTA
Button("Secondary") { } .buttonStyle(.glass)           // secondary / toolbar
```

### glassEffect — for genuinely custom controls only
```swift
// Signature: glassEffect(_ glass: Glass = .regular, in shape: some Shape = Capsule)
Text("Pill").padding().glassEffect()                       // default capsule
Image(systemName: "star").padding().glassEffect(in: .circle)
view.glassEffect(in: .rect(cornerRadius: 16))
```
Glass styles: `.regular` (default), `.clear`, `.identity`.
Modifiers on Glass: `.tint(.blue)` (use sparingly), `.interactive()` (ONLY on
tappable elements — never static content).
```swift
.glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
```

### GlassEffectContainer — group adjacent glass shapes
Glass samples a region larger than itself; adjacent glass in *different* containers
can't sample each other and looks inconsistent. Group a cluster (e.g. a row of
toolbar icon buttons) in one container. Container `spacing` should match the
layout spacing.
```swift
GlassEffectContainer(spacing: 16) {
    HStack(spacing: 16) {
        ToolbarButton(icon: "pencil"); ToolbarButton(icon: "eraser")
    }
}
```

### glassEffectID — morph between glass shapes during transitions
```swift
@Namespace private var ns
// inside a GlassEffectContainer, with withAnimation { ... }:
.glassEffect().glassEffectID("pencil", in: ns)
```

### backgroundExtensionEffect — sidebar artwork edge bleed
Use on hero artwork behind a glass sidebar so it extends under/past the sidebar
instead of clipping at the edge.

## Do / Don't

**Do**
- Let standard sidebar / toolbar / buttons adopt glass automatically (SDK 26).
- Use `.glassProminent` for the single primary action, `.glass` for secondary.
- Apply `.glassEffect` **after** padding and frame modifiers.
- Group adjacent glass shapes in one `GlassEffectContainer`; match its spacing.
- `.interactive()` only on tappable controls.
- Keep glass shapes within a feature consistent (same corner radii, concentric
  with their container).
- Always ship a material fallback (`.ultraThinMaterial`) for OS < 26 behind an
  `if #available` gate.

**Don't**
- Don't put glass on every card/row/panel. Content stays on standard materials or
  grouped backgrounds. Glass is chrome, not wallpaper.
- Don't stack glass on glass (nested `.glassEffect` / nested containers).
- Don't add a custom darkening/gradient behind a toolbar — it conflicts with the
  scroll-edge effect.
- Don't use `.interactive()` on static text/images.
- Don't tint heavily; tint is an accent, not a fill.
- Don't draw custom selection chips inside native sidebar lists.

## Availability gating (mixed-OS targets)

> MacSweep's own minimum deployment target is **macOS 26**, so it does **not**
> need any of this — the helpers in `LiquidGlass.swift` call the glass APIs
> unconditionally. The pattern below is retained as general guidance for the
> reusable skill, and only applies if a project supports a target below macOS 26.

Glass APIs are macOS 26.0+. For an app with a lower deployment target (e.g.
macOS 13), **centralize** the gate in reusable modifiers so `if #available` lives
in one file, not scattered across every view. Any function that names the `Glass`
type must itself be `@available(macOS 26.0, *)`.

```swift
extension View {
    @ViewBuilder
    func glassControl<S: Shape>(in shape: S, tint: Color? = nil,
                                interactive: Bool = true) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)   // fallback
        }
    }
    @available(macOS 26.0, *)
    static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}
```

A `@ViewBuilder` body returning different branches across `if #available` is the
correct pattern — it resolves to `_ConditionalContent`, which compiles cleanly
against the newer SDK with an older target.

## Verifying glass visually without Xcode

Liquid Glass only truly renders in a real window backed by the compositor —
`ImageRenderer` (pure offscreen) will not show the refraction. To snapshot it,
host the view in an `NSWindow`/`NSHostingView` and capture the real render
(`screencapture -l <windowNumber>` with Screen Recording permission, or the
view's `cacheDisplay` bitmap for a no-permission offscreen approximation).

## MacSweep helpers (this repo)

`MacSweep/Sources/App/LiquidGlass.swift` provides the centralized helpers — the
app's minimum is macOS 26, so they call the glass APIs unconditionally (no
`if #available`, no pre-26 fallback). Use these instead of raw glass APIs:

- `.glassButton(prominent: Bool = false)` — native `.glassProminent` (the single
  primary CTA) / `.glass` (secondary). Tint only the one prominent action.
- `.glassControl(in:tint:interactive:)` — raw `.glassEffect` on a custom control
  shape. Pass `interactive: true` only on tappable controls.
- `GradientBackground` is the brand accent — keep it subtle and behind content,
  never behind the sidebar (it's currently unused; reserved for content-only
  accents).
