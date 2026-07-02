# DRY / Slop Audit — MacSweep

**Date:** 2026-07-02
**Scope:** Entire repo (`MacSweep/Sources` ~34,200 LOC Swift, `MacSweep/Tests`, `scripts/`, `.github/`, Xcode project)
**Method:** Two-round multi-agent audit. 18 domain finders swept scan modules, the three execution surfaces (GUI / CLI / headless), core services, all feature views, and cross-cutting concerns (formatting, subprocess execution, error handling, types, dead code, test coverage). Every finding was then adversarially verified by an independent agent that re-read the cited files and graded the claim CONFIRMED / PARTIAL / REFUTED; 8 findings whose verifiers were cut off were re-verified manually. **68 raw findings → 47 verified findings, 0 refuted.** All file:line references below were confirmed against the working tree.

---

## 1. Executive summary

MacSweep's core architecture is **healthier than a typical audit target**: scan/clean orchestration is genuinely shared across GUI, CLI, and headless surfaces (one `ScanEngine`, one `SmartCareAnalyzer`, one `MaintenanceTask.allTasks` table — verified, not duplicated), and `SafetyChecker` + `CleanupFileRemover` are small, well-tested single sources of truth. The slop lives **at the edges**, in four concentrations:

1. **Subprocess execution is the single biggest DRY violation.** ~38 `Process()` sites across 16 files use at least five semantically distinct hand-rolled patterns. Only **1 of 38 sites has a timeout/watchdog**. Two byte-identical runners read both pipes *after* `waitUntilExit` (real >64 KB deadlock: `git status --porcelain` on a dirty repo hangs the scan forever). Two services reintroduce `/bin/bash -c` string execution — one of them on the malware-scanning path, the app's only adversarial-input surface.
2. **The deletion safety net has holes copied around it.** 13 of 15 scan modules re-validate with `SafetyChecker` before deleting; `AppUninstallerModule` — which trashes app bundles and fuzzy-matched "leftovers" under `~/Library` — calls it **zero** times. Five modules validate but then bypass `CleanupFileRemover` and call `FileManager` directly. `OptimizationView` privately reimplements `MaintenanceActions.freeUpRAM()` with a silently-swallowed failure path the changelog claims was fixed app-wide.
3. **GUI vs CLI feature forks have drifted.** `LoginItemsService` (GUI) is a parallel reimplementation of `LoginItemEnumerator` (Core) that is missing the `geteuid() == 0` guard the Core version documents as preventing an infinite hang, and never scans `/Library/LaunchDaemons` — so GUI and CLI show different login items *and* the GUI can hang where the CLI cannot.
4. **View-layer copy-paste is broad but shallow.** One 14-line `errorBanner` is duplicated 12 times (9 byte-identical); cleanup failures are surfaced five different ways (banner / alert / silent `try?` / custom enum / `print`); the `reduce`+`ByteCountFormatter` size-summary idiom is hand-rolled in 10+ views; dashboard threshold colors, pulse animations, and alert badges have quietly divergent constants.

There is also meaningful **dead weight**: a 1.5 MB `logo.png` bundled into every build with zero references, an unreachable `WidgetType.system` enum case carrying three dead switch arms, unused theme components, a dead selection function, a pass-through duplicate API on `SmartCareFinding`, and a tracked file that `.gitignore` explicitly excludes.

Countervailing finding worth stating plainly: the **headless DTO layer is not slop**. All 54 `Headless*` structs are a deliberate `internal`-core → `public Codable` JSON boundary with raw numeric fields and a single encoder site. It should be kept — only two concrete field-drift bugs inside it need fixing.

---

## 2. High-impact duplication clusters

Grouped by business/domain impact. Verifier verdict and divergence notes inline.

### Cluster A — Deletion-safety divergence *(user data at stake)*

