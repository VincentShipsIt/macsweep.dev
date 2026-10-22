# Stale project review

`StaleProjectsView()` is a standalone, manual-only screen. It never contributes source checkouts to Smart Care. It lists repositories from user-chosen roots, sorts by verified artifact estimate, total estimate, last activity or name, and shows source/retained data separately from verified generated artifacts. The default stale threshold is six months, with three- and twelve-month choices. The threshold labels inventory; it never grants cleanup permission.

Home discovery includes `.codex/worktrees`, `.claude/worktrees`, `.agents/worktrees`, `.grok/worktrees`, `.t3/worktrees` and `worktrees`. Explicit custom roots retain their scope. `DeveloperRepositoryDiscovery` supplies the same bounded walker used by Git and developer artifact scans. Its entry, depth, time, unreadable-path and protection issues are visible; findings collected before a limit survive. The old independent `ProjectScanner` walker is removed: project grouping consumes production artifact receipts.

## Artifact sweep

The screen uses `DevToolsModule` and `ScanEngine`, including their shared Git/content identity receipts, protected-path rules, aggregate deletion guard and current-job/shared-dependency checks. Each selected artifact receives a fresh assessment and final content validation. A recent or dirty project does not add an age/dirty veto to an independently eligible artifact; the shared gate must still prove the artifact safe. Source, TypeScript configuration, lockfiles, captures and conversation data never become caches because of a directory name.

All selected artifacts go through one engine invocation, so the aggregate cap applies before any dispatch. The artifact inspection phase also has count and time limits and retains partial results with diagnostics. Cleanup uses recoverable Trash only. The source checkout remains in place.

## Archive and optional checkout Trash

Archive creation requires an explicitly selected, new ZIP destination outside the checkout. Existing files and dangling destination links are refused. Native argv-only commands create a ZIP with `ditto -c -k --sequesterRsrc --rsrc --extattr --acl --qtn --keepParent`, test it using `unzip -tqq`, then extract it with `ditto -x -k` into a private verification directory. Every command runs through `ProcessRunner` with a 300-second bound; there is no shell, privilege prompt, unlock prompt or source deletion command.

The full source manifest includes ignored and untracked files, Git metadata, regular-file SHA-256 hashes, literal symlink destinations, modes, ownership, flags, extended attributes/resource forks and ACLs. File hashing uses no-follow descriptors in 64 KiB chunks. Inspection defaults to 100,000 entries and 30 seconds per manifest; xattr/ACL reads have explicit size limits. Unsupported nodes, hardlinked regular files, unreadable metadata, protection rules, archive failure or any changed source manifest stop publication. Copy verification compares complete relative paths, contents and permission metadata. ZIP timestamps may have different precision; the original checkout's complete modification/change stamps must remain unchanged. The original manifest is revalidated before extraction and again before publication. The ZIP must be nonempty and pass actual extraction/content comparison before atomic no-replacement publication.

Archiving does not move the source. A separate shared cleanup review offers checkout Trash only when all of these facts can be proven again:

- The verified ZIP still has its exact identity, stamp and SHA-256 digest.
- The complete original manifest still matches, including all ignored/untracked content.
- Git has a readable HEAD commit, is clean, and no commit reachable from local refs/HEAD is missing from local remote-tracking refs.
- A remote is configured, all Git metadata is inside this checkout, and there are no other linked worktrees or nested repositories.
- Current-user activity and shared-dependency inspection is complete and finds no relevant job.
- Fresh user protections, the explicit `SafetyChecker.validateForTrash` gate and the aggregate cap permit the target.

The final synchronous boundary rechecks every vnode/change stamp and the archive seal after the fresh process snapshot, then calls the existing recoverable Trash remover. Cancellation is bridged into utility-queue hashing and checked again before publication or Trash. Final mutations use `DevArtifactIO.commit`, which preserves a completed receipt if cancellation arrives after the mutation succeeds. No `git worktree remove --force`, permanent checkout removal, broad process kill or automatic job stop exists.

Remote coverage uses already-present remote-tracking refs; it does not fetch or claim that a remote server is a complete backup. A linked checkout can be archived as checkout contents, but external shared Git metadata is outside that ZIP and checkout Trash stays unavailable. Dirty/unpushed checkouts may be archived while their Trash action remains locked. Unknown Git/process/content coverage always retains the source.

## Records and accounting

A bounded local history records `artifactSweep`, `archive` and `checkoutTrash` separately. Archive records contain copied ZIP bytes and never claim reclaimed space. Artifact and checkout Trash records have distinct target estimates. Service results report zero freed-byte credit; shared accounting can separately describe bytes moved to Trash and observed volume changes. External checkout removal or unrelated disk activity is not credited to an artifact sweep. Trash does not immediately release space.

## Verification

Fixture Git repositories cover ecosystem grouping, ignored source, configuration/lock/capture/conversation preservation, partial discovery, aggregate refusal, active/shared jobs, unknown activity, dirty/unpushed Git, linked worktrees, fresh protections, changed source/archive and cancellation. ZIP tests perform real native archive/test/extract round trips on disposable fixtures, including an extended attribute. Failure paths retain original source. Successful Trash authorization uses an injected fixture ledger; no user checkout is archived, deleted or moved during verification.

Primary command evidence: installed `ditto -h`, `man ditto`, `unzip -h`, `man acl_get_file`; [Git status](https://git-scm.com/docs/git-status), [revision traversal](https://git-scm.com/docs/git-rev-list), [reflog](https://git-scm.com/docs/git-reflog) and [worktree documentation](https://git-scm.com/docs/git-worktree). Git queries disable optional locks, fsmonitor, untracked-cache writes and hooks; bounded output pipelines refuse incomplete or undecodable evidence.
