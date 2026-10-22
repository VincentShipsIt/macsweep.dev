# Local Time Machine snapshots

`LocalSnapshotsView()` is a standalone, manual-review page. It is not a Smart Care module. It lists startup-volume local Time Machine restore points, their native date tokens and dataless status, and explicitly labels their sizes unavailable. An empty, verified listing explains when local snapshots may not exist. Incomplete native output, unknown records, duplicate identifiers and invalid calendar dates disable thinning.

macOS normally removes local snapshots as they age or when storage is needed. These restore points can recover earlier file versions without a backup disk. Removing them reduces local recovery options and cannot be undone. Backup destinations, schedules, remote backups and Time Machine enablement are not changed.

## Supported operation and privilege boundary

The feature offers only three finite, reviewed choices on startup volume `/`:

- `/usr/bin/tmutil thinlocalsnapshots / 1073741824 1`
- `/usr/bin/tmutil thinlocalsnapshots / 5368709120 1`
- `/usr/bin/tmutil thinlocalsnapshots / 10737418240 1`

These are best-effort requests for 1, 5 or 10 GiB at urgency 1. Time Machine chooses the local snapshots to thin; the request is not an upper bound on the extent of restore points removed. A newly created snapshot may be included while authorization is pending. The configured deletion cap is refreshed and applies to the request goal. A complete fresh snapshot set, startup APFS volume identity, permission state and inactive backup status must match the reviewed inventory before authorization starts.

The upfront page and shared cleanup review disclose that MacSweep requires administrator authorization for this operation, and require Full Disk Access first. The installed `tmutil` manual says some verbs require root and Full Disk Access; it does not independently guarantee an unprivileged thinning mode on every host. MacSweep deliberately uses its existing `PrivilegedRunner` policy rather than probing by mutation. Its contract remains unchanged: the administrator script consists exclusively of constant strings from a closed enum, never scanned text. A fixed root-side activity guard rechecks `tmutil status` after authorization; running, failed or unknown backup status prevents the thinning command.

Exact-date deletion is intentionally omitted. The installed `tmutil` manual states that `deletelocalsnapshots <date>` deletes that date across **all mounted disks**. Fixed, root-volume thinning satisfies the issue's delete-and/or-thin proposal while preserving the trusted-script boundary and narrower disk scope. No filesystem fallback or dynamic privileged shell interpolation exists.

User rules are reloaded before the operation. Protecting or ignoring `/`, `/System/Volumes/Data`, `/Volumes/com.apple.TimeMachine.localsnapshots`, or an exact logical snapshot path `/Volumes/com.apple.TimeMachine.localsnapshots/YYYY-MM-DD-HHMMSS` blocks thinning. Rule-load failures also block the operation. This is volume/snapshot intent protection; it does not claim to inspect historical files inside APFS snapshots.

## Storage accounting

Available capacity comes from Foundation's ordinary available-volume metric. Additional reclaimable capacity is an estimate calculated from the capacity for important usage minus ordinary available capacity, only when both metrics are present and ordered consistently. It includes every source macOS considers reclaimable; it is not total Time Machine snapshot size. Missing values remain unavailable.

Receipts include before/after available-space observations on the same volume and before/after reclaimable estimates when available. Observed missing snapshot IDs are reported independently of successful native command completion. All observations may include concurrent macOS or application activity; causal snapshot-reclaimed bytes remain unknown. `CleanupAccounting` carries the observations separately from processed-byte estimates. A native command failure, declined authorization or unverifiable after-state produces a factual failure receipt, with no claimed removed IDs or attributable bytes.

Verification (local) uses injected native outputs, administrator dispatch, permission state, policy and capacity samples. Owned fixtures cover valid/dataless/empty/unknown listings, calendar and injection rejection, finite scripts, fresh snapshot/volume changes, active backup and authorization blockers, fresh user rules, request caps, declined authorization, partial verification and noncausal accounting. Real native checks are read-only; no snapshot is thinned or deleted during verification.

Sources: [Apple's local snapshot explanation](https://support.apple.com/en-ie/102154), [Foundation volume capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity), and installed `tmutil help`/`man tmutil` for listing, thinning and date-deletion scope.
