# Toolchain review

Toolchains is a manual Developer Tools page. It does not implement a `ScanModule`,
and its typed uninstall actions never enter Smart Care or generic filesystem
cleanup. `ToolchainsView()` owns the review UI; `ToolchainService` owns inventory,
protection evidence and native dispatch.

The inventory recognizes nvm, pyenv, rbenv, asdf, mise, rustup and user/system JDK
bundles. Environment-selected manager data roots are honored. Missing managers
and empty install roots produce no empty groups or process-inspection errors.
JDK bundles remain inventory only: MacSweep does not invent a native owner or
replace uninstall with a directory deletion.

A version is active when a global selection, repository version file, linked
virtual environment, linked runtime dependency, or running job references it.
Active versions cannot be selected. A version is stale only when all protection
evidence is complete and its newest executable-access/file-modification signal
is older than the configured threshold. The default is six calendar months;
the review page offers three, six and twelve months. These timestamps are
activity signals, not a reliable record of last use. Unknown, recent,
unsupported, unreadable or replaced versions remain locked.

Repository references are collected from the developer scan roots, including
hidden version files and managed worktrees. Git metadata, Library, Trash,
caches and installed runtimes are excluded from ordinary reference parsing;
installed runtimes receive a separate linked-dependency inspection. Inspection
is bounded and cancellation-aware. Exhausted budgets, unreadable configuration,
unsupported aliases/TOML shapes, external dependencies and incomplete process
evidence retain versions. Projects outside the displayed reference scope require
manual review. No project configuration, shell profile or startup file is run.

## Native commands

Exact executable paths, environment assignments and argument vectors appear in
the review sheet. Commands run from the filesystem root with bounded timeouts.
The destructive command receives a clean environment and an explicit data root.

- nvm: a fixed Bash launcher sources only the installation's `nvm.sh` with
  `--no-use`, then calls `nvm uninstall` with the validated version supplied as
  a positional argument. `env -i`, `--noprofile` and `--norc` exclude inherited
  shell hooks and startup files. Alias references are retained conservatively.
- pyenv/rbenv: `uninstall -f VERSION`, after installed help confirms the native
  uninstall capability. rbenv without ruby-build's uninstall remains locked.
- asdf: `uninstall TOOL VERSION`; identifiers are single validated argv values.
- rustup: `toolchain uninstall TOOLCHAIN`; global defaults, directory overrides
  and repository toolchain files are protected.
- mise: `--no-config --no-env --no-hooks uninstall TOOL@VERSION`. The installed
  help must advertise all three isolation flags. Unsupported installations,
  dynamic aliases and configuration overlays remain locked.
- JDK bundles: no uninstall action.

Immediately before each dispatch, the service rescans inventory, global
selection, references, linked dependencies and processes. Runtime and parent
inode/device/type, manager executable identity/content stamps, complete runtime
content stamps, native argv and eligibility must still match the preview.
Explicit permanent-removal SafetyChecker vetoes and sensitive-content checks
apply within the recognized runtime; user protection rules remain effective.
DeletionGuard checks aggregate selected impact before any uninstall and checks
cumulative live impact before each command. Commands never escalate privilege,
edit shell configuration, kill existing jobs or fall back to raw deletion.

Native uninstall is permanent and removes global packages installed inside the
selected runtime. A failed command can have partial effects; errors remain
visible and inventory is refreshed. Success requires both exit zero and the
runtime's absence. Native managers may share files or remove other metadata, so
result accounting reports completed version count and zero credited bytes
rather than inventing savings from the preview estimate.

## Verification

Fixture tests cover reference parsers and discovery for every manager, global
and repository selection, aliases, virtual environments, linked runtimes,
unknown activity, unsupported capabilities, changed content/executables,
aggregate caps, failed commands, retained targets and partial outcomes. They
use UUID-scoped owned fixtures and fake manager dispatch; no real runtime is
uninstalled. Verification (local) also compiles the complete macOS app and
performs a read-only actual inventory.

Command semantics were checked against primary documentation and installed
read-only help:

- [nvm](https://github.com/nvm-sh/nvm#usage)
- [pyenv commands](https://github.com/pyenv/pyenv/blob/master/COMMANDS.md)
- [rbenv and ruby-build uninstall](https://github.com/rbenv/rbenv)
- [asdf version management](https://asdf-vm.com/manage/versions.html)
- [mise uninstall](https://mise.jdx.dev/cli/uninstall.html) and
  [configuration isolation flags](https://mise.jdx.dev/cli/)
- [rustup toolchains](https://rust-lang.github.io/rustup/concepts/toolchains.html)
  and [overrides](https://rust-lang.github.io/rustup/overrides.html)
