# Changelog

All notable changes to MacSweep are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The user-facing product name and installed app bundle are consistently
  **MacSweep** and `MacSweep.app`. The production bundle identifiers remain
  unchanged so macOS privacy permissions and defaults identity stay stable:
  `dev.macsweep.app` (app), `dev.macsweep.core` (framework), `dev.macsweep.cli`
  (CLI), and `dev.macsweep.weeklyscan` (background task).
- The earlier identifier migration moved every bundle identifier from
  `com.vincentshipsit.macsweep` to the reverse-DNS of the domain:
  `dev.macsweep.app` (app), `dev.macsweep.core` (framework), `dev.macsweep.cli`
  (CLI), and `dev.macsweep.weeklyscan` (background task). The shared scheduler
  preferences suite and log subsystem stay on the org-level `dev.macsweep`
  namespace (the common parent the app and CLI both read); the app's Keychain
  service and the assistant config directory
  (`~/Library/Application Support/macsweep.dev`) follow the same rename.
  Because no signed build ever shipped under the old identifier, existing
  installs simply re-run onboarding: old preferences, the stored AI API key,
  and the scheduled-scan state are not migrated. The Homebrew tap coordinates
  (`vincentshipsit/tap/macsweep`) and the `macsweep` CLI binary are unchanged.
- The canonical product website is now [macsweep.dev](https://macsweep.dev),
  including the in-app About view and generated Homebrew cask metadata.

### Security

- Release builds now use Developer ID signing, secure timestamps, Apple
  notarization, ticket stapling, and Gatekeeper verification before GitHub
  assets are published. Distribution signing credentials remain isolated in a
  protected GitHub environment.
- Added the macOS privacy-purpose strings required for Apple Events, other app
  data, app bundles, and explicitly requested system-administration actions.
- Removed sandbox-only entitlements from the intentionally non-sandboxed app
  and disabled debugger-entitlement injection in Release builds.

## [1.0.8] - 2026-07-08

### Added

- The dashboard's Mac-overview row now opens a System detail popover (chip,
  macOS version, memory, storage, uptime), matching the other six status rows.
- CLI JSON: malware-scan findings (`HeadlessThreatFinding`) now include `id` and
  `isKnownSignature`, so automation consumers can dedupe/reference individual
  findings and distinguish known-signature matches from review-tier items.
- CLI JSON: cache-analysis findings (`HeadlessCacheFinding`) now include a raw
  `sizeBytes` byte count (exact for fast-scan findings, absent for AI size
  estimates) so consumers can sum, sort, and threshold sizes. `sizeText` is kept
  for compatibility.

### Changed

