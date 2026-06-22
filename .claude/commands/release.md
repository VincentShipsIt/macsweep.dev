# /release — cut a MacSweep release and auto-publish to Homebrew

Tag the current `master` as `vX.Y.Z` so CI builds + smoke-tests the `macsweep` CLI,
publishes a GitHub Release, and bumps the Homebrew **formula** in
`VincentShipsIt/homebrew-tap` — all from one tag push. Run this after the
version-bumping PR has merged to `master`.

MacSweep ships as a **build-from-source formula** (no cask): the formula's `url` is the
tag's source tarball and `sha256` is its digest; `brew install` compiles the CLI.

## Preconditions (one-time)
- The repo secret `TAP_GITHUB_TOKEN` exists (token with `contents: write` on
  `VincentShipsIt/homebrew-tap`) — `update-homebrew.yml` needs it to push the bump.
- `Formula/macsweep.rb` lives in `VincentShipsIt/homebrew-tap` (the tap-consolidation
  is merged), not in this repo.

## Steps

1. **Preflight — clean, current master.**
   - `git fetch origin --prune`
   - Current branch must be `master` and `git status` clean. If not, stop and tell the user.
   - Local `master` must equal `origin/master` (fast-forward if behind; stop if diverged).

2. **Verify version consistency, then read the version.**
   - `scripts/release.sh check` must pass (all version sources agree). If it fails, STOP
     and tell the user to run `scripts/release.sh bump X.Y.Z` in a PR first.
   - `VERSION=$(grep -m1 'MARKETING_VERSION:' MacSweep/project.yml | sed -E 's/.*"([0-9.]+)".*/\1/')`
   - `TAG="v$VERSION"`

3. **Guard against double-release.**
   - If `git ls-remote --tags origin "$TAG"` returns the tag, STOP: this version is
     already released. Tell the user to bump the version
     (`scripts/release.sh bump X.Y.Z`) in a PR, merge it, then re-run `/release`.

4. **Tag + push (this triggers everything).**
   - `git tag -a "$TAG" origin/master -m "MacSweep $TAG"`
   - `git push origin "$TAG"`
   - Fires `.github/workflows/release.yml`: build + smoke-test CLI → compute source
     tarball sha256 → publish GitHub Release (`macsweep-$TAG.tar.gz.sha256` asset,
     auto-generated notes) → its `update-homebrew` job calls `update-homebrew.yml`,
     which bumps `url` + `sha256` in the tap's `Formula/macsweep.rb`.

5. **Watch both jobs land.**
   - `gh run watch "$(gh run list --workflow=Release --limit 1 --json databaseId -q '.[0].databaseId')"`
   - Confirm the `build` AND `update-homebrew` jobs both succeed.
   - Verify the formula bumped:
     `gh api repos/VincentShipsIt/homebrew-tap/contents/Formula/macsweep.rb -q .content | base64 -d | grep -E 'url|sha256'`
     — the `url` tag and `sha256` must match `$TAG` and the published `.sha256` asset.

6. **Report** the release URL and the consumer command:
   - `brew update && brew upgrade macsweep`
   - First-time: `brew tap vincentshipsit/tap && brew trust --formula vincentshipsit/tap/macsweep && brew install macsweep`.

## Notes
- The formula is build-from-source, so the release pins the **source tarball's** sha256
  (GitHub's `archive/refs/tags/$TAG.tar.gz`), not a prebuilt binary.
- If the `update-homebrew` job ever fails alone, re-run it:
  `gh workflow run "Update Homebrew" -f version=vX.Y.Z`.
- Never move or delete a published tag — cut a new patch version instead.
