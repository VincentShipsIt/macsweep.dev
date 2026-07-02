# MacSweep — Deletion Safety Audit (Audit 01)

Date: 2026-07-02
Auditor: Claude Code (adversarial safety review; evidence-first, no code changes)
Scope: the deletion / trash / shred / prune path — "can MacSweep remove something the user did not intend, or fail to protect a path it promises to protect?"
Baseline: full test suite green before audit — `262 tests in 22 suites passed` via `./scripts/test.sh` on Command Line Tools toolchain (Swift 6.3.3, no Xcode).

Method note: an 8-hunter adversarial fan-out generated candidates; a 3-lens refutation pass was meant to verify each. The verify pass was cut short by an API session limit, so **every finding below was re-verified by hand against source** (file+line reads quoted). Several candidates the automated pass marked "rejected" were rejected only because their verifier agents were killed mid-run (zero refutation reasons recorded) — those were re-examined from scratch here, not taken as cleared.

The safety architecture is genuinely good in the common path: `SafetyChecker` is default-deny for automated cleanup, most modules re-validate at delete time (`ScanEngine.clean` re-runs `validateForCleanup` on every item, `SystemCacheModule.clean:231` does it again), parent-symlink resolution defeats the classic link-swap attack (`SafetyChecker.realParentPath:247-269`), and Darwin's `FileManager.removeItem`/`trashItem` do not follow a final-component symlink. The findings are where code steps **outside** that gate.

---

## Findings summary

| # | Sev | Title | File |
|---|-----|-------|------|
| 1 | HIGH | App-uninstaller leftover deletion bypasses SafetyChecker entirely | `AppUninstallerModule.swift` |
| 2 | HIGH | Dashboard "Clean Selected"/"Clean Recommended" delete with no confirmation | `DashboardView.swift` |
| 3 | HIGH | 1 GB `requiresConfirmation` threshold computed but never enforced | `SafetyChecker.swift` / `ScanEngine.swift` |
| 4 | HIGH | Git worktree removal permanently deletes gitignored content, ungated | `DevToolsModule.swift` |
| 5 | MED | Docker `clean()` runs unscoped `prune -f`; fake dry-run, DeletionGuard blind | `DockerModule.swift` |
| 6 | MED | App-bundle removal path also skips SafetyChecker | `AppUninstallerModule.swift` |
| 7 | MED | SystemCache recursively permanent-deletes child subtrees without validating descendants | `SystemCacheModule.swift` |
| 8 | LOW | Dev-artifact deletion has no active-project/git gate (mitigated: Trash + regenerable) | `DevToolsModule.swift` |
| 9 | LOW | `SSHKnownHostsManager.removeHost` read-modify-write with no lock | `NetworkModule.swift` |

Dismissed on hand-review: SystemCache permanently deleting `/private/var/folders/*/T` temp files — those are regenerable OS scratch, permanent removal is policy-consistent (`CleanupFileRemover` header); not a defect.

---

## 1. HIGH — App-uninstaller leftover deletion bypasses SafetyChecker entirely

**Files:** `MacSweep/Sources/Core/Scanning/Modules/AppUninstallerModule.swift:253-309` (match), `:313-362` (delete)
**Reachable from:** `AppUninstallerView.swift:262-265` (GUI), `HeadlessService.swift:402` (headless API), `CLIExecutor.swift:373` (`macsweep uninstall`).

Leftovers are matched by a **two-way case-insensitive substring test** against app name / bundle id (`scanForAppData`, `:273-276`), then trashed directly:

```swift
try FileManager.default.trashItem(at: leftover.path, resultingItemURL: nil)   // :348
```

There is no `SafetyChecker.validateForCleanup` anywhere in `uninstall()` or in any of its three callers — verified by grepping `CLIExecutor.swift` and `HeadlessService.swift` (both empty around the uninstall path). Every *other* delete site in the codebase validates immediately before removal; this is the one caller-facing path fully outside the default-deny gate.

**Scenario:** uninstalling an app whose display name or bundle-id fragment is a substring/superstring of an unrelated vendor folder under `~/Library/Application Support` (e.g. an app literally named "Mail" or "Notes", or a shared bundle-id token) matches that folder and trashes it — no protected-path check, no sensitive-filename check, no symlink check.

**Mitigation in place:** removal is to Trash (recoverable), not permanent.
**Fix direction:** route every leftover through `SafetyChecker.validateForTrash` (the blocklist variant) before `trashItem`, and tighten `scanForAppData` matching from substring to path/prefix + known-bundle-id exact match.

## 2. HIGH — Dashboard clean buttons delete with no confirmation

**File:** `MacSweep/Sources/Features/Dashboard/DashboardView.swift:122-132` (toolbar "Clean Selected"), `:207-217` (inline "Clean Selected")

Both call the destructive path directly, error-swallowed, no dialog:

```swift
Button { Task { _ = try? await appState.deleteSelected() } } label: { Image(systemName: "trash") }   // :123-129
```

