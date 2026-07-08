# UI Fix Brief — 2026-07-08 (MacSweep)

Audit of the main window, menu-bar companion, and glass system as of master
`83bf12f` + the uncommitted working tree. This is the contract for the next UI
pass. Do ONE pass against this brief; do not invent a new chrome approach
mid-task. If something here conflicts with reality, STOP and report instead of
improvising.

**All file:line references below are against master `83bf12f` — i.e., the tree
AFTER Step 0 parks the uncommitted diff.** Do not look for these lines in the
current dirty working tree.

## Why the sessions looped (read first)

MacSweep has been circling ONE unresolved decision since late June: does the
system own the window chrome, or does the app hand-roll it?

- 2026-06-24/25: three codex branches (`codex/native-titlebar-refresh-placement`,
  `codex/unify-titlebar-and-header`, `codex/trim-toolbar-bottom-modules`) plus
  PRs #66/#69 fought the titlebar into NATIVE chrome (`FeaturePageShell` puts
  title/subtitle/action in the real titlebar; `ContentView` comments explicitly
  warn "No background overrides: the native sidebar draws its own Liquid Glass
  material").
- Same day, SIX consecutive `fix(app): … window` commits (`98d6964` → `b48b8fe`)
  patched the window-reopen fallback. Root cause of THAT loop: the app has
  three parallel window-construction paths (two `WindowGroup`s, an
  `NSViewRepresentable` that reaches back and mutates the live `NSWindow`, and
  a manual fallback `NSWindow` in `AppDelegate`) that must be kept in sync by
  hand, plus staggered `t+0.6s`/`t+0.7s`/`t+1.0s` timers racing each other.
- The current UNCOMMITTED diff (8 files, +664/−200) is the next lap: it deletes
  the native `NavigationSplitView`, `List(.sidebar)`, `.navigationTitle` and
  toolbar, and hand-rolls a "MeterBar-style full-window chrome" (its own doc
  comment) — fake titlebar strip, fake sidebar with `Color.white.opacity`
  selection painting, zero-safe-area `NSHostingView` subclass, manual layer
  `cornerRadius`, `window.toolbar = nil`, `.windowStyle(.hiddenTitleBar)`.
  That is the EXACT architecture MeterBar's own 2026-07-08 brief orders deleted
  (see `../meterbarapp/.agents/UI-FIX-BRIEF-2026-07-08.md`, Part B). The
  attached screenshots show its symptoms: page subtitle clipped under the
  traffic lights, and a dark square halo behind the rounded corners (the manual
  `layer.cornerRadius` clip + `isOpaque=false` near-black background fighting
  the native window shape).

**Decision (final): the committed master state — native `NavigationSplitView` +
native titlebar — is the correct architecture. The uncommitted diff is a
regression and must NOT land. The remaining real problems at master are (1) the
hardcoded-dark theme that breaks light mode, (2) triple window-construction
paths, (3) card-recipe sprawl, (4) the menu-bar panel's guessed heights.**

## Current state + Step 0 (the literal first commands)

`git status`: 8 modified files, nothing staged, no other branches (local or
origin) besides master. The diff compiles but is the regression described
above. Park it on a reference branch, then work from master:

```
git switch -c wip/handrolled-chrome-2026-07-08
git add -A
git commit -m "WIP: hand-rolled MeterBar-style chrome (reference only, do not merge)"
git switch master
```

Do NOT merge or cherry-pick that branch. Salvage exactly four ideas from it by
re-implementing per this brief (read them with
`git diff master wip/handrolled-chrome-2026-07-08`):

1. The 12pt `panelGap` for the menu-bar detail panel → A1.
2. The `Color.adaptive(light:dark:lightHighContrast:darkHighContrast:)` helper
   and adaptive `glassCardTint`/`glassCardStroke` tokens → B1/B3.
3. The `accessibilityReduceTransparency` fallback pattern on surfaces → B3.
4. `MenuBarDetailPanel` divider under the panel header → A2 (cosmetic, optional).

