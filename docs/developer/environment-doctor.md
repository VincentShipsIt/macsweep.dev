# Environment Doctor

Run Checks inspects user/system launch items, supported bin links, the configured
login shell's effective PATH and Homebrew doctor. `macsweep doctor --format json`
exposes the same read-only diagnostics. Coverage failures return a nonzero status.

Only a verifiably missing absolute executable makes a launch plist an orphan.
Relative commands, unreadable paths and link loops are not guessed. Broken-link
repair moves the link itself. PATH and Homebrew findings are copyable suggestions;
MacSweep never edits shell configuration or applies brew-doctor advice.

Repairs use the shared review. Fresh protection rules, file identity,
program/link evidence, supported roots and privileges are rechecked before each
operation. The whole selection passes the size cap before any move. Restored
tools and changed links are retained. Loaded launch jobs are not stopped.

System repairs require administrator acknowledgement before review. A finite
action builder admits only supported launch/bin locations and simple filenames.
The root program rechecks identity, hashes plist content, rechecks the missing
program or broken link, pins the user's real Trash as its working directory
and uses a unique destination without overwriting anything. Privileged Trash
entries have a suffix and require administrator access for restoration to the
original location. Unsupported system repairs remain manual.

The administrator bridge preserves the existing process-group supervisor and
constant-script API. Finite actions pass independently quoted data. Pinned
output descriptors and a reader handshake permit live output while the delivery
directory remains root-owned. Output is bounded and native exit status remains
distinct from authorization success. Explicitly reviewed App Store updates use
the same bridge; no installation is performed during verification.

Trash sizes are target estimates and do not imply additional free space.
Unavailable size estimates are explicit in the shared result; observed volume
changes are reported independently and include other activity.

Verification (local) uses fixtures for clean/dirty environments, protection
changes, restored executables, aggregate caps, read-only CLI parsing and actual
supervised streaming without elevation or user-data removal.