| # | Finding | Verdict |
|---|---------|---------|
| A1 | **`AppUninstallerModule` deletes with zero `SafetyChecker` validation.** `AppUninstaller.uninstall()` calls `FileManager.default.trashItem` directly for the bundle ([AppUninstallerModule.swift:337](../../MacSweep/Sources/Core/Scanning/Modules/AppUninstallerModule.swift)) and each leftover (line 348). `findOrphanedLeftovers` (line 216) fuzzy-matches by name substring against `Preferences`, `Application Support`, `Containers`, `LaunchAgents` — several of which appear in `ProtectedPaths.neverDelete` — with no path-safety gate. 13/15 sibling modules re-validate (e.g. [SystemCacheModule.swift:220](../../MacSweep/Sources/Core/Scanning/Modules/SystemCacheModule.swift) with an explicit "Defense-in-depth" comment); `DockerModule` is a legitimate exception (delegates to `docker … prune`, never touches the filesystem). Both the GUI ([AppUninstallerView.swift:265](../../MacSweep/Sources/Features/AppUninstaller/AppUninstallerView.swift)) and headless ([HeadlessService.swift:402](../../MacSweep/Sources/Core/Headless/HeadlessService.swift)) call `uninstall()` with no intermediate wrapper. | CONFIRMED |
| A2 | **Five modules bypass `CleanupFileRemover` in `clean()`.** `DuplicateFinderModule` and `SimilarPhotosModule` call `checker.validateForCleanup(...).isSafe` and then delete via raw `FileManager` instead of the remover, so recoverable-vs-permanent policy is decided per copy-paste site rather than in one place. | PARTIAL (bypass confirmed; "5" includes legitimately different mechanisms) |
| A3 | **Five modules share one copy-pasted `clean()` body** (DuplicateFinder, LargeFiles, MailAttachments, SimilarPhotos, PackageManager) — the same validate→delete→accumulate-errors loop, drifting independently (see A2). | CONFIRMED |
| A4 | **`OptimizationView.freeUpRAM()` privately reimplements `MaintenanceActions.freeUpRAM()`** ([OptimizationView.swift:229-260](../../MacSweep/Sources/Features/Optimization/OptimizationView.swift) vs [MaintenanceActions.swift:9-44](../../MacSweep/Sources/Core/Maintenance/MaintenanceActions.swift)). The private copy `guard … else { return }`s on failure and swallows the purge-launch catch, while the shared one throws `MaintenanceError.commandFailed` and reports `bytesFreed` — the contract used by the Dashboard card ([ContentView.swift:406](../../MacSweep/Sources/Features/Dashboard/ContentView.swift)) and `macsweep maintenance free-ram` ([CLIExecutor.swift:249](../../MacSweep/Sources/CLIKit/CLIExecutor.swift)). This contradicts CHANGELOG 1.0.2: "The GUI now surfaces deletion and scan errors instead of silently swallowing them." | CONFIRMED |
| A5 | **`AppState.safetyChecker` has zero consumers** while [ShredderView.swift:347](../../MacSweep/Sources/Features/Shredder/ShredderView.swift) constructs its own `SafetyChecker` for `validateForShred` — a dead injection point plus an unmanaged local instance (verifier discovery while checking the orchestration claim). | CONFIRMED |

### Cluster B — Subprocess execution (~38 `Process()` sites, ≥5 distinct patterns)

