# Developer Disk Map

`DeveloperDiskMapView(onOpenOwner:)` is an inventory page. Its typed `DiskMapOwner`
callback opens the dedicated module's inspection/review page; it grants no deletion
permission. The map has no selection for cleanup, Trash, shell cleanup, Smart Care,
or automatic cleanup action. Known protected roots can be inspected in their owner;
unknown paths, repository source, and swap have no owner action. Finder reveal and
read-only details remain available.

## Scope and progress

Opening the page checks known package/editor caches, version-manager installations,
Xcode installations/data, simulators, persistent VM/container data, then bounded
repository discovery in common developer and agent worktree directories. Roots are
published incrementally. `Measure Home…` explicitly adds bounded home discovery and
other home-file measurements. No full-volume scan, administrator request, or unlock
prompt is used. Services accept explicit roots for configured scans and fixtures.

Repository discovery reuses `DeveloperRepositoryDiscovery`: Git internals and
nested dependency trees are pruned during discovery. Measurement makes one streaming
pass over each disjoint root, splitting nested generated directories (`node_modules`,
`.build`, `dist`, `target`, `build`, DerivedData, Pods, virtual environments, Next/Nuxt)
from source and repository metadata. Classification does not imply disposability.

A walk defaults to 150,000 entries, four seconds and 96 levels per root; a scan
defaults to 25 seconds plus at most one five-second discovery chunk, with at most
128 measured roots. UI detail is
bounded to four levels and 1,200 explicit nodes per root, with aggregate remainder
blocks preserving totals. Budget/permission/protection gaps retain measurements as
lower bounds or unknown sizes. An unknown size is never displayed as a complete zero.
Cancellation retains previously published root chunks. Scan / Resume reuses recent
chunks, including clearly marked partial chunks, so one very large root cannot
starve later roots. Refresh discards that evidence and remeasures.

## Storage accounting and protections

Logical bytes are file lengths; allocated estimates use `st_blocks * 512`. Directory
metadata allocation is omitted. Overlapping root paths are excluded by component
boundaries. Hard links are counted once across all roots using device/inode identity.
APFS clone/snapshot sharing and exclusive reclaimability are unknown: neither size is
advertised as recovered or recoverable disk space. Persistent VM/container data is a
separate category from caches; system swap is a separate block without an action.

Measurements use `lstat` and no-follow directory opens. Arbitrary symlink roots and
symlink files are retained as unknown, and their targets are not followed. Only the
fixed macOS `/var`, `/tmp` and `/etc` aliases to their `/private` counterparts are
normalized. Sensitive names and current user ignore/protect rules stop traversal;
protected blocks remain visible. Broad home traversal also stops at critical protected
subtrees. Explicit known roots may be measured read-only while retaining their built-in
protection labels and routing inspection through the owning module.

## Low-impact I/O and caching

Filesystem walks run through the shared `DevArtifactIO` utility-priority budget,
which has two asynchronous permits. It shares those permits with Space Lens and
other migrated developer scans, forwards queued and active cancellation, and carries
scan diagnostics. A measurement holds one permit and creates no per-directory task
fan-out. No permit is held while awaiting a child scan.

A five-minute cache retains at most two scope entries. Optional home scans reuse
recent known-root measurements rather than walking them again. Cache scope includes
root configuration and current protection rules, including collapsed descendants.
Refresh invalidates reuse. Cached evidence is labeled as recent rather than live;
modification time is not claimed to prove every descendant unchanged.

The optional index contains metadata only and is capped at 256 KiB and 128 root
records. It is not written with unknown or less than 1 GiB available space, incomplete
coverage, cancellation, or scan issues. Reads are bounded and index paths refuse
symlinks. Oversized scans continue in memory. Verification can inject an in-memory
cache and suppress all index writes.

## Verification

Fixtures cover source/artifact partitions, explicit known-root progress, optional
home overlap exclusion, hard links, permission failures, protected and symlink paths,
entry/depth/time budgets, cached reopening, protection-rule changes, cancellation and
resume, index size limits, critical free space and index symlink tampering. Shared I/O
tests exercise mixed synchronous/asynchronous concurrency, queued/active cancellation,
errors, reentry and diagnostic propagation. Native acceptance compiles the actual
GUI sources and renders a populated page; production verification is read-only.
