# MacSweep Backlog — Consolidated Implementation Brief

Status date: 2026-07-03
Source: full review of 3 open PRs (#73, #74, #75) and 60 open issues (#10–#123).
Audience: implementing agent (Opus 4.8). Work top-to-bottom by workstream; each workstream lists its issues, dependencies, and verification bar.

## How to use this document

- Every numbered item is a GitHub issue; the issue body is the spec (file paths, line numbers, fix direction, risk, tests). Do not re-derive findings — read the issue, verify against current source, implement.
- Ship small PRs: one workstream slice per PR, never mixed workstreams. P0 fixes may be batched into one PR if each fix stays independently revertable.
- Verification per PR: `swift build` + `zsh scripts/test.sh` locally (focused), full CI on the PR. Deletion-adjacent changes require new/updated tests before the behavior change.
- Close issues via PR body keywords (`Fixes #NN`). Update the tracking issue #121 checklist as items land.

## Step 0 — land the open PRs (blocking everything else)

Merge order: **#75 → #74 → #73**.

1. **PR #75** (`docs: repo-wide DRY/slop audit report`) — docs-only, CI green, merge state CLEAN. Merge as-is.
2. **PR #74** (`docs(audit): repo map — audit 00`) — CI green. Note the title undersells the content: it also adds `docs/audits/01-deletion-safety.md` and `MacSweep/Tests/SafetyCheckerCaseSensitivityTests.swift` (the xfail test that issue #122 depends on). Merge as-is; the test must land before #122 work starts.
3. **PR #73** (`[codex] share cleanup and error banner components`) — **do not merge yet.** Two unresolved CodeRabbit *Major* findings arrived after the last push and are real correctness bugs in the new shared code:
   - `BrowserModule.swift:69` — the running-browser guard executes before `cleanItems` filters by module id, so a running browser can block *unrelated* cleanup on mixed/empty selections. Move the guard after the module filter (or filter first).
   - `SystemCacheModule.swift:233` — directory children are validated as `.file` (line 230) before **permanent** deletion; subdirectory-specific protections are skipped. Validate each child with its real type.

   Fix both on the PR branch, re-run CI, then merge. Once merged, #73 substantially implements #91 (shared `cleanItems`) and the banner half of #100 — see the dedupe notes below before touching either issue.

### Post-merge link fix (one-time)

The `audit:dry-slop` issue bodies (#85–#121) link the report at `blob/claude/keen-northcutt-9021b1/docs/audits/01-dry-slop-audit.md`. That branch dies at merge. After merging #75, batch-edit the links to the master path:

```bash
for n in $(gh issue list --label audit:dry-slop --json number --jq '.[].number'); do
  gh issue edit $n --body "$(gh issue view $n --json body --jq .body | sed 's|blob/claude/keen-northcutt-9021b1/|blob/master/|g')"
done
```

Optional cosmetic: `docs/audits/` ends up with two `01-` files (`01-deletion-safety.md`, `01-dry-slop-audit.md`). If renumbering to `02-dry-slop-audit.md`, do it in the same pass as the link edit; otherwise leave it.

## Issue hygiene — duplicates, stale labels, unlabeled grab-bag

Do these on GitHub before implementation starts, so the backlog is honest.

### Duplicates across the two audits (close or cross-link)

| Keep | Close as duplicate | Why |
| --- | --- | --- |
| #76 + #81 | #90 | #90 (dry-slop) = #76 (leftover deletion, HIGH) + #81 (bundle removal, MEDIUM) from the deletion-safety audit. The safety-audit pair has finer severity/spec. One PR on `AppUninstallerModule` fixes all three; close #90 with a comment pointing at #76/#81, tick it in #121. |

### Issue #123 (unlabeled grab-bag) — split it

#123 collects 15 late bot-review follow-ups from PR #72. Five duplicate existing audit issues; the rest are novel. Edit #123 down to the novel items (and label it `bug` + appropriate priority), striking the duplicated lines with cross-references:

- Duplicated → strike and reference: `CacheAnalyzer.runProcess` pipe deadlock (= #85), `mdls` POSIX locale (= #87), `purge` failures swallowed (= #88), "every error called a safety block" messaging (= #100), directory counted clean despite skipped children + preserve selected dirs on child failures (= #82 / PR #73 review scope).
- Novel → keep in #123 (or split into individual issues if preferred): notification-tap open-or-focus path; `ProcessMonitor.startMonitoring()` double timer; Homebrew stderr/stdout separation (feeds #93 design); free-space wipe files on the requested volume; overlapping AI-analysis cleanup runs; browser service-worker results cleared before replacement scan succeeds; unresolved login-item plist targets; last-scan defaults migration to the app-group suite; Docker TB/T size tokens.

### Stale release labels

v1.0.7 shipped 2026-06-28, but 8 open issues still carry `release:v1.0.7`: #64, #49, #48, #47, #33, #32, #31, #10. Retarget them (label + milestone) to v1.0.8 or v1.1.0. **#64 (signing/notarization) is the standout: it is P0, and v1.0.7 shipped without it — the published cask still installs an ad-hoc-signed, quarantined app.** It should be the first item of the next release, not carried silently.

### Stale planning docs

- `.agents/ROADMAP.md` is dated 2026-06-17 and still frames the release as "v0.1.0" (issue #48's body inherited that). Refresh it (or mark it superseded by the GitHub milestones + this backlog) next time roadmap work is touched.

## Workstream 1 — P0 targeted bug fixes

Independent, each <20 lines, from the dry-slop audit. One batched PR is fine.

- #85 pipe deadlock in `GitArtifactScanner.run` / `CacheAnalyzer.runProcess` (read pipes before `waitUntilExit`)
- #86 GUI `LoginItemsService` missing `geteuid()` root-guard + LaunchDaemons scan (fork drift from Core `LoginItemEnumerator`)
- #87 `AppUninstallerModule` date parser missing `en_US_POSIX`
- #88 `OptimizationView.freeUpRAM()` swallows errors (also closes the `purge` item in #123)
- #89 `NetworkDetailView.formatBytes` uses `.binary` — only divergent `ByteCountFormatter` site

## Workstream 2 — deletion-safety convergence (highest stakes)

The app permanently deletes user files; these are the issues where a bug destroys data. Order matters.

1. #117 — minimal `os.Logger` facade first (`Log.safety` / `Log.scan` / `Log.process`), logging every deletion (path + module + result). Enabler: all later safety fixes get diagnosable.
2. #122 — case-insensitive APFS bypass of protected roots in shred/trash (**fails open**: `validateForShred(~/.SSH)` returns `.safe` and destroys `~/.ssh`). The xfail test from PR #74 flips red when fixed — remove the `withKnownIssue` wrappers in the same PR. Prefer path canonicalization over case-folding so case-sensitive volumes stay correct.
3. #76 + #81 — route `AppUninstallerModule` leftover *and* bundle removal through `SafetyChecker` (also tighten the two-way substring leftover matching per #76's spec). Supersedes #90.
4. #91 — after PR #73 merges, verify all 5 formerly-bypassing modules actually go through the shared `cleanItems`/`CleanupFileRemover` path; close or file the residue.
5. #78 — enforce the 1 GB `DeletionGuard.requiresConfirmation` result (currently dead code: only `.blocked` is matched in `ScanEngine.swift:280`).
6. #77 — dashboard "Clean Selected"/"Clean Recommended" confirmation dialog. Minimal dialog now; the full unified review surface is v1.1.0 issue #38 — do not build #38 here, just stop the zero-confirmation delete.
7. #82 — `SystemCacheModule` recursive child validation before `permanent()` (same code region as PR #73's second CodeRabbit finding — coordinate so it's fixed once).
8. #92 — delete dead `AppState.safetyChecker` / make `ShredderView` use the shared instance.
9. #79 — git worktree removal: use `git status --ignored` (or `--force` awareness) so gitignored content isn't silently destroyed.
10. #80 — Docker `prune -f` scoping + honest dry-run + DeletionGuard visibility.
11. #83 — dev-artifact active-project gate (LOW).
12. #84 — `SSHKnownHostsManager.removeHost` atomic write/locking (LOW).

## Workstream 3 — subprocess consolidation

- #93 is the umbrella: one `ProcessRunner` replacing ~38 hand-rolled `Process()` sites (design in the audit report; the #85 deadlock fix and #123's Homebrew stderr item define the requirements: drain pipes concurrently, keep stderr separate, timeouts everywhere).
- #94 kill `/bin/bash -c` string execution in `CacheAnalyzer`/`MalwareScannerService` (argv arrays).
- #95 single Homebrew path resolver (currently ×5).
- #96 `WiFiNetworkManager.savedNetworks()` duplicate with reversed pipe-drain order — delete the duplicate.
- #97 isolate/document the single osascript `with administrator privileges` escalation site.

Sequence: #94/#96 can go early as targeted fixes; #93 migrates sites incrementally (module-family per PR), #95/#97 fold into it.

## Workstream 4 — headless DTO field fixes

- #98 `HeadlessThreatFinding` add `id`/`isKnownSignature` to CLI JSON.
- #99 `HeadlessCacheFinding.sizeText` → raw byte count (formatting is the client's job).

Small, independent; note CLI JSON is a public-ish contract — mention in CHANGELOG.

## Workstream 5 — view-layer dedupe

Precondition: #120 (move testable logic into the SwiftPM package graph — `Features/`, `App/`, `Background/`, `Services/` are currently unreachable by `swift test`). Do #120 incrementally: as each helper below is extracted, place it inside the package with tests, rather than one big build-system PR.

- #100 remainder after PR #73: the `.errorAlert(message: Binding<String?>)` modifier (×4 hand-copied idiom), the silent Docker/DNS/`print()` failure paths, and the "safety block" mislabeling (overlaps #123 messaging items). PR #73 already delivered the shared banner.
- #101 `formattedTotalSize` extension on `Sequence<CleanupItem>` (10+ views).
- #102 `MetricThresholds` constants + `StatTile`/`AlertBadge` unification (pick intended boundary values deliberately — user-visible).
- #103 shared `ProcessMonitor` for CPU/Memory detail views (kills duplicate 5s `ps` loops).
- #104 `IconStatColumn` component (5 inline copies) + battery-health band helper.
- #105 `NotificationManager` → `ByteCountFormatter` (extract testable `formattedBody(for:)`).

Verification for all of WS5: `scripts/render-screenshots.sh` snapshot pass (29 states) for visual parity.

## Workstream 6 — dead code & repo weight (one batch PR)

- #106 drop `logo.png` (1.5 MB) + `logo.svg` from the Resources build phase (move to docs/marketing dir).
- #107 delete `DevToolsView.selectCachesOnly()`.
- #108 delete `MacSweepEmptyState` / `macSweepDetailSurface` (do **not** force-merge the 7 hand-rolled empty states — they differ visually).
- #109 `WidgetType.system`: either wire the Mac-overview row to a detail panel or delete the case + 3 dead switch arms (pick one; wiring matches the other 6 rows).
- #110 delete `SmartCareAnalyzer.featureName(for:)` + `recommendedFeatureName` (check the headless DTO mirror first).
- #111 `git rm --cached MacSweep/.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata`.

## Workstream 7 — scan-module internals

- #114 `SystemCacheModule` → `DiskAnalyzer.size(of:)` (×2).
- #115 single `BrowserModule.scanPath` computing `lastModified` for all six browsers.
- #116 `PrivacyModule.scanSingleFile` private helper (~6 inline repeats).
- #112 DevTools: derive `projectIndicators` from `allPatterns` (or add the 3 missing entries) + add `validateForScan` to `discoverProjects` — **write the CocoaPods/.NET/CMake detection tests before refactoring the table** (issue spec is explicit about this).

## Workstream 8 — test & tooling infrastructure

- #119 `TempTestDirectory` shared test helper (6 copied init/deinit pairs).
- #120 remainder of the package-graph testability work not absorbed by WS5.
- #113 wire `scripts/RenderSnapshots.swift` into CI or document it (do not delete).
- #31 CLI/app e2e safety smoke suite (dry-run, protected paths, exit codes).
- #32 coverage reporting + branch protection.

## Workstream 9 — release & product roadmap (retargeted from v1.0.7 / v1.1.0)

Next release (v1.0.8 candidates):
- **#64 sign + notarize release artifacts — P0, overdue** (shipped v1.0.7 without it).
- #48 release QA checklist + version alignment (fix the stale "v0.1.0" wording while in there).
- #47 README/screenshots/safety-model docs.
- #33 Full Disk Access onboarding & recovery.
- #49 accessibility/keyboard polish.
- #10 user-configurable ignore/protect rules — implement **after** WS2 lands (it extends `SafetyChecker`; building it on the pre-canonicalization matcher would bake in the #122 bug class).

v1.1.0 (product UX, in priority order): #37, #38 (absorbs the #77 minimal dialog into the full review surface), #39, #42, #43, #44, #41, #45, #40.

Future: #26 iOS companion — out of scope for this backlog.

## Explicitly do NOT "fix" (verified healthy — from the audit)

Scan/clean orchestration sharing across GUI/CLI/headless; the headless DTO boundary itself (only #98/#99 field fixes); `SafetyChecker`/`CleanupFileRemover` as the convergence target; `SystemMonitor.formatSpeed`; per-service error enums; the WiFi/SSH ScanEngine bypass in `NetworkModule.swift:12-33` (deliberate security carve-out — #100 fixes presentation only).