| # | Finding | Verdict |
|---|---------|---------|
| B1 | **Only 1 of ~38 sites has a timeout.** [ConnectedDevice.swift:302-332](../../MacSweep/Sources/Core/Monitoring/ConnectedDevice.swift) `runProcess` has a `DispatchWorkItem` watchdog (10 s default); `SystemMonitor.runCommand` (552-577) and `ProcessMonitor.sampleProcessStats` (102-139) reimplement the identical continuation body with **no** watchdog — accidental divergence (their comments explain drain ordering, never timeouts). The family spans at least five semantically distinct implementations: watchdog / no-watchdog continuation, `Task.detached`, `terminationHandler`, `readabilityHandler` streaming ([HomebrewService.swift:208-231](../../MacSweep/Sources/Core/Services/HomebrewService.swift) uses two different mechanisms in one file), and fully synchronous. | PARTIAL (pattern confirmed; "one pattern ×14" understated the variance) |
| B2 | **Byte-identical two-pipe deadlock pair.** `GitArtifactScanner.run` ([DevToolsModule.swift:1167-1188](../../MacSweep/Sources/Core/Scanning/Modules/DevToolsModule.swift)) and `CacheAnalyzer.runProcess` ([CacheAnalyzer.swift:335-354](../../MacSweep/Sources/Core/Services/CacheAnalyzer.swift)) both `run(); waitUntilExit()` and only then read stdout **and** stderr. With >64 KB of output (`git status --porcelain` on a dirty repo — called at lines 1131 and 1238) the child blocks on a full pipe and the scan hangs forever. [AssistantConversationService.swift:383-404](../../MacSweep/Sources/Core/Assistant/AssistantConversationService.swift) proves the correct concurrent-drain pattern already exists in-repo. Single-pipe read-after-wait also occurs in `NetworkModule` (123-125, 170-172, 464-466) and `DockerModule` (222-224, 304-306, 386-388) — lower risk (stderr nulled) but same idiom. | PARTIAL (deadlock pair confirmed; "every other site drains first" was false) |
| B3 | **`/bin/bash -c` string execution reintroduced** in `CacheAnalyzer.shell()` and `MalwareScannerService.shell()` alongside the codebase's otherwise argv-style launches. The malware scanner is the app's only adversarial-input surface (it inspects untrusted files) and has **no timeout** either — worst-case combination. | CONFIRMED |
| B4 | **Five independent Intel/Apple-Silicon Homebrew path resolvers** with inconsistent existence checks (`/opt/homebrew` vs `/usr/local` probing re-derived per site, DockerModule et al.). | PARTIAL |
| B5 | **`NetworkModule.flushWithAdmin()`** is the only site escalating privilege via `osascript 'with administrator privileges'` — a one-off pattern with no shared review point. | CONFIRMED |
| B6 | **`WiFiNetworkManager.savedNetworks()` duplicates `savedNetworks(interface:)`** instead of delegating — plus the round-1 verifier found its copy has the reversed drain/wait order. | CONFIRMED |

### Cluster C — GUI/CLI feature forks with user-visible drift

| # | Finding | Verdict |
|---|---------|---------|
| C1 | **`LoginItemsService` (GUI) is a parallel reimplementation of `LoginItemEnumerator` + `LoginItemController` (Core).** The Core file even carries a comment documenting the intentional port — but the copies have since diverged. | PARTIAL (parallel impl confirmed; some divergence intentional) |
| C2 | **The GUI copy is missing the `geteuid() == 0` root-guard.** [LoginItemEnumerator.swift:29-32](../../MacSweep/Sources/Core/Services/LoginItemEnumerator.swift): "`sfltool dumpbtm` requires root on macOS 13+ … it would hang the caller … Skip it unless we're root," followed by `guard geteuid() == 0 else { return [] }`. [LoginItemsService.swift:45-58](../../MacSweep/Sources/Features/LoginItems/LoginItemsService.swift) runs the exact same `sfltool dumpbtm` unconditionally. | CONFIRMED |
| C3 | **The GUI never scans `/Library/LaunchDaemons`** (`grep -ci launchdaemon` = 0 in LoginItemsService) while the Core enumerator does (lines 14, 21) — GUI and CLI report different sets of login items. | CONFIRMED (manual verify) |
| C4 | **`DevToolsModule` maintains two artifact-pattern tables.** `DevArtifactPattern.allPatterns` (lines 182-441, 30 entries) drives the cleanup scan; `projectIndicators` (lines 538-549, 10 entries) drives the per-project browser. CocoaPods, .NET, and CMake are genuinely absent from the browser table — their `ProjectType.dotnet`/`.xcode` cases have full icon/color/regenerate-command plumbing (500-530, DevToolsView.swift:740/744) but are **never constructible**. (Next.js/Nuxt/Turbo/Bun are covered as node subdirs — the original claim overstated that part.) | PARTIAL |
| C5 | **`discoverProjects()` skips the `SafetyChecker.validateForScan` gate that `scanForPatterns()` applies** (checker at lines 82-83/111 only; `discoverProjects` starts at 535) — protected paths can be listed and made selectable in the project-browser UI. Deletion-time safety still holds downstream. | CONFIRMED (manual verify) |

### Cluster D — View-layer copy-paste

