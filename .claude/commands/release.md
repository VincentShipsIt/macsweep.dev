# /release — cut a MacSweep release and auto-publish to Homebrew

Tag the current `master` as `vX.Y.Z` so CI builds + smoke-tests the `macsweep` CLI,
builds + packages `MacSweep.app`, publishes a GitHub Release, and bumps both the
Homebrew **formula** and **cask** in `VincentShipsIt/homebrew-tap` — all from one
tag push. Run this after the version-bumping PR has merged to `master`.

MacSweep ships two Homebrew entries:

- `brew install macsweep` installs the build-from-source CLI formula.
- `brew install --cask macsweep` installs the GUI app and depends on the formula,
  so the GUI path installs both `MacSweep.app` and the `macsweep` CLI.

## Preconditions (one-time)
- The Apple Developer Program membership is active and the bundle identifier
  remains `dev.macsweep.app`.
- A protected GitHub environment named `release` exists with these values:
  - Secrets: `DEVELOPER_ID_P12_BASE64`,
    `DEVELOPER_ID_P12_PASSWORD`, and
    `APPLE_API_PRIVATE_KEY_P8_BASE64`.
  - Variables: `APPLE_TEAM_ID`, `APPLE_API_KEY_ID`, and
    `APPLE_API_ISSUER_ID`.
- `DEVELOPER_ID_P12_BASE64` is a password-protected Developer ID Application
  certificate plus private key exported as `.p12` and then base64-encoded.
  `APPLE_API_PRIVATE_KEY_P8_BASE64` is a team App Store Connect API private key
  used only by `notarytool`, also base64-encoded. A Developer ID Installer
  certificate is not needed while MacSweep ships as a zip rather than a pkg.
- The repo secret `TAP_GITHUB_TOKEN` exists (token with `contents: write` on
  `VincentShipsIt/homebrew-tap`) — `update-homebrew.yml` needs it to push the bump.
- `Formula/macsweep.rb` and `Casks/macsweep.rb` live in
  `VincentShipsIt/homebrew-tap` (the tap-consolidation is merged), not in this repo.

To verify configuration without exposing values:

```bash
gh secret list --repo VincentShipsIt/macsweep --env release
gh variable list --repo VincentShipsIt/macsweep --env release
```

## Steps

1. **Preflight — clean, current master.**
   - `git fetch origin --prune`
   - Current branch must be `master` and `git status` clean. If not, stop and tell the user.
   - Local `master` must equal `origin/master` (fast-forward if behind; stop if diverged).

2. **Verify version consistency, then read the version.**
   - `scripts/release.sh check` must pass (all version sources agree). If it fails, STOP
     and tell the user to run `scripts/release.sh bump X.Y.Z` in a PR first.
   - `VERSION=$(grep -m1 'static let current' MacSweep/Sources/Core/MacSweepVersion.swift | sed 's/.*"\(.*\)".*/\1/')`
   - `TAG="v$VERSION"`

3. **Guard against double-release.**
   - If `git ls-remote --tags origin "$TAG"` returns the tag, STOP: this version is
     already released. Tell the user to bump the version
     (`scripts/release.sh bump X.Y.Z`) in a PR, merge it, then re-run `/release`.

4. **Tag + push (this triggers everything).**
   - `git tag -a "$TAG" origin/master -m "MacSweep $TAG"`
   - `git push origin "$TAG"`
   - Fires `.github/workflows/release.yml`: build + smoke-test CLI → archive and
     Developer ID-sign `MacSweep.app` → notarize → staple → Gatekeeper-check →
     package → publish GitHub Release (`macsweep-$TAG.tar.gz.sha256`,
     `macsweep-$TAG-macos.zip`, and `macsweep-$TAG-macos.zip.sha256` assets,
     auto-generated notes) → its `update-homebrew` job calls
     `update-homebrew.yml`, which bumps the tap's formula and cask.

5. **Watch both jobs land.**
   - `gh run watch "$(gh run list --workflow=Release --limit 1 --json databaseId -q '.[0].databaseId')"`
   - Confirm the `build` AND `update-homebrew` jobs both succeed.
   - Verify the formula bumped:
     `gh api repos/VincentShipsIt/homebrew-tap/contents/Formula/macsweep.rb -q .content | base64 -d | grep -E 'url|sha256'`
     — the `url` tag and `sha256` must match `$TAG` and the published `.sha256` asset.
   - Verify the cask bumped and still depends on the formula:
     `gh api repos/VincentShipsIt/homebrew-tap/contents/Casks/macsweep.rb -q .content | base64 -d | grep -E 'version|sha256|url|depends_on|app'`
     — the version, app zip `sha256`, `depends_on formula`, and `app "MacSweep.app"`
     stanzas must be present.
   - Download the published app zip to a clean temporary directory and verify:
     `codesign --verify --deep --strict --verbose=4 MacSweep.app`,
     `xcrun stapler validate MacSweep.app`, and
     `spctl --assess --type execute --verbose=4 MacSweep.app` must all pass.

6. **Report** the release URL and the consumer command:
   - GUI + CLI: `brew update && brew upgrade --cask macsweep && brew upgrade macsweep`
   - First-time GUI + CLI: `brew tap vincentshipsit/tap && brew trust --formula vincentshipsit/tap/macsweep && brew install --cask macsweep`.
   - CLI only: `brew install macsweep`.

## Notes
- The formula is build-from-source, so it pins the **source tarball's** sha256
  (GitHub's `archive/refs/tags/$TAG.tar.gz`). The cask pins the prebuilt
  `macsweep-$TAG-macos.zip` sha256.
- If the `update-homebrew` job ever fails alone, re-run it:
  `gh workflow run "Update Homebrew" -f version=vX.Y.Z`.
- Never move or delete a published tag — cut a new patch version instead.
