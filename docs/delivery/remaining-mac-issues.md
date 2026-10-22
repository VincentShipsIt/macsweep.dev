# Remaining Mac backlog delivery

Started 2026-10-22. iOS epic #26 is explicitly deferred by the user and stays open.
The active scope is fourteen Mac issues. This file records the delivery sequence;
GitHub issues and linked PR receipts hold current completion evidence.

A unit is complete only when its entire acceptance contract works, focused checks
and required current-head CI pass, its PR is merged, and any required real-product
acceptance is recorded. An unsupported capability stays explicit and retained;
fixture output cannot stand in for a real mutation or clean-machine acceptance.

| Order | Issues | Outcome and gate |
| --- | --- | --- |
| 1 | #120, #121, #42 | Package-test actual app scan/cleanup and background/notification coordination; complete everyday cleanup evidence states; close audit tracker only when #120 is delivered. |
| 2 | #165 | Xcode inventory and protected native/file cleanup across all six categories. |
| 3 | #166 | Toolchain inventory, reference evidence and guarded native uninstall. |
| 4 | #169 | Environment Doctor with exact orphan/symlink evidence and report-only PATH advice. |
| 5 | #167 | Local snapshot inventory and explicitly confirmed native thinning/removal with observed volume accounting. |
| 6 | #170 | VM/container inventory with persistent-state and active/protected safeguards. |
| 7 | #171 | Evidence-backed orphan leftovers with shared-owner retention. |
| 8 | #172 | Exact IDE/editor cache evidence and active/current-version retention. |
| 9 | #168 | Project/source/artifact inventory, independent safe sweep and verified archive workflow. |
| 10 | #164 | Incremental, globally bounded developer disk map and low-impact known-root inventory. |
| 11 | #173 | Unified detected-source outdated inventory, exact streamed native updates and per-item results. |
| 12 | #48 | Current-release metadata/scope and genuinely fresh cask-install/interactive-launch acceptance. |

The implementation uses existing shared safety, bounded ProcessRunner,
DeletionGuard, recovery accounting and review confirmation contracts. New
inventory domains expose typed states and evidence. Selection never authorizes a
stale target without cleanup-time revalidation. Native-manager failures never
fall back to whole-directory deletion.

Parallel implementation is confined to separately claimed directory trees and
worktrees. The parent owns shared navigation/registry integration and inspects the
actual diffs and artifacts. Separate model review is not requested.

Each unit runs focused behavior tests, applicable strict lint and real UI/native
acceptance. Shared safety changes additionally run all coverage floors. Release
CLI/GUI, signature/launch, E2E and visual snapshots are required for affected
product surfaces. CI proves compatibility with its installed Swift toolchain.
Reversible implementation continues while external acceptance blockers or
consequential product questions are resolved.