Explicitly NOT salvaged (do not re-land any of it): the `HStack` app shell,
`dashboardTitlebar`, `MacSweepTitlebarGlass`, `MacSweepSidebarSurface`,
`MacSweepChromeIconButtonStyle`, `MacSweepRefreshIcon`,
`MacSweepFullSizeHostingView`, `applyMainWindowRadius`,
`.windowStyle(.hiddenTitleBar)`, `window.toolbar = nil`, the per-`Feature`
`titlebarSubtitle` string table (duplicates `FeaturePageShell` subtitles), the
popover width bump 320→390, the popover footer deletion (it removed the ONLY
Quit affordance, `MenuBarView.swift:162-166`), and the `DashboardSection` card
rewrite of the Smart Care page.

---

## Part A — Small surgical fixes (on master, after Step 0)

### A1. Menu-bar detail panel touches the primary panel
`MacSweep/Sources/Features/MenuBar/MenuBarDetailPanel.swift:48` positions the
detail panel at `x: a.minX - width` — flush against the dropdown. Add
`static let panelGap: CGFloat = 12` to `MenuBarCompanionPanelLayout`
(`MenuBarDetailPanel.swift:70-75`) and use `a.minX - width - panelGap`. Keep
tops aligned as today.

### A2. Panel heights must be measured, not guessed
`MenuBarDetailContent.preferredHeight(for:monitor:)`
(`MenuBarDetailPanel.swift:136-155`) is a table of guesses (storage 500,
memory 540, battery 430, cpu 500, network 460, devices `110 + rows*62`,
system 400). The same detail views already self-size on the dashboard path via
`.fixedSize(horizontal: false, vertical: true)` (`DashboardView.swift:733-736`)
— proof the estimates are unnecessary. When the guess is low, content overflows
into the indicator-less ScrollView and looks clipped; when high, dead space.

Fix: in `MenuBarDetailPanel.present` (`MenuBarDetailPanel.swift:29-50`), build
the `NSHostingView` first, pin its width to `detailWidth`, and read
`fittingSize.height` to size the panel. Then:
- DELETE `preferredHeight(for:monitor:)` entirely and its caller argument
  (`toggleWidget`, `MenuBarView.swift:271`); change `present(anchor:preferredHeight:content:)`
  to `present(anchor:content:)`. Update BOTH signature and caller in the same
  commit (MeterBar's session left exactly this refactor half-done and
  non-compiling — do not repeat).
- DELETE `.clipped()` at `MenuBarDetailPanel.swift:46`.
- Lower `minDetailHeight` (`:73`) from 240 to ~120 (empty-state floor only).
- Keep the screen-height clamp (`:35-39`); the internal ScrollView
  (indicators already hidden) remains the tall-content fallback.

### A3. Clamp the detail panel to the screen's left edge
`present` clamps vertically (`MenuBarDetailPanel.swift:40-41`) but never
horizontally: with a status item near the screen's left edge,
`x = a.minX - width - gap` goes off-screen. Add
`x = max(visibleFrame.minX + screenPadding, x)`.

### A4. Dashboard popover shows scrollbars; menu-bar panel hides them
`dashboardScrollablePopoverContent` (`DashboardView.swift:738-744`) wraps the
devices popover in a `ScrollView` with visible indicators; the identical view
in the menu-bar panel hides them. Add `.scrollIndicators(.hidden)` to the
dashboard one for consistency.

### A5. AI Analysis status bar hardcodes near-black
`MacSweep/Sources/Features/AIAnalysis/AIAnalysisView.swift:331` —
`.background(MacSweepTheme.backgroundMid.opacity(0.96))` on the status bar.
Replace with `.background(.bar)` (or `.regularMaterial`). This is the only
`backgroundTop/Mid/Bottom` consumer outside `MacSweepDetailBackground`.

---

## Part B — Architectural (the real work)