| # | Finding | Verdict |
|---|---------|---------|
| D1 | **`errorBanner(_:)` duplicated 12× across 11 files, 9 byte-identical** (MD5-verified by the round-1 verifier): SimilarPhotosView:58, PrivacyView:77, AppUninstallerView:72, NetworkCleanupView:85 & 399 (twice in one file), BrowserCleanupView:49, LargeFilesView:92, CloudCleanupView:75, SpaceLensView:75, DuplicateFinderView:58; TrashBinsView:190 is whitespace-reformatted; HomebrewUpdaterView:141 diverges (dismisses via `service.error = nil`). | PARTIAL (count corrected upward) |
| D2 | **Cleanup-failure feedback presented five different ways** for the same event class: inline banner; `.alert` (5 files); silent `_ = try? await DockerCleanupActions.pruneX()` ([PackageManagersView.swift:166-203](../../MacSweep/Sources/Features/DevTools/PackageManagersView.swift)); a custom `FlushResult` enum ([NetworkCleanupView DNSCacheView:648-655](../../MacSweep/Sources/Features/NetworkCleanup/NetworkCleanupView.swift)); and console-only `print(...)` ([DevToolsView.swift:503,510](../../MacSweep/Sources/Features/DevTools/DevToolsView.swift)). Note: the WiFi/SSH paths bypass `ScanEngine` **deliberately** (documented security carve-out at NetworkModule.swift:12-33) — the fix is presentation-level, not re-routing. | PARTIAL |
| D3 | **`Optional<String>` → `Bool` `Binding(get:set:)` alert idiom hand-copied in exactly 4 files** (MailAttachmentsView:52-61, PackageManagersView:35-44, SystemCleanupView:50-59, LoginItemsView:64-71). | CONFIRMED |
| D4 | **`reduce` + `ByteCountFormatter` size-summary boilerplate in 10+ views** (`totalSize`/`selectedSize` computed properties; e.g. CloudCleanupView:242-250 ≈ SimilarPhotosView:207-215 ≈ TrashBins/LargeFiles/DuplicateFinder/MailAttachments/BrowserCleanup/DevTools/PackageManagers/Privacy). Behavior is consistent (all `.file`) — purely structural repetition. | CONFIRMED |
| D5 | **Three hand-rolled metric-alert-threshold implementations with divergent boundary values** across MenuBarView / DashboardView — the same "CPU/RAM is critical" concept flips at different percentages depending on which surface you look at. `SystemStatCard` (menu bar tile) and `SystemStatusRow` (dashboard row) are parallel implementations of the same tile. | CONFIRMED |
| D6 | **Critical-state pulse animation copy-pasted 4× with silently divergent opacity/duration values**; **alert badge (Critical/Warning pill) has three incompatible visual implementations**; **connected-devices count string diverges** between menu bar ("connected") and dashboard ("devices"). | CONFIRMED (all three) |
| D7 | **CPU and Memory detail views each instantiate their own `ProcessMonitor`** (`@StateObject private var processMonitor = ProcessMonitor()` at CPUDetailView.swift:6 and MemoryDetailView.swift:6) — two concurrent 5 s `ps` sampling loops when both popovers have been opened. | CONFIRMED (manual verify) |
| D8 | **Icon/value/label stat column hand-written 5×** (BatteryDetailView `statusSection`:117-163, NetworkDetailView `connectionDetails`:128-162) while three separate named components for near-identical purposes already exist (`DetailBox` BatteryDetailView:293, `StatItem` StorageDetailView:197, `UsagePill` CPUDetailView:153). | CONFIRMED (manual verify) |

### Cluster E — Formatting drift (same number renders differently by screen)

