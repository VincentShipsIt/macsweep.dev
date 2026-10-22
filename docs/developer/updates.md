# Unified Updates

`UpdatesView(administratorUpdate:)` presents manual checks for Homebrew formulae,
Homebrew casks, Mac App Store apps (`mas`), npm/pnpm global packages, pipx apps
and RubyGems. The parent navigation replaces the old Homebrew-only entry.
There is no background polling or automatic installation.

`UpdateScanner` owns detection and source parsing. Missing tools produce install
hints. A failed or unsupported check produces a source diagnostic; it never
means that the source is up to date. Every reported package carries current and
latest versions, native argv, executable identity/content stamps, install roots,
and an explicit eligibility reason. Permission inspection failures preserve
rows for manual action. Pinned Homebrew formulae and pipx apps stay visible and
locked.

## Checks and commands

- Homebrew uses `outdated --json=v2`, with formulae/casks grouped separately.
  Formula upgrades use `upgrade --formula NAME`; casks use `upgrade --cask NAME`.
  The installed Homebrew implementation must support `HOMEBREW_NO_SUDO`.
  Update children receive `NONINTERACTIVE=1`, `HOMEBREW_NO_SUDO=1`,
  `HOMEBREW_NO_ASK=1`, `HOMEBREW_NO_AUTO_UPDATE=1`,
  `HOMEBREW_NO_INSTALL_CLEANUP=1` and
  `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1`. Installer/package/script casks
  require manual review rather than surprising the user with elevation.
- `mas outdated` uses its ordinary mode, which avoids the authentication dialogs
  associated with `--accurate`. Reviewed updates use `mas upgrade ADAM_ID`.
  IDs are positive `UInt64` values. No names, shell fragments or bundle paths
  become administrator arguments.
- npm uses `outdated --global --json`; pnpm uses
  `outdated --global --format json`. npm's normal exit 1 for available updates
  is accepted only with valid structured output. Updates install the exact
  reviewed version with native global install/add, with lifecycle scripts
  disabled. The process PATH includes the manager's directory, inherited tool
  paths and configured/default pnpm global bin directories without editing shell
  configuration.
- pipx release capabilities differ. The stable fallback reads `list --json`,
  then runs `runpip ENV list --outdated --format=json` and filters to each
  environment's primary application. Dependency-only updates are not presented
  as app upgrades. A failed/unsupported probe is an honest source failure.
  Native `upgrade ENV` receives `--pip-args=--no-input --only-binary=:all:`;
  packages requiring source builds can fail and remain available for manual
  work. Pinned environments are inspected but cannot be upgraded here.
- RubyGems uses `outdated --norc`, then `update NAME --no-document --norc` in
  its existing install location. System or unwritable gem roots remain locked;
  MacSweep does not silently switch to another Ruby or install duplicate user
  copies. Native extensions may build as the current user.

Checks and native updates use bounded, cancellation-aware `ProcessRunner`
operations from the filesystem root. No project scripts or shell startup files
are sourced by the wrapper. Review names each exact command and explains the
applicable script and privilege behavior. Homebrew/pipx/RubyGems commands retain
their native latest-version semantics; the advertised versions are rechecked
before execution, but the registry can change subsequently.

## Administrator boundary

The view accepts the optional `MasAdministratorUpdate` closure. Without a
supported administrator bridge, App Store rows show an actionable instruction to
sign in and update using the App Store. With the bridge, the review sheet
requires both an acknowledgement of the upcoming macOS administrator prompt and
an acknowledgement that the required Apple Account is signed in. Missing either
blocks the entire requested batch before dispatch.

App Store updates run before ordinary updates so the disclosed authorization
flow occurs first. The callback receives `MasUpdateRequest` containing the known
executable path, integer App Store ID, and executable identity/content stamps.
The shared integrator supplies the dedicated typed
`PrivilegedRunner.updateMacStoreApp` API. The pre-existing constant-only
`runShellScriptAsAdmin` contract is not weakened. The privileged implementation
validates its own executable/ID boundary, supervises root lifetime and streams
output. Sign-in remains the App Store's responsibility; MacSweep never collects
Apple Account or administrator passwords.

## Execution and results

The executor refreshes selected sources before dispatch. A changed version,
manager, manager content stamp or install-root identity requires a new review.
Writable locations and executable metadata are checked again immediately before
each command. Identifier/version validation prevents option, path and shell
injection. Empty selections never turn into native "upgrade everything" calls.

Commands run per item. Native exit status determines each item's outcome;
failures do not abort other selected items. An explicit cancellation stops the
remaining batch. The UI streams stdout and stderr with incremental UTF-8
decoding, flushes incomplete final sequences, and retains a bounded log tail.
It refreshes inventory after the batch while preserving results. Successful
status says that the native command completed; it does not invent a byte-saving
metric or claim an unverified installed version.

## Verification

Fixture tests cover every parser, source grouping, missing-tool hints,
unsupported pipx probes, pinned applications, cask installer privileges, no-sudo
capabilities, permission failures, changed versions/executables/root identities,
unsafe identifiers, independent item failures, streaming output, and both App
Store acknowledgements. The fake native dispatch never upgrades real packages.
Verification (local) also builds the complete macOS app and performs actual
read-only source checks; real upgrades require interactive review.

Primary command references:

- [Homebrew commands and environment](https://docs.brew.sh/Manpage)
- [mas commands, root privileges and accounts](https://github.com/mas-cli/mas)
- [npm outdated](https://docs.npmjs.com/cli/commands/npm-outdated) and
  [install configuration](https://docs.npmjs.com/cli/using-npm/config/)
- [pnpm outdated](https://pnpm.io/cli/outdated) and
  [global add](https://pnpm.io/cli/add)
- [pipx command reference](https://pipx.pypa.io/stable/reference/cli/)
- [RubyGems command reference](https://guides.rubygems.org/command-reference/)
