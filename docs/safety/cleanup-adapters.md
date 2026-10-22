# Package caches, gcloud logs and live Brave workers

Verified 2026-10-22. Tracks #309, #310 and #311.

## Package cache actions

Package Managers is the cleanup owner for its explicit cache roots, including
`~/.cache/uv`. System Caches and AI Analysis cannot remove overlapping package
cache paths. Installed runtimes, global packages and tool installation roots are
outside the inventory.

Each finding captures owner UID, bounded size, modification time, target/parent
identity, content stamps and active-job evidence. Cleanup checks these again,
including after manager capability probes. Symlink roots/ancestors, external
cache links, protected descendants, special files, held advisory/record locks,
unknown process evidence and retained-job dependency references block cleanup.
The activity panel offers only the existing narrowly verified developer-job stop;
stopping is separately confirmed and followed by rescanning. Unknown jobs must
be stopped in their owning application. Cleanup never kills arbitrary managers.

| Cache | Action | Recovery and regeneration |
| --- | --- | --- |
| UV | `uv cache prune --cache-dir <reviewed-root> --no-config --offline` | Permanent native prune. No Trash recovery. Downloads/builds may recur. |
| Bun with verified prune capability | `bun pm cache prune --max-age 30 --cache-dir <reviewed-root>` | Permanent removal of old packages; shared `links/` store, Git clones and manifests retained by documented prune semantics. |
| Bun without that capability | Skip | No whole-directory fallback or full cache clear. |
| Other explicit package cache roots | Move reviewed directory to Trash after revalidation | Restore until Trash is emptied; caches may be recreated. |

UV prune can remove centralized cached environments. MacSweep retains the whole
cache when it contains an `environments-*` bucket or an installed UV tool links
into it. Active executables, open files, manager jobs and shared dependency links
also retain the cache. No `--force`, `--ci`, clean-all fallback or runtime pruning
is used. Custom cache locations are not inferred from project configuration.

The native command is fixed argv with an explicit cache path, executed outside
projects through ProcessRunner with a 15-second lifecycle bound. Cancellation
terminates only that invocation's isolated child group. A timeout, cancellation
or nonzero result may have changed some entries; the error requests a rescan and
credits zero processed bytes. Successful prune records tool cleanup and zero
estimated bytes freed because the whole cache inventory is only an upper bound.
Volume observations remain distinct from these estimates.

Verification (local): official UV 0.13.5 successfully pruned an owned orphan
through the actual module. Installed Bun 1.4.2 and official Bun 1.4.3 did not
advertise `bun pm cache prune`; both are retained by the capability gate. Current
Bun documentation describes prune, so the adapter requires both the stable
version check and explicit installed CLI help support. A version number alone
never enables it. Fixture coverage exercises the supported-command branch.

Primary references:
[UV caching and locks](https://docs.astral.sh/uv/concepts/cache/),
[UV command reference](https://docs.astral.sh/uv/reference/cli/#uv-cache-prune),
[Bun cache operations](https://bun.sh/docs/pm/cli/pm#cache).

## gcloud log retention

The Developer Tools package page and `developer-cli-logs` CLI module share one
adapter. It visits only `.config/gcloud/logs/YYYY.MM.DD/HH.MM.SS.<digits>.log`
beneath the user's home. No arbitrary `logs` directory, gcloud credential store,
account database, named configuration or sibling user file is traversed.
Only owned regular files with a single hard link are inventoried. Symlink day
folders/files are skipped; symlink roots/ancestors fail closed. Sensitive-file
and user protection rules remain in force.

Default retention keeps logs at or newer than the 30-day cutoff, plus at least
256 MiB of the newest logs. A boundary file is kept whole. The GUI can choose
90 days or 1 GiB; changing policy clears the previous selection and requires a
new scan. CLI uses the displayed default policy. Old files are reviewed
individually with owner, exact path, size, mtime, policy and writer/retention
reason. Recent files and active or uninspectable writers are retained.

Cleanup recomputes retention against the complete inventory and revalidates
identity, owner, content stamps, locks and activity immediately before moving
each selected file to Trash. Partial failures credit only completed files.
Trash remains recoverable until emptied; a Trash move is not a promise of
immediate recovered disk capacity.

## Brave capability result

The requested combination is **unsupported for an already-running ordinary Brave
profile without prior debugging setup**: remove worker registrations and worker
caches across its profiles, preserve authentication/session stores, leave the
browser open, and avoid a relaunch. MacSweep has no supported attachment channel
for that combination. It reports this limitation and skips the live targets.
The existing integrity guard remains enforced. MacSweep does not enable remote
debugging, attach to a user's debugging endpoint, restart Brave, or delete live
profile files. Offline cache/worker cleanup remains available after the user
quits Brave and rescans.

These browser-owned operations are distinct:

| Operation | Protocol behavior |
| --- | --- |
| `ServiceWorker.unregister(scopeURL)` | Removes a registration for one known scope; does not evict its Cache Storage. |
| `CacheStorage.requestCacheNames` then `deleteCache(cacheId)` | Evicts named Cache Storage for an explicitly known origin; does not unregister workers. |
| `Network.clearBrowserCache` | Clears HTTP cache; distinct from worker Cache Storage and cookies. |
| General site-data deletion | Can remove authentication stores; excluded from this investigation and product path. |

Verification (local): `node scripts/verify-brave-worker-cleanup.mjs` launched
Brave with a new disposable profile and a local fixture server. Chromium
155.0.8059.80 / protocol 1.3 accepted the three selective operations. Assertions
proved registration removal, separate worker-cache eviction, preserved cookie,
Local Storage, Session Storage and IndexedDB sentinels, a successful authenticated
fixture request, and a browser process that stayed alive throughout the checks.
Only the owned probe process was terminated during teardown. The profile was
removed afterwards. The probe never accesses a real user profile or session.

This proves selective protocol semantics for that fixture, not preservation of
every real site's login: a site may itself store required session data in worker
caches. No live product path is enabled on the strength of a fixture alone.
Tests also prove that the running-browser guard prevents filesystem mutation and
that offline worker/cache cleanup preserves neighboring session-store fixtures.

Primary references:
[ServiceWorker protocol](https://chromedevtools.github.io/devtools-protocol/tot/ServiceWorker/),
[CacheStorage protocol](https://chromedevtools.github.io/devtools-protocol/tot/CacheStorage/),
[Network cache protocol](https://chromedevtools.github.io/devtools-protocol/tot/Network/#method-clearBrowserCache),
[Chrome debugging attachment restrictions](https://developer.chrome.com/blog/remote-debugging-port).
The Chrome attachment restriction is evidence about Chrome, not an assertion
that Brave implements an identical restriction.