| # | Finding | Verdict |
|---|---------|---------|
| E1 | **`NetworkDetailView.formatBytes` uses `.binary`** ([NetworkDetailView.swift:168-172](../../MacSweep/Sources/Features/Dashboard/WidgetDetails/NetworkDetailView.swift)) — the only `.binary` site among ~70 `ByteCountFormatter` call sites; disk totals use `.file`, RAM uses `.memory` (a separate, intentional convention). The same byte count shows different values on different screens. | PARTIAL (core claim confirmed; a second cited symbol was innocent) |
| E2 | **`NotificationManager` hand-rolls GB/MB math** ([NotificationManager.swift:28-35](../../MacSweep/Sources/Background/NotificationManager.swift)) with `String(format:)` division instead of `ByteCountFormatter` — the weekly-scan notification's size text can disagree with every in-app display of the same number. | CONFIRMED |
| E3 | **`AppUninstallerModule`'s shell-date parser is missing `en_US_POSIX`** ([AppUninstallerModule.swift:179-181](../../MacSweep/Sources/Core/Scanning/Modules/AppUninstallerModule.swift)) while `DevToolsModule.parseGitDate` (1200-1203) sets it on a **byte-identical format string** — `mdls` date parsing silently fails on non-Gregorian/12-hour-locale systems. Related: `RelativeDateTimeFormatter` uses `.abbreviated` in DevTools vs `.full` in DashboardView:629 for the same concept. | CONFIRMED |
| E4 | **`HeadlessCacheFinding.sizeText` is a pre-formatted `String`** ([HeadlessModels.swift:380](../../MacSweep/Sources/Core/Headless/HeadlessModels.swift)) — the only size field in the entire headless DTO layer that isn't raw bytes (`HeadlessFinding.size:75`, `HeadlessAppLeftover.size:432`, etc. are all `Int64`/`UInt64`). JSON consumers can't sum or compare it. | CONFIRMED (manual verify) |
| E5 | **`HeadlessThreatFinding` drops `ThreatFinding.id` and `isKnownSignature`** (HeadlessModels.swift:530-553 vs [MalwareScannerModels.swift:44-53](../../MacSweep/Sources/Core/Services/MalwareScannerModels.swift)) — CLI/automation consumers cannot dedupe findings or distinguish "known signature" from "review-tier", the exact distinction the `ThreatLevel` doc comment says matters. | CONFIRMED (manual verify) |

### Cluster F — Scan-module internals

| # | Finding | Verdict |
|---|---------|---------|
| F1 | **`SystemCacheModule` hand-rolls the `isDirectory`-branch sizing that `DiskAnalyzer.size(of:)` already implements — twice in the same file.** | CONFIRMED |
| F2 | **Six `BrowserModule.scanPath()` copies diverge on `lastModified`** — only the Chrome copy computes it; five hardcode `nil`, so stale-data hints render for one browser only. | CONFIRMED |
| F3 | **`PrivacyModule` repeats the `exists → size → CleanupItem` block ~6×** inline for single files while `ScanModule.scanCacheDirectory` (ScanModule.swift:24-33) centralizes the directory variant. Not a drop-in (single-file vs directory semantics) — a local `scanSingleFile` helper is the right size. | CONFIRMED (manual verify) |

---

## 3. Dead / obsolete code candidates

All grepped repo-wide (Sources, Tests, `project.pbxproj`, scripts, `.github`) before being called dead.

| Item | Evidence | Action |
|------|----------|--------|
| `Sources/Resources/logo.png` (**1.5 MB**) + `logo.svg` | In `PBXResourcesBuildPhase` (project.pbxproj:889-890); zero Swift references (icons come from `Assets.xcassets`) | Remove from Resources phase; delete or move to a `marketing/` dir. Pure bundle bloat |
| `DevToolsView.selectCachesOnly()` | Defined [DevToolsView.swift:481-489](../../MacSweep/Sources/Features/DevTools/DevToolsView.swift); zero call sites; `private`, no `@objc` | Delete (or wire the intended "Select Caches Only" button) |
| `MacSweepEmptyState` + `macSweepDetailSurface()` | [LiquidGlass.swift:165 / :151](../../MacSweep/Sources/App/LiquidGlass.swift); zero call sites — meanwhile 7 hand-rolled private `emptyState` views exist in 6 files | Delete both; optionally consolidate the 7 hand-rolled ones later (they differ visually — check before merging) |
| `WidgetType.system` | Declared [DashboardView.swift:5](../../MacSweep/Sources/Features/Dashboard/DashboardView.swift); `toggleWidget` called only with the other 6 cases (lines 445-537); final `SystemStatusRow` (555) is not tappable → carries three dead switch arms in `MenuBarDetailPanel` (body:91 `EmptyView()`, title:113, feature:124) | Remove case + 3 arms, or wire the Mac-overview row to a detail |
| `SmartCareAnalyzer.featureName(for:)` + `SmartCareFinding.recommendedFeatureName` | [SmartCare.swift:103](../../MacSweep/Sources/Core/Scanning/SmartCare.swift) is a pure pass-through to `title(for:)`; the struct field is always identical to `title` | Delete function + field; callers read `title` |
| `AppState.safetyChecker` | Zero consumers repo-wide; ShredderView builds its own instance | Delete property (or actually inject it into ShredderView) |
| `ProjectType.dotnet` / `.xcode` plumbing | Full icon/color/regenerateCommand switch arms (DevToolsModule.swift:500-530, DevToolsView.swift:740/744) but never constructible — `projectIndicators` lacks their indicator entries | Fix C4 (derive table) or delete the cases |
| `MacSweep/.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata` | Tracked in git despite `.gitignore:22` excluding `.swiftpm/`; pure boilerplate | `git rm --cached` |
| `scripts/RenderSnapshots.swift` + `render-screenshots.sh` | **Not dead** — compiles against live symbols and is the only visual QA for 29 GUI states — but referenced by no CI job, README, or doc | Wire into CI or add a README pointer; do not delete |