`AppState.deleteSelected(dryRun:false)` (`AppState.swift:75`) is a pure passthrough to `scanEngine.clean(dryRun:false)` with **zero built-in confirmation** — gating is delegated entirely to callers. Verified: `DashboardView.swift` and `ContentView.swift` contain **0** `.confirmationDialog`/`.alert` (grep count 0). Every other delete surface gates first — e.g. `SystemCleanupView.swift:133-145` wraps the identical `deleteSelected()` call in a `.confirmationDialog` reading "This action cannot be undone."

**Scenario:** one click on the dashboard's marquee "Clean Recommended"/"Clean Selected" trashes (and for `system-cache`/`cloud-cleanup` modules **permanently deletes** — see #7) every selected Smart Care item with nothing between the click and the removal. This is the app's most prominent cleanup control.

**Fix direction:** wire the same `showingConfirmation` + `.confirmationDialog` the other 13 views use; ideally show byte total in the message.

## 3. HIGH — 1 GB confirmation threshold is dead code

**Files:** `MacSweep/Sources/Core/Safety/SafetyChecker.swift:632-651`, `MacSweep/Sources/Core/Scanning/ScanEngine.swift:280-285`

`DeletionGuard.preflightCheck` returns `.requiresConfirmation(size:)` above the 1 GB `confirmationThreshold` (`SafetyChecker.swift:638-640`). The **only** caller matches solely `.blocked`:

```swift
if case .blocked(let reason) = deletionGuard.preflightCheck(items: aggregate) {   // ScanEngine.swift:282
    throw ScanEngineError.deletionBlocked(reason: reason)
}
```

`.requiresConfirmation` falls through and the delete proceeds. Grep confirms no other caller of `preflightCheck`/`requiresConfirmation` exists anywhere. So the 1 GB confirmation control the design advertises provides **no protection at any layer** — only the 10 GB hard `.blocked` cap does anything.