### B1. Adaptive appearance: kill the forced near-black chrome
Nothing forces dark mode (`preferredColorScheme` / `NSApp.appearance` appear
nowhere), yet the window is painted near-black and most surface tokens are
white-alpha. In light mode the OS renders dark text and light materials over a
forced-dark window → broken. Delete the dark hardcoding; let the system carry
appearance:

- DELETE `enum MacSweepWindowChrome` (`MacSweep/Sources/App/LiquidGlass.swift:92-110`,
  fixed RGB 0.080/0.086/0.084) and its two window assignments:
  `AppDelegate.swift:131-132` (`isOpaque = false`, `backgroundColor = …`) and
  `MacSweepApp.swift:143-144`. A standard titled window keeps its native
  background; do not set `isOpaque` or `backgroundColor` at all.
- DELETE `MacSweepDetailBackground` (`LiquidGlass.swift:126-155`, the
  near-black gradient) and its use at `ContentView.swift:25-26`. The detail
  pane then sits on the native window background. If a brand wash is wanted,
  add ONLY the accent gradient at ≤0.15 opacity over the native background —
  no solid dark layer.
- Replace the dark-only tokens (`LiquidGlass.swift:115-117`) with semantics:
  `panel` (`Color.white.opacity(0.050)`, 10 uses w/ `panelStrong`) → `.quinary`
  or the new adaptive `glassCardTint`; `panelStrong` → `.quaternary`;
  `divider` (`Color.white.opacity(0.095)`, 27 uses as Divider overlays) →
  DELETE the overlay entirely and let native `Divider()` draw itself (that is
  what it is for). `backgroundTop/Mid/Bottom` (`:112-114`) die with
  `MacSweepDetailBackground` (A5 removed the last other consumer).
- Keep `accent`, `accentBlue`, `warningPanel` (brand/status colors, fine in
  both modes). Keep `ShareView`'s fixed-dark colors — that is a rendered export
  card, appearance-independent by design.
- Port `Color.adaptive` from the parked branch as the mechanism for any token
  that genuinely needs per-appearance values.

### B2. One window, one owner
Three code paths construct/configure the main window and 4 staggered timers
keep them from racing (this fed the six-commit reopen loop on 06-25). Collapse
to a single SwiftUI-owned window:

Delete:
- The anonymous `WindowGroup` (`MacSweepApp.swift:26-32`); keep ONE scene and
  make it `Window("MacSweep", id: "main")` (single-window app — `WindowGroup`
  allows accidental duplicates).
- `MainWindowChromeConfigurator` (`MacSweepApp.swift:131-155`) and its
  `.background(...)` at `:65`. Replace with scene modifiers on the `Window`:
  `.defaultSize(width: 1040, height: 800)`, `.defaultPosition(.center)`,
  `.restorationBehavior(.disabled)`. Do not touch `titleVisibility`,
  `titlebarAppearsTransparent`, `toolbarStyle`, or `styleMask` anywhere —
  `NavigationSplitView` + macOS 26 provide the Finder look natively.
- The entire fallback-window machinery in `AppDelegate.swift`:
  `fallbackMainWindow` (`:12`), the `t+0.6s` launch timer (`:33-35`),
  `openMainWindowIfNeeded()` (`:114-146`), `isMainAppWindow` size heuristic
  (`:148-156`), and the lie-about-visibility workaround inside
  `focusMainWindow` (`:106-111` comment). Opening/focusing becomes:
  `openWindow(id: "main")` from SwiftUI contexts (menu-bar footer already has
  `@Environment(\.openWindow)` via `openMainWindow()`,
  `MenuBarView.swift:151-158`), and `applicationShouldHandleReopen` just
  activates + `makeKeyAndOrderFront` on an existing window if present.
- The menu-bar label's delayed window-open task (`MacSweepApp.swift:105-123`,
  the `t+0.7s`/`t+1.0s` sleeps). Launch behavior belongs to the scene, not to
  a label's `.task`.