---

## 4. Inconsistent local patterns

Beyond the clusters above, patterns that are locally fine but globally incoherent:

- **Logging does not exist.** Zero hits repo-wide for `Logger(`, `import os`, `NSLog(`. The only diagnostics are 3 ad-hoc `print()` calls (MalwareScannerService.swift:548, DevToolsView.swift:503/510 — the 4 in CLIExecutor are legitimate CLI stdout). An app that irreversibly deletes files has no way to diagnose a bad deletion after the fact.
- **Silent `catch` blocks:** 5 well-commented catch-and-ignore sites in best-effort informational paths (NetworkModule:139/185/484, MaintenanceActions:80, ProcessMonitor:132). Acceptable today; should become debug-level log lines once a logger exists.
- **16 per-service `LocalizedError` enums**, of which only ~4 are the degenerate one-case/reason-string shape (`TrashError`, `PrivacyError`, `NetworkError`, `DNSError`). Verifier verdict: case names carry domain meaning, callers never cross-catch — **do not force a universal error enum**; at most a `protocol OperationFailure: LocalizedError` default-formatter if new services keep repeating the shape.
- **`.background(.ultraThinMaterial, in: RoundedRectangle(...))` hand-rolled** in MenuBar views, bypassing the LiquidGlass helpers used elsewhere.
- **Test suite:** six test classes hand-roll the identical UUID-scoped temp-dir `init`/`deinit` pair; `SystemCacheModuleTests` uniquely (and redundantly) gates its `deinit` on `fileExists` — a holdover, not a design decision.
- **CLI's two TTY confirmation helpers** (`confirmCleanup` CLIExecutor:1086-1102, `confirm` :1107-1116) are near-identical; fold one into the other next time the file is touched.

**Explicit non-findings (verified healthy — do not "fix"):**
- Scan/clean orchestration across the three surfaces (one engine, thin adapters). This was the audit's central risk and it is **not present**.
- `CleanupFileRemover` (26 lines) + `SafetyChecker`: the model the rest of the code should converge on — no force-unwraps, well-tested.
- The 54-struct headless DTO layer: deliberate API-stability boundary (`internal` non-Codable core types → `public Codable` DTOs, one encoder site). Keep; fix only E4/E5.
- `SystemMonitor.formatSpeed`: documented single source of truth with intentional sub-1-kbps flattening ("0 KB/s" instead of jitter). Swapping in `ByteCountFormatter` would be a regression.
- CLI `moduleDisplayPriority` vs GUI `feature(for:)`: different questions (text sort order vs sidebar mapping), both legitimately presentation-only.

---

## 5. Recommended shared modules / components

Only abstractions that remove real, demonstrated complexity:

1. **`ProcessRunner`** (Core/Services) — `run(executable:arguments:timeout: = 10s) async throws -> ProcessResult`. Argv-only (no `bash -c`), concurrent pipe drain before reap (pattern already proven in AssistantConversationService:383-404), watchdog terminate (pattern from ConnectedDevice:302), checked `terminationStatus`. Replaces ~38 hand-rolled sites; deletes the B2 deadlocks and B1 hang-risk by construction. **This is the highest-value abstraction in the audit.**
2. **`ErrorBanner` view + `.errorAlert(message: Binding<String?>)` modifier** (Features/Shared) — deletes 12 banner copies and 4 binding idioms; becomes the single cleanup-failure presentation primitive (D1/D2/D3). Keep it message + dismiss closure; no further generalization.
3. **`Sequence<CleanupItem>.formattedTotalSize(selected:)` extension** — collapses the D4 boilerplate in 10+ views. One small extension, no protocol ceremony.
4. **`MetricThresholds` constants + one `StatTile` component** — single source for critical/warning boundaries, pulse animation constants, and alert-badge rendering (D5/D6); `SystemStatCard`/`SystemStatusRow` become two thin layouts over one model.
5. **`DateFormatter.posixShellDate(format:)`** — shared by AppUninstaller/DevTools shell-output parsers; fixes E3 as a side effect.
6. **`TempTestDirectory`** test-support value type (create-on-init / remove-on-deinit) — replaces six copied init/deinit pairs; keep XCTest-agnostic.
7. **Minimal `os.Logger` facade** (e.g. `Log.safety`, `Log.scan` categories) — prerequisite for making the 5 silent catches and every deletion visible in Console.app.