**Scenario:** cleaning 8 GB of items proceeds with no threshold-driven confirmation from the engine; the only backstop is whatever per-view dialog exists (and #2 shows the dashboard has none, and none of the dialogs check size).

**Fix direction:** either handle `.requiresConfirmation` (surface a size-gated confirm to CLI `--yes`/GUI dialog) or delete the threshold and its enum case so the safety story matches the code.

## 4. HIGH — Git worktree removal permanently deletes gitignored content, ungated

**File:** `MacSweep/Sources/Core/Scanning/Modules/DevToolsModule.swift:1130-1134` (clean check), `:1238-1245` (removal), scan gate `:812-852`

Cleanliness is judged by:

```swift
run(["git","-C",url.path,"status","--porcelain","--ignore-submodules"]).output …isEmpty   // :1131
```

`git status --porcelain` **does not list gitignored files** (needs `--ignored`). Removal then runs `git worktree remove <path>` **without `--force`** (`:1245`) — and git's own guard only refuses on tracked/untracked changes, not on ignored files. So a worktree whose only extra content is gitignored (a real `.env` with secrets, a local SQLite db, an un-pushed build artifact) reads as "clean" and is removed. `git worktree remove` deletes the directory tree **permanently** (not to Trash) and the whole path never passes `SafetyChecker` — it is a raw `git` subprocess.

Scan surfacing (`discoverWorktrees`, `:812-852`) requires: not the main worktree, git-clean (misses ignored), stale by age, AND either a merged/gone branch (`branchState.isSafeToClean`) or an ephemeral agent-worktree root. Search root defaults to all of `$HOME`, so blast radius is any stale merged-branch worktree under home — not just agent dirs.

**Scenario:** a developer keeps a feature-branch worktree with a local `.env` (API keys) and a dev database, both gitignored. Branch merges upstream; worktree goes stale. MacSweep surfaces it as a clean stale worktree and `git worktree remove` permanently destroys the `.env` and the db.

**Fix direction:** run the cleanliness check with `--ignored` (or `git clean -ndx` preview) and refuse if any ignored content with nonzero size exists; never rely on `git worktree remove` succeeding to imply "nothing valuable lost."

## 5. MEDIUM — Docker `clean()` runs unscoped `prune -f`; fake dry-run, DeletionGuard blind

**File:** `MacSweep/Sources/Core/Scanning/Modules/DockerModule.swift:145-205`

`clean()` dispatches on `item.moduleName` and runs host-wide prunes: `docker builder prune -f`, `image prune -f`, `container prune -f`, `volume prune -f`. These are scoped by *category* but not by *what was scanned* — `volume prune -f` removes **all** unused volumes, `container prune -f` **all** stopped containers, regardless of the specific `CleanupItem`s presented. Docker's own semantics limit this to *unused* resources, but a stopped container holding uncommitted filesystem changes, or an unused-but-wanted named volume with real data, is destroyed.

Two compounding problems:
- **Dry-run is fake:** `if dryRun { freed += item.size }` (`:155`) just echoes the scan-time size; there is no `docker … --dry-run`/`system df` preview of what prune would actually remove.
- **DeletionGuard is blind:** Docker `CleanupItem`s carry synthetic paths and scan-time sizes; the byte-cap preflight can neither meaningfully bound nor represent what a `prune -f` will delete. These deletions also never pass `SafetyChecker` (paths like `/var/lib/docker/...` are not real local files).

**Mitigation in place:** GUI path (`DevToolsView`) shows a `.confirmationDialog` before cleaning.
**Fix direction:** enumerate concrete prune targets (`docker … ls` → specific ids) and remove by id, or at minimum surface `docker system df` and a real preview; stop reporting `item.size` as "freed" in dry-run.

## 6. MEDIUM — App-bundle removal also skips SafetyChecker

**File:** `MacSweep/Sources/Core/Scanning/Modules/AppUninstallerModule.swift:335-342`

Same class as #1 but for the `.app` bundle itself: trashed via `FileManager.trashItem` with no `SafetyChecker` gate. Lower severity because the target is a user-chosen app the user explicitly asked to uninstall (intent is clear) and removal is recoverable, but it should still pass `validateForTrash` so a symlinked / relocated `.app` path can't redirect the removal.

## 7. MEDIUM — SystemCache recursively permanent-deletes child subtrees without validating descendants

**File:** `MacSweep/Sources/Core/Scanning/Modules/SystemCacheModule.swift:239-255`

For a directory target, `clean()` validates `item.path` (`:231`) and each **immediate** child (`:251`), then calls `CleanupFileRemover.permanent(content)` (`:254`) — a recursive `removeItem` — on each child. Grandchildren and deeper descendants are **not** re-validated. Also, the module's own richer protected list (`protectedSubdirectories` at `:19-30`: `CloudKit`, `com.apple.bird`, `com.apple.nsurlsessiond`, …) and `isProtected()` (`:189-214`) are used only at scan time; the clean path relies solely on `SafetyChecker`, which treats anything under `~/Library/Caches` as safe and does not know those module-specific names. Deletion is **permanent**, not Trash.

**Scenario:** between scan and clean, an app writes a new protected-by-module-policy subdir (or a symlink) two levels below a validated cache dir; it is permanently removed because only the top level and its direct children are checked. Narrow (TOCTOU-ish) but the blast is permanent and the module's own protection list is silently not enforced at delete time.

**Fix direction:** either delete the validated child with a validated recursive walk, or consult `isProtected()` per descendant, and document why module-policy names aren't in `SafetyChecker`.

## 8. LOW — Dev-artifact deletion has no active-project/git gate

**File:** `MacSweep/Sources/Core/Scanning/Modules/DevToolsModule.swift:54-166`

`node_modules`, `.build`, `target`, `dist`, etc. are removed with no check for an active/dirty project. Rated **low**: removal is to Trash (`:128`, recoverable) and these are regenerable (`npm install`, rebuild). Real cost is time, not data — but a build in progress could be corrupted mid-run. Worth a "project looks active (lockfile newer than N days)" skip.

## 9. LOW — `SSHKnownHostsManager.removeHost` unlocked read-modify-write

**File:** `MacSweep/Sources/Core/Scanning/Modules/NetworkModule.swift:340-351`

Removing a host entry reads the whole `~/.ssh/known_hosts`, filters, and rewrites — no file lock. A concurrent `ssh` TOFU append racing the rewrite can be lost. Low impact (host key re-prompted on next connect), but it mutates a security-relevant file non-atomically.

---

## What held up (explicitly cleared on hand-review)

- **Symlink-in-Trash / link-swap tricks** — defeated: `realParentPath` resolves parent symlinks before every protection decision, and Darwin `removeItem`/`trashItem` don't follow a final-component link.
- **Background scheduler auto-cleaning** — false alarm: `ScanScheduler.runBackgroundScan` (`ScanScheduler.swift:60-84`) only ever calls `engine.scan()` (read-only) + notify; it never cleans.
- **CLI `--yes` defaults** — clean: every destructive subcommand defaults the confirm bool to false and gates on a TTY confirm in `CLIExecutor` (`selfUpdate` is the one documented `--yes`-only exception).
- **PackageManager / Browser / Privacy / TrashBins / MailAttachments / Duplicate / SimilarPhotos / CloudCleanup modules** — all re-validate via `SafetyChecker` before `trashItem`/`permanent`, or use recoverable Trash for regret-prone items, matching the documented `CleanupFileRemover` policy.

## Recommended fix ordering

1. #3 (dead threshold) and #2 (dashboard dialog) — small, high-value, no behavior risk.
2. #1 + #6 — add `validateForTrash` to the uninstaller path; tighten leftover matching.
3. #4 — `--ignored` check before worktree removal (prevents permanent secret/db loss).
4. #7 — recursive validation in SystemCache; #5 — real Docker preview; #8/#9 — hardening.

Add regression tests alongside each: the suite already has `SafetyCheckerTests`, `DeletionGuardTests`, `ScanEngineTests`, `GitArtifactScannerTests` to extend — notably a `DeletionGuard` test asserting `.requiresConfirmation` is actually acted on, and a `GitArtifactCleaner` test with a gitignored file present.