- `mainWindowLaunchSize` is defined twice (`AppDelegate.swift:10`,
  `MacSweepApp.swift:16`) — after the deletions above only the scene needs it.

Keep: the dock-icon policy management (`showDockIcon`/`hideDockIcon`,
`AppDelegate.swift:81-89`) and the `willClose` observer that hides the dock
icon when the last main window closes (`:44-70`) — that is genuine
menu-bar-app behavior. Simplify `handleWindowClose`'s window sniffing only if
it falls out naturally.

VERIFY by hand after B2 (this area is behavior-sensitive): app launches with
window; close window → dock icon hides, menu bar stays; reopen via dock click
AND via menu-bar "Open MacSweep"; no duplicate windows after spamming both.

### B3. One card recipe + Reduce Transparency
Master has zero `accessibilityReduceTransparency` handling and four competing
card/panel treatments: `MacSweepCompanionSurface` (`LiquidGlass.swift:157-184`
— `.ultraThinMaterial` + **0.74 near-black overlay** at `:165` that kills the
material), `.macSweepPanel` (`:186-205`, white-alpha fill), ~22 ad-hoc
`.background(.ultraThinMaterial …)` sites across 15 files (Privacy,
AppUninstaller, BrowserCleanup, WidgetDetails/*, Shredder, Homebrew,
BatteryMonitor, Onboarding, SpaceLens, ContentView), plus raw `.glassControl`.

Target:
- ONE card modifier — `macSweepCard(radius:)` in `LiquidGlass.swift`:
  `.ultraThinMaterial` fill + adaptive tint ≤0.2 (`glassCardTint` from the
  parked branch) + adaptive hairline stroke + `reduceTransparency` fallback to
  a solid `Color(nsColor: .windowBackgroundColor)`. Migrate the ~22 ad-hoc
  material sites and the `.macSweepPanel` sites to it, then DELETE
  `MacSweepPanelModifier`/`macSweepPanel`.
- `MacSweepCompanionSurface` stays as the menu-bar panel/window surface ONLY
  (2 uses), but drop the 0.74 solid overlay to ≤0.2 adaptive tint and add the
  `reduceTransparency` solid fallback. No solid tint above 0.2 over any
  material anywhere.
- `glassEffect` stays reserved for floating controls (`.glassButton`,
  `.glassControl`) — never stacked on a material fill (the parked branch's
  `MacSweepSidebarSurface` did exactly that; it stays dead).
- Sidebar and titlebar get NO custom painting at all — native
  `List(.sidebar)` + native toolbar own their materials (already true at
  master; keep it true).

---

## Part C — Deep cleanup (verified findings)

### C1. Dead code — the legacy welcome-screen island (delete ~190 lines)
All verified zero-reference at master (grep counts include declaration only):
- `GradientBackground` — `ContentView.swift:273-286` (referenced only by a
  comment at `:41`).
- `SmartScanView` — `ContentView.swift:289-346` (superseded by
  `ScanLandingView`; contains a no-op "Assistant" button with an empty action).
- `AppIllustration` — `ContentView.swift:350-382` (only caller is dead
  `SmartScanView`, `:320`).
- `ScanButton` — `ContentView.swift:386-464` (only caller `:337`; do NOT
  confuse with the live `CircularScanButton` in `FeaturePageShell.swift:179`).

Checked and NOT dead — do not delete: `PlaceholderFeatureView`
(`ContentView.swift:468`, used `:197,199`), `backgroundMid` until A5 lands,
`rescanButton`/`cleanRecommendedButton` (`DashboardView.swift:126-146`, live
via the toolbar at `:95-100`). No write-only environment plumbing, no no-op
`nonisolated`, no pass-through alias modifiers exist at master (all 10
`nonisolated` uses sit on actors/`@MainActor` classes — meaningful).

### C2. Consolidations (small)
- The "Run Smart Care"/"Rescan" ternary is duplicated at
  `DashboardView.swift:135` and `:215` — hoist one computed `scanButtonTitle`.
- The window-config duplication (`AppDelegate.swift:126-139` vs
  `MacSweepApp.swift:138-149`) dies entirely with B2 — do not unify it in
  place first; delete it.

### C3. Stale planning docs
`.agents/BACKLOG.md:3-24` still says "3 open PRs (#73, #74, #75)" and orders
their merge — all three merged weeks ago. Rewrite the header/Step 0 or archive
the file; a release agent reading it today would be misled. (There are ZERO
open PRs; 21 open issues, none with unresolved review threads.)

### C4. Repo weight (housekeeping, no code change)
`MacSweep/.build` = 536MB, `build/` (DerivedData) = 348MB — both ignored;
~884MB reclaimable with a clean before packaging. Versions are consistent
(1.0.8 in `MacSweepVersion.swift`, `project.yml`; latest tag v1.0.7 as
expected pre-release). No stray branches, no dead tracked plists.

### C5. Deferred (note, don't fix now)
- `SystemStatCard` hard cap `maxHeight: 94` (`MenuBarView.swift:362-365`,
  applied `:418`) — latent clip for longer localized strings; revisit at
  localization time.
- `FeaturePageShell`'s `scrolls:` flag (`FeaturePageShell.swift:12-21`) is a
  REQUIRED workaround for the NavigationSplitView sidebar-blackout bug (see
  memory + doc comment) — it stays. Do not "clean it up".

---

## Part D — Decided product changes (Vincent, 2026-07-08)

These were open questions; Vincent answered them on 2026-07-08. They are IN
scope for this pass (run after Part C). The unreachable-features question is
NOT in scope — it is tracked as GitHub issue #142; do not wire in or delete
`.aiAnalysis` / `.loginItems` / `.homebrewUpdater` / `.updater` /
`.extensions` in this pass.

### D1. Watchlist items must not arrive preselected for deletion
Remove `AssistantWatchlistModule.moduleID` from
`SmartCareDefaults.autoCleanModules` (`MacSweep/Sources/Core/Scanning/SmartCare.swift:47`).
Effect (both intentional): watchlist items no longer land in
`recommendedCleanupItemIDs` (`SmartCare.swift:73-75`) so they arrive UNCHECKED
in the cleanup review, and their finding row loses the `autoCleanRecommended`
badge (`SmartCare.swift:61`). Check for tests asserting the old membership and
update them.

### D2. Recommendations section becomes data-driven
`recommendationRows` (`DashboardView.swift:371-447`) currently renders 8
unconditional navigation rows. Gate each row on a real signal; a row with no
signal renders nothing:
- "Run Deep Scan" (`:373-383`) — keep unconditional (it is the primary action,
  not navigation).
- "Developer Tools" (`:403`), "Large & Old Files" (`:394`), "Duplicate Files"
  (`:412`), "Similar Photos" (`:430`), "Cloud Cleanup" (`:439`) — show only
  when the current `appState.smartCareSummary` contains a finding for the
  matching module ID (`dev-tools`, `large-files`, `duplicates`,
  `similar-photos`, `cloud-cleanup` — the same IDs `AppState.feature(for:)`
  maps at `AppState.swift:159-175`).
- "Battery Monitor" (`:421-428`) — show only when
  `monitor.batteryInfo.hasBattery`; delete the "This Mac is on desktop power"
  fallback copy.
- "Uninstall Apps" (`:385-392`) — no signal exists for it; delete the row.

### D3. Share leaves the sidebar; export becomes a post-cleanup action
- Remove `.share` from `FeatureSection.main` (`AppState.swift:307` —
  `return [.smartScan, .assistant, .share]` → drop `.share`). Keep the
  `Feature.share` case and `ShareView` (`ContentView.swift:157` detail arm) —
  `selectedFeature = .share` still renders it; an unlisted selection simply
  shows no sidebar highlight.
- Add the entry point where the brag-worthy number exists: in the dashboard's
  "Recent Activity" section (shown when `appState.lastCleanup != nil`,
  `DashboardView.swift` Recent Activity section), add a "Share your results"
  row/button that sets `appState.selectedFeature = .share`. No other entry
  point is needed this pass.

---

## Acceptance criteria (grep-verifiable)

Regression guards — all of these must return ZERO matches in
`MacSweep/Sources` after every step (they are zero at master; the parked
branch must not leak back):
- [ ] `MacSweepFullSizeHostingView`, `applyMainWindowRadius`,
      `dashboardTitlebar`, `MacSweepTitlebarGlass`, `MacSweepSidebarSurface`,
      `MacSweepChromeIconButtonStyle`, `titlebarContentInset`,
      `hiddenTitleBar`, `toolbar = nil`, `isMovableByWindowBackground`
- [ ] `NavigationSplitView` still present in `ContentView.swift`;
      `.listStyle(.sidebar)` still present

Zero matches after the work:
- [ ] `MacSweepWindowChrome`, `MacSweepDetailBackground`, `backgroundTop`,
      `backgroundMid`, `backgroundBottom`
- [ ] `Color.white.opacity` in `App/LiquidGlass.swift`
- [ ] `preferredHeight(for`, `.clipped()` in `MenuBarDetailPanel.swift`
- [ ] `MainWindowChromeConfigurator`, `openMainWindowIfNeeded`,
      `fallbackMainWindow`, `isMainAppWindow`
- [ ] `SmartScanView`, `AppIllustration`, `GradientBackground`,
      `struct ScanButton`
- [ ] `background(.ultraThinMaterial` outside `App/LiquidGlass.swift`
      (all migrated to the one card recipe)

Present after the work:
- [ ] `accessibilityReduceTransparency` ≥ 1 (in the card recipe +
      companion surface)
- [ ] `git branch --list 'wip/*'` shows the parked branch, untouched

Part D greps:
- [ ] `AssistantWatchlistModule.moduleID` absent from the `autoCleanModules`
      set in `SmartCare.swift`
- [ ] `"This Mac is on desktop power"` → zero matches
- [ ] `.share` absent from `FeatureSection.main`'s returned array;
      `selectedFeature = .share` present ≥ 1 (the new Recent Activity entry)

Behavioral (verify in the running app):
- [ ] Light mode AND dark mode AND Reduce Transparency: sidebar, Smart Care
      page, one scan page (System Junk), menu-bar dropdown + detail panel all
      readable, no dark-on-dark, no white-on-white.
- [ ] Menu-bar detail panel: 12pt gap from dropdown, tops aligned, hugs
      content height (devices with 1 and 4 devices; battery; network), never
      clipped, never off the left screen edge.
- [ ] Window lifecycle per B2's verify list; no duplicate windows.
- [ ] `swift test` passes; Release build succeeds.

---

## Run order (budget-aware, one commit per step)

1. **Step 0** — park the WIP branch (commands above). Cheapest, unblocks all
   file:line refs.
2. **Part A** (A1-A5) — small, high-visibility, each independently
   verifiable. One commit per item or one for A1-A4 + one for A5.
3. **B1** (adaptive appearance) — biggest visible payoff; mostly deletions.
4. **B2** (single window owner) — isolated to App/; manual verify list.
5. **B3** (card recipe consolidation) — wide but mechanical; do the recipe +
   `LiquidGlass.swift` first, then migrate call sites in 2-3 commits.
6. **Part C** (C1 dead code, C2, C3) — zero user-visible risk.
7. **Part D** (D1 → D2 → D3) — decided product changes; D1 is one line +
   test updates, D2/D3 are small view edits.

If any step's premise doesn't match the tree (signature moved, line drifted,
symbol already gone), STOP and report — do not improvise a new approach.

Non-goals: do not touch scan modules (except the one-line D1 set change),
deletion safety, services, CLI, or the data layer. Do not redesign page
content or copy beyond Part D. Do not add new surface recipes beyond the one
card modifier. Do not touch the unreachable features tracked in issue #142.