**Deliberately not recommended:** universal error enum (loses domain meaning); merging Headless DTOs into core types (leaks JSON-shape concerns into the scan engine); generalizing `scanCacheDirectory` to single files (signature churn for 6 call sites — a private `PrivacyModule.scanSingleFile` is the right size); replacing `formatSpeed`.

---

## 6. Refactor roadmap (ordered by ROI)

Ordered by (user-facing risk removed × effort saved) ÷ refactor risk. Phases 1–2 are bug-adjacent; 3–5 are hygiene.

| Phase | Work | Why first/later |
|-------|------|-----------------|
| **P0 — targeted bug fixes** (small diffs, big risk removed) | (a) Fix B2 deadlock pair: drain-before-wait in `GitArtifactScanner.run` + `CacheAnalyzer.runProcess`. (b) Add `geteuid()` guard + LaunchDaemons scan to `LoginItemsService` (C2/C3). (c) Add `en_US_POSIX` to AppUninstaller date parser (E3). (d) Route `OptimizationView` through `MaintenanceActions.freeUpRAM()` (A4). (e) `.binary` → `.file` in NetworkDetailView (E1). | Each is <20 lines, independently shippable, and removes a real user-visible defect (hang, hang, wrong dates, swallowed failure, wrong numbers). |
| **P1 — deletion-safety convergence** | Add `SafetyChecker` gates to `AppUninstaller.uninstall()` + leftover deletion (A1); route the five bypassing modules through `CleanupFileRemover` (A2); dedupe the shared `clean()` body into a protocol extension or free helper (A3); delete `AppState.safetyChecker` or inject it (A5). | Highest-stakes domain. Do after P0 so the diff is purely about the safety net. Caveat from verifier: gate the *bundle* trash on a validation mode that allows `/Applications` bundles — naive `validateForCleanup` reuse would block legitimate uninstalls. |
| **P2 — `ProcessRunner` consolidation** | Introduce the runner (module 1 above); migrate sites in risk order: MalwareScannerService + CacheAnalyzer `shell()` first (kills `bash -c`, B3), then NetworkModule/DockerModule/Maintenance, then monitors. Delete B4's five Homebrew resolvers into one `HomebrewPaths` helper during the same sweep. | Big but mechanical after P0 proved the drain/watchdog pattern. Migrate incrementally — each site is independently testable. |
| **P3 — headless DTO field fixes** | Add `id` + `isKnownSignature` to `HeadlessThreatFinding` (E5); add raw `sizeBytes` alongside (or replacing) `sizeText` (E4). | Additive Codable changes; coordinate with any JSON consumers (additive = backward-compatible). |
| **P4 — view-layer dedupe** | `ErrorBanner` + `.errorAlert` (D1/D2/D3); `formattedTotalSize` extension (D4); `MetricThresholds`/`StatTile` (D5/D6/D7 — also share one `ProcessMonitor` via `@EnvironmentObject`); `IconStatColumn` (D8); NotificationManager → `ByteCountFormatter` (E2). | Pure presentation; large LOC win (~400+ lines deleted), near-zero semantic risk. |
| **P5 — dead-code sweep** | Everything in §3: logo assets, `selectCachesOnly`, `MacSweepEmptyState`/`macSweepDetailSurface`, `WidgetType.system` + arms, `featureName`/`recommendedFeatureName`, `.swiftpm` untrack, `ProjectType` decision (fix C4 table derivation or delete cases), RenderSnapshots CI wiring. | Mechanical deletions; do last (or opportunistically) since nothing depends on order. |
| **P6 — test infrastructure** | `TempTestDirectory` helper; normalize SystemCacheModuleTests deinit; then the structural gap: `App/`, `Features/`, `Background/`, `Services/` are **outside the SwiftPM package graph** (Package.swift builds only Core + CLIKit) — structurally unreachable by `swift test`. Moving testable logic (view-model state machines, NotificationManager formatting, threshold logic) into the package is the enabler for testing P4's shared components. | Biggest effort, longest payoff; sequence last but start extracting *new* shared code (ProcessRunner, MetricThresholds) into the package from day one so it's testable immediately. |

