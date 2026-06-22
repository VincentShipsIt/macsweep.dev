# MacSweep v0.1.0 Roadmap

Status date: 2026-06-17

## Release Intent

v0.1.0 is the first credible native GUI release of MacSweep.

The CLI/core already looks beyond an early MVP: the scan engine, safety pipeline,
headless mode, Homebrew formula, and broad module coverage are in place. The v0.1.0
work should therefore focus on trust, polish, onboarding, and turning the GUI into
a dependable product surface rather than adding more sidebar items.

Primary users:

- Mac power users who want a transparent alternative to CleanMyMac.
- Developers who need to reclaim space from build artifacts, package caches,
  old worktrees, and Docker.
- Users who want DaisyDisk-style storage insight without opaque deletion.

## Current State

### Solid Foundation

| Area | Current State | Evidence |
| --- | --- | --- |
| Core scan engine | Broad multi-module scanner with partial-failure diagnostics and progress updates | `MacSweep/Sources/Core/Scanning/ScanEngine.swift` |
| Safety | Default-deny path checks, module safety profiles, deletion guard, trash-first removal | `MacSweep/Sources/Core/Safety/` |
| Smart Care | Safe aggregate scan across system junk, trash, mail attachments, dev tools, large files, duplicates, similar photos, and cloud cleanup | `MacSweep/Sources/Core/Scanning/SmartCare.swift` |
| Cleanup modules | System cache, browsers, service workers, dev tools, package managers, Docker, cloud cleanup, mail attachments, trash, privacy, network, large files, duplicate files, similar photos | `MacSweep/Sources/Core/Scanning/Modules/` |
| GUI feature surfaces | 24 sidebar destinations render, with only Updater and Extensions intentionally placeholder | `MacSweep/Sources/Features/Dashboard/ContentView.swift` |
| CLI/headless | CLI supports scan, dry-run, apply, modules, permissions, maintenance, space, uninstall, AI, malware, Homebrew, shred, network, processes, privacy, monitor, schedule, self-update | `MacSweep/Sources/CLIKit/CLICommand.swift` |
| Monitoring | CPU, memory, disk, battery/no-battery, network, process views | `MacSweep/Sources/Core/Monitoring/` |
| Release plumbing | Homebrew formula (lives in [VincentShipsIt/homebrew-tap](https://github.com/VincentShipsIt/homebrew-tap)), release consistency script, CI for CLI/core tests | `.github/workflows/ci.yml`, `scripts/release.sh` |
| Visual baseline | Snapshot harness renders 29/29 GUI states | `scripts/render-screenshots.sh`, `scripts/screenshots/` |

### Current Gaps

| Gap | Severity | Why It Matters For v0.1.0 |
| --- | --- | --- |
| Full Disk Access onboarding is too thin | Critical | Protected folders are core to value. Users need one-click guidance, verification, and recovery messaging. |
| GUI cleanup confirmation flow is not yet product-grade everywhere | Critical | A cleaner app lives or dies on trust. Every destructive action needs preview, selection, size, destination, and errors. |
| App signing/notarization/distribution for the GUI is not ready | Critical | CLI can ship via Homebrew, but a native app needs a signed/notarized artifact users can open without fear. |
| Updater and Extensions are visible but placeholder | High | Visible dead ends make the product feel unfinished. Hide or implement before v0.1.0. |
| Visual system is inconsistent across old and new surfaces | High | Recent design direction is better, but feature pages still mix card density, headers, colors, and empty states. |
| Smart Care does not explain recommended vs review-only items clearly enough | High | Duplicates, similar photos, and large files should not auto-clean. The UI must make that distinction obvious. |
| Permission and scan failure reporting needs a single user-facing pattern | High | Partial scans are captured in core, but GUI messaging needs to tell users exactly what failed and why. |
| GUI tests/visual regression are not in CI | Medium | The current CI proves CLI/core. v0.1.0 needs app build plus snapshot smoke test. |
| Audit log / cleanup history is missing | Medium | Users need proof of what changed, especially after deletion. |
| Preferences are shallow | Medium | Users need safety defaults, scan exclusions, schedule interval, AI provider, and menu bar behavior in one place. |
| Accessibility and keyboard polish are unverified | Medium | Native macOS utility should support VoiceOver labels, focus rings, shortcuts, and reduced motion. |
| Landing/docs/screenshots are stale | Medium | README still says screenshots coming soon and versioning is CLI-first. v0.1.0 needs honest GUI documentation. |

## v0.1.0 Scope

### Must Ship

1. **Reliable app launch and menu bar behavior**
   - Main window opens from Dock and menu bar every time.
   - Menu bar icon, app icon, titlebar, and app name are consistent.
   - Closing the window should leave menu bar mode working, with clear reopen behavior.

2. **Full Disk Access onboarding**
   - First-run permission screen with exact System Settings path.
   - "Grant Access" opens the correct privacy pane.
   - App detects access after the user returns.
   - Feature screens show scoped permission warnings instead of silently empty states.

3. **Smart Care as the main product loop**
   - Scan progress with current module and partial-failure states.
   - Findings grouped by safe-to-clean vs review-required.
   - "Clean Recommended" only selects safe modules.
   - Post-clean summary shows bytes recovered and errors.

4. **Core cleanup surfaces ready**
   - System Junk
   - Trash Bins
   - Developer Tools
   - Large & Old Files
   - Duplicate Files
   - Similar Photos
   - Cloud Cleanup
   - Mail Attachments
   - Privacy

5. **Developer-focused differentiator ready**
   - Developer Tools should clearly expose node_modules, DerivedData, package caches, Docker, stale git worktrees, and merged branches.
   - Each item needs path, size, last modified, rebuild hint where possible, and safe clean action.

6. **Uninstaller usable**
   - App list loads reliably.
   - App details show bundle, support files, caches, prefs, containers, and logs.
   - Running apps are protected or clearly handled.
   - Orphan leftovers have their own review section.

7. **Protection and speed baseline**
   - Malware scan can run and explain clean/review/suspicious results.
   - Login Items can list, disable, and remove safely.
   - Optimization can show processes and memory pressure.
   - Battery Monitor handles desktop Macs with "No Battery" state.
   - Maintenance tasks should either work, require admin clearly, or be hidden.

8. **Distribution-ready build**
   - Release app is signed and notarized.
   - Bundle identifier stable: `com.vincentshipsit.macsweep`.
   - Hardened runtime enabled.
   - GitHub release contains app zip/dmg plus CLI notes.
   - Homebrew formula remains CLI-first unless a separate cask is added.

9. **Quality gate**
   - `swift test --package-path MacSweep` passes.
   - `xcodebuild -scheme MacSweep` passes.
   - Snapshot harness renders all primary screens.
   - No "Coming soon" surfaces visible in the v0.1.0 sidebar.
   - No known destructive-action bypasses.

### Should Ship

- Cleanup history/audit log.
- Exportable scan/cleanup report.
- Settings for exclusions, schedule interval, menu bar behavior, and AI provider.
- Better empty states with next action.
- README screenshots and a short "What MacSweep will never delete automatically" section.
- Keyboard shortcuts for Scan, Clean Recommended, Search, Refresh, Settings.

### Explicitly Defer

- Updater, unless Homebrew Updater fully covers the app-update story.
- Extensions manager.
- iOS companion app.
- Cloud sync.
- Paid licensing.
- App Store distribution.
- Automatic background deletion.

## Prioritized Backlog

### P0: v0.1.0 Blockers

1. **Permission onboarding and recovery**
   - Impact: 5
   - Urgency: 5
   - Effort: 2
   - Notes: Highest leverage. Without this, protected scans look broken.

2. **Unified cleanup confirmation and result flow**
   - Impact: 5
   - Urgency: 5
   - Effort: 4
   - Notes: Create one reusable review/confirm/result pattern and apply across cleanup pages.

3. **Hide or finish visible placeholders**
   - Impact: 4
   - Urgency: 5
   - Effort: 1
   - Notes: Updater and Extensions should not be visible unless real.

4. **GUI signing/notarization pipeline**
   - Impact: 5
   - Urgency: 5
   - Effort: 3
   - Notes: Personal/local signing is fine for development; v0.1.0 needs real distribution signing.

5. **Smart Care trust pass**
   - Impact: 5
   - Urgency: 4
   - Effort: 3
   - Notes: Make recommended cleanup vs manual review impossible to misunderstand.

6. **Visual consistency pass**
   - Impact: 4
   - Urgency: 4
   - Effort: 3
   - Notes: Shared page layouts, empty states, toolbar actions, row styles, and dark background.

### P1: v0.1.0 Strongly Recommended

1. **Developer Tools final pass**
   - Impact: 5
   - Urgency: 4
   - Effort: 3
   - Notes: This is the best wedge against CleanMyMac for developers.

2. **Uninstaller final pass**
   - Impact: 4
   - Urgency: 4
   - Effort: 3
   - Notes: Must show leftovers clearly and avoid deleting active apps.

3. **Partial scan and permission error UX**
   - Impact: 4
   - Urgency: 4
   - Effort: 2
   - Notes: Core supports partial failures; GUI needs a consistent pattern.

4. **Settings and safety controls**
   - Impact: 4
   - Urgency: 3
   - Effort: 3
   - Notes: Exclusions and schedule interval are especially important.

5. **App icon/logo replacement**
   - Impact: 3
   - Urgency: 4
   - Effort: 2
   - Notes: The current logo/icon story has caused visible confusion. Ship one polished app icon and matching menu bar symbol.

### P2: After v0.1.0

1. **Audit log and undo-adjacent recovery**
   - Trash-first cleanup plus history view.
   - Show original path, moved-to-trash path, timestamp, module, and bytes.

2. **App updater / Extensions**
   - Either implement or keep hidden until v0.2.0.

3. **Visual charts and Space Lens polish**
   - Space Lens exists, but v0.2.0 can make it a signature experience.

4. **Accessibility certification pass**
   - VoiceOver labels, keyboard navigation, contrast, reduced motion, dynamic type stress test.

5. **Public docs and website**
   - Installation, permissions, safety model, screenshots, FAQ.

## Milestones

### Milestone 1: Stabilize The Shell

Goal: The app opens, looks coherent, and explains permissions.

- Fix app/menu bar open/focus behavior.
- Replace all old pencil/brush/logo leftovers.
- Implement first-run permission onboarding.
- Hide Updater and Extensions from sidebar.
- Normalize page headers and toolbar actions.
- Add GUI build and snapshot smoke test to CI.

Exit criteria:

- Fresh install opens main window.
- Closing and reopening from menu bar works.
- No visible placeholder pages.
- Snapshot harness passes.

### Milestone 2: Make Smart Care Trustworthy

Goal: The main scan/clean loop feels safe enough to use.

- Show current scanning module and progress.
- Surface partial scan failures.
- Split results into "Recommended" and "Needs Review".
- Confirm cleanup with item count, module breakdown, and bytes.
- Show post-clean summary with errors.

Exit criteria:

- User can run Smart Care, clean recommended items, and understand exactly what happened.
- Duplicates, similar photos, and large files are never silently cleaned.

### Milestone 3: Finish The High-Value Feature Pages

Goal: The sidebar feels real.

- Developer Tools final UX.
- Uninstaller final UX.
- Large & Old Files final UX.
- Duplicate Files and Similar Photos review UX.
- Privacy, Trash, Mail Attachments, Cloud Cleanup empty/error states.

Exit criteria:

- Every visible v0.1.0 page has scan, results, selection, cleanup/review, empty, and error states.

### Milestone 4: Distribution Readiness

Goal: A user can download and run the app without Xcode.

- Apple Developer Team signing configured.
- Hardened runtime release build.
- Notarized artifact.
- GitHub release draft with checksums.
- README updated with screenshots and permission instructions.
- Version sources aligned.

Exit criteria:

- Clean machine can download, open, grant access, scan, and clean.

## v0.1.0 Non-Negotiable Checklist

- [ ] No placeholder sidebar destinations visible.
- [ ] Full Disk Access onboarding works.
- [ ] App opens from Dock, Finder, and menu bar.
- [ ] Smart Care scan and cleanup flow works end-to-end.
- [ ] Cleanup confirmation is consistent across deletion-bearing pages.
- [ ] Protected paths and deletion guard stay enforced.
- [ ] Desktop Macs show "No Battery", not 0%.
- [ ] `swift test --package-path MacSweep` passes.
- [ ] `xcodebuild -project MacSweep/MacSweep.xcodeproj -scheme MacSweep -configuration Release build` passes.
- [ ] Snapshot harness renders every visible feature surface.
- [ ] Release app is signed and notarized.
- [ ] README has current screenshots, install steps, and safety model.

## Current Verification Snapshot

Latest local check:

- Swift package tests passed: 247 tests in 21 suites.
- Xcode Debug app build passed.
- Snapshot harness rendered 29/29 states.
- Snapshot compile warnings remain in MalwareScanner, Optimization, and SpaceLens.

Known warnings to clean before release:

- `MalwareScannerView.swift`: mutable `var result` can be `let`.
- `OptimizationView.swift`: unused `process` binding.
- `SpaceLensView.swift`: unused `endOuter` value.