- Cache-analysis `sizeText` for fast-scan findings is now derived from the exact
  byte count (e.g. `1.26 GB` instead of `du`'s `1.2G`), matching the byte
  formatting used everywhere else in the app.

### Removed

- Unused `logo.png`/`logo.svg` are no longer bundled into the app (~1.5 MB
  smaller); the assets moved to `docs/assets/`.

## [1.0.6] - 2026-06-24

### Changed

- Polished the native dashboard titlebar/sidebar chrome so the main window uses
  the platform titlebar behavior while keeping MacSweep's compact launch size.
- Moved the Smart Care rescan control into the navigation toolbar placement and
  kept Clean Recommended as the primary dashboard action.

## [1.0.5] - 2026-06-24

### Added

- Homebrew GUI cask distribution: releases now publish a `MacSweep.app` zip and
  update `Casks/macsweep.rb`, whose GUI install depends on the `macsweep` CLI
  formula so `brew install --cask vincentshipsit/tap/macsweep` installs both.

## [1.0.2] - 2026-06-14

### Added

- `macsweep self-update` — prints the Homebrew upgrade command, or runs it with `--yes`.
- `macsweep schedule status` and `macsweep schedule set-interval <days>` — read and
  configure the weekly background-scan interval. The CLI and the GUI scheduler share
  the same `com.vincentshipsit.macsweep` preferences domain, so a change from either
  side is honoured by the other.
- CLI parity for network, running processes, privacy, and system monitoring.
- Deeper malware scanning — crontab `@reboot` indicators, Firefox profile coverage,
  Homebrew dependency/leaves analysis, and minimum-size gating.

### Changed

- The GUI now surfaces deletion and scan errors instead of silently swallowing them.
- Malware scanner: full-path pipe detection plus a dedicated `threatsFound` exit code.

### Security

- **Closed a GUI deletion bypass** — all cleanup now routes through
  `ScanEngine`/`DeletionGuard`, so deletions initiated from the GUI pass the same
  default-deny safety checks, protected-path rules, and aggregate size cap as the CLI.

### Internal

- CLI exit-code contract with partial-scan surfacing and parser test coverage.
- Safety-critical unit tests: `DeletionGuard`, `LoginItemController`, assistant
  watchlist, `CacheAnalyzer`, duplicate finder, malware pipeline, login enumerator.
- Release tooling: a tag-gated Homebrew CI job (validates the formula `sha256` against
  its pinned tarball, then installs build-from-source and runs `brew test`), five
  headless data-state snapshot variants for the deletion-bearing flows, and
  version-sync automation across the CLI and Xcode project.

## [1.0.1] - 2026-06-14

### Changed

- Malware scanner adopts an IoC-first severity model, so a machine with no
  indicators of compromise reports clean instead of surfacing benign noise.
- Malware allowlist is now forgery-resistant, resolving interpreter wrappers before
  matching so a renamed shell can't impersonate a trusted binary.

### Fixed

- Cleared all release-build warnings in the scan modules.

### Internal

- Migrated the test suite from XCTest to swift-testing; it now runs without a full
  Xcode install (CommandLineTools-only) and is wired into CI on `macos-15`.
- Added malware-pipeline and deletion-path unit tests.
- Documented the required `brew trust` step in the Homebrew formula install notes.

## [1.0.0] - 2026-06-13

Initial public release — a CLI-first native macOS system cleaner.

### Added

- **Smart Scan** — one-click deep scan for junk files.
- **System Cleanup** — caches, logs, and temporary files.
- **Browser & Network Cleanup** — browser caches, service workers, network caches.
- **Developer Tools cleanup** — `node_modules`, DerivedData, Docker, mise, sccache,
  deno, and other developer caches.
- **AI Analysis** — Claude-powered cache identification (opt-in, your own API key;
  sends directory names and sizes only, never file contents; key stored in Keychain).
- **AI Assistant** — local Codex/Claude planning with persistent watchlists, all
  routed through the same safety pipeline as manual cleanup.
- **Large & Old Files** finder and interactive **Space Lens** disk visualization.
- **App Uninstaller** with orphaned-leftover detection.
- **Malware scanner** with a signature/Homebrew/extension trust allowlist.
- **Login Items & Launch Agents** manager.
- **Homebrew updater** with AI changelog analysis.
- **File Shredder** for secure deletion, **Privacy** history clearing, **Menu Bar
  widget**, and real-time CPU/RAM/disk/battery/network monitoring.
- **Weekly background scan agent** with local notifications.
- **Safety pipeline** — dry-run by default, default-deny `SafetyChecker`, protected
  paths, aggregate `DeletionGuard` size cap, and trash-not-delete across all modules.
- **CLI-first design** — every feature is reachable headless with documented exit
  codes for agent automation.
- **Homebrew distribution** — build-from-source formula, no Apple Developer account
  or code signing required.

[Unreleased]: https://github.com/VincentShipsIt/macsweep/compare/v1.0.8...HEAD
[1.0.8]: https://github.com/VincentShipsIt/macsweep/compare/v1.0.7...v1.0.8
[1.0.6]: https://github.com/VincentShipsIt/macsweep/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/VincentShipsIt/macsweep/compare/v1.0.4...v1.0.5
[1.0.2]: https://github.com/VincentShipsIt/macsweep/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/VincentShipsIt/macsweep/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/VincentShipsIt/macsweep/releases/tag/v1.0.0