---

## 7. Risk level and test coverage needed per refactor

Test-coverage baseline (from the coverage sweep): 22 test files cover Core parsing/safety well (`SafetyCheckerTests`, `CleanupFileRemoverTests`, `ScanEngineTests`, `HeadlessServiceTests`, `SmartCareAnalyzerTests`, `DeletionGuardTests`, codec/parser tests). **Zero coverage:** 11 of 15 scan modules' scan/clean paths, `MaintenanceActions`, `SecureDelete`, both monitors, `HomebrewService`, `AIKeychainService`, `FullDiskAccess`, `AssistantConversationService`, and everything outside the package graph (all Features/ views, App/, Background/, AIAnalysisService).

| Refactor | Risk | Required tests before merging |
|----------|------|-------------------------------|
| P0a drain-before-wait fix | **Medium** (touches live scan path) | New: >64 KB-output subprocess test proving no deadlock in `GitArtifactScanner.run` / `CacheAnalyzer.runProcess`. Existing `GitArtifactScannerTests`/`CacheAnalyzerTests` cover parsing only |
| P0b LoginItems root-guard + daemons | **Medium** | New: `LoginItemsService.scan()` test with `sfltool` stubbed; parity assertion vs `LoginItemEnumerator` categories. Existing enumerator/controller tests are the template |
| P0c POSIX locale | **Safe-mechanical** | Optional: one date-parse unit test with a 12-hour-locale fixture |
| P0d OptimizationView delegation | **Medium** (error contract change: silent → surfaced) | New: `MaintenanceActions.freeUpRAM()` success + `commandFailed` paths (currently zero coverage for all of MaintenanceActions) |
| P0e `.binary` → `.file` | **Safe-mechanical** | None (display-only); visual check via RenderSnapshots |
| P1 SafetyChecker in AppUninstaller | **High** (deletion path; naive gating breaks legitimate `/Applications` uninstalls) | New: `AppUninstallerModule` tests — uninstall trashes bundle, leftover fuzzy-match never selects a `ProtectedPaths.neverDelete` path, validation-rejection path. Currently zero references to AppUninstaller in Tests |
| P1 CleanupFileRemover routing + shared clean() | **High** | Extend `ScanEngineTests`/`CleanupFileRemoverTests`: per-module clean() test asserting removal goes through the remover (recoverable vs permanent) and errors accumulate; snapshot the five modules' behavior before/after |
| P2 ProcessRunner | **High in aggregate, low per-site** | New: ProcessRunner unit tests (timeout kill, exit-code throw, large-output drain, argv no-shell). Migrate one site per PR; sites with existing tests (ConnectedDeviceScannerTests) first |
| P3 Headless DTO fields | **Low** (additive Codable) | Extend `HeadlessSerializationTests` with the new fields; assert old JSON still decodes |
| P4 view dedupe | **Low** (presentation) | Unit test `formattedTotalSize` (empty/single/filtered/0-byte) and `MetricThresholds` boundaries once in the package; RenderSnapshots pass for visual parity. No view tests exist or are required for the banner/alert swaps |
| P5 dead code | **Safe-mechanical** | None beyond a clean `xcodebuild` + `scripts/test.sh` run; `git rm --cached` needs no test |
| P6 test infra / package-graph moves | **Medium** (build-system change) | CI green on both toolchain paths in `scripts/test.sh` (full Xcode and CLT-only); no new behavior tests needed for `TempTestDirectory` itself |

---

*Audit artifacts: 68 raw findings from 18 finder agents across 2 rounds; every surviving finding adversarially re-verified against source (verdicts and corrections embedded above). Refuted claims: 0; overstated claims corrected: 10 (noted as PARTIAL with the correction applied in the text).*
