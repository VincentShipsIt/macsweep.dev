#!/bin/zsh
# MacSweep release automation — version consistency + cut preparation.
#
# The version string lives in several places that MUST agree, or `brew install`
# builds one version while the binary reports another (exactly the 1.0.0/1.0.1
# drift this script exists to prevent):
#
#   1. MacSweep/Sources/Core/MacSweepVersion.swift  .current  (SSoT; CLI `version`)
#   2. MacSweep/MacSweep.xcodeproj/...pbxproj  MARKETING_VERSION (app bundle)
#   3. MacSweep/MacSweep.xcodeproj/...pbxproj  CURRENT_PROJECT_VERSION
#      (Sparkle's monotonically increasing update version)
#
# The xcodeproj is hand-maintained (synchronized folder references — file
# adds/removals never touch it), NOT generated: XcodeGen and project.yml are
# gone, so `bump` edits MARKETING_VERSION in the pbxproj directly with sed.
#
# The Homebrew formula and cask live in a SEPARATE repo —
# VincentShipsIt/homebrew-tap (Formula/macsweep.rb, Casks/macsweep.rb) — so this
# script can't edit them directly. The tag-triggered Release workflow publishes
# the source tarball checksum, the app zip, and the app zip checksum, then bumps
# both tap files. `release.sh sha` remains a read-only formula checksum helper.
#
# Developer ID signing and notarization happen in the tag-triggered Release
# workflow, using credentials stored in GitHub's protected `release`
# environment. This script performs NO outward-facing actions — it never
# creates a git tag, never pushes, and never edits the tap's formula/cask (that
# needs a tag that already exists on GitHub). It verifies, bumps local sources,
# and prints the remaining manual steps. Safe to run in CI or a pre-commit hook.
#
# Usage:
#   scripts/release.sh check          Verify all version sources agree (read-only).
#   scripts/release.sh bump X.Y.Z     Set X.Y.Z in MacSweepVersion.swift + the
#                                      pbxproj MARKETING_VERSION, then re-verify.
#   scripts/release.sh sha [X.Y.Z]    Fetch the GitHub tag tarball and print its
#                                      sha256 for the formula (defaults to the
#                                      current version). Network read only.
#
# Exit codes: 0 = success / consistent, 1 = drift or error, 2 = usage.
set -euo pipefail

REPO_ROOT="${0:A:h:h}"   # scripts/ -> repo root
PKG="$REPO_ROOT/MacSweep"
VERSION_SWIFT="$PKG/Sources/Core/MacSweepVersion.swift"
PBXPROJ="$PKG/MacSweep.xcodeproj/project.pbxproj"

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

# --- extractors: each prints the single version string from one source ----------
swift_version()   { grep 'static let current' "$VERSION_SWIFT" | head -1 | sed 's/.*"\(.*\)".*/\1/'; }
# pbxproj may carry the value on multiple configs; assert they're uniform and print one.
pbxproj_version() {
  grep 'MARKETING_VERSION = ' "$PBXPROJ" | sed 's/.*= \(.*\);/\1/' | sort -u
}
pbxproj_build() {
  grep 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed 's/.*= \(.*\);/\1/' | sort -u
}

die()  { print -u2 "error: $*"; exit 1; }
usage() { print -u2 "usage: release.sh {check|bump X.Y.Z|sha [X.Y.Z]}"; exit 2; }

cmd_check() {
  local swift pbx build
  swift="$(swift_version)"
  pbx="$(pbxproj_version)"   # may be multiple lines if configs disagree
  build="$(pbxproj_build)"

  print "version sources:"
  print "  MacSweepVersion.swift $swift"
  print "  pbxproj               ${pbx//$'\n'/, }"
  print "  bundle build          ${build//$'\n'/, }"

  local ok=1
  if [[ ! "$swift" =~ $SEMVER_RE ]]; then
    print -u2 "  ✗ MacSweepVersion.swift ($swift) is not X.Y.Z — run: scripts/release.sh bump X.Y.Z"
    ok=0
  fi
  # pbx must be exactly one distinct value AND equal to the SSoT.
  if [[ "$(print -r -- "$pbx" | wc -l | tr -d ' ')" != "1" || "$pbx" != "$swift" ]]; then
    print -u2 "  ✗ pbxproj MARKETING_VERSION ($pbx) != MacSweepVersion.swift ($swift) — run: scripts/release.sh bump $swift"
    ok=0
  fi
  if [[ "$(print -r -- "$build" | wc -l | tr -d ' ')" != "1" || "$build" != "$swift" ]]; then
    print -u2 "  ✗ pbxproj CURRENT_PROJECT_VERSION ($build) != MacSweepVersion.swift ($swift) — run: scripts/release.sh bump $swift"
    ok=0
  fi

  if [[ "$ok" == "1" ]]; then
    print "✓ all version sources agree on $swift"
    return 0
  fi
  return 1
}

cmd_bump() {
  local new="${1:-}"
  [[ -n "$new" ]] || usage
  [[ "$new" =~ $SEMVER_RE ]] || die "version must be X.Y.Z, got '$new'"

  # Edit all version carriers in place (the pbxproj is hand-maintained, not
  # generated — sed is the whole story).
  sed -i '' "s/static let current = \".*\"/static let current = \"$new\"/" "$VERSION_SWIFT"
  sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $new;/" "$PBXPROJ"
  sed -i '' "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $new;/" "$PBXPROJ"

  print "bumped app, CLI, and Sparkle build versions -> $new"
  print ""
  cmd_check || die "post-bump verification failed"
  print ""
  print "next (manual, outward-facing — left to you):"
  print "  1. commit the version bump"
  print "  2. git tag v$new && git push origin v$new"
  print "  3. let the Release workflow publish the app zip/checksums and update"
  print "     VincentShipsIt/homebrew-tap (Formula/macsweep.rb + Casks/macsweep.rb)"
}

cmd_sha() {
  local v="${1:-$(swift_version)}"
  [[ "$v" =~ $SEMVER_RE ]] || die "version must be X.Y.Z, got '$v'"
  local url="https://github.com/VincentShipsIt/macsweep.dev/archive/refs/tags/v$v.tar.gz"
  print -u2 "fetching $url ..."
  local sha
  sha="$(curl -fsSL "$url" | shasum -a 256 | awk '{print $1}')" \
    || die "could not fetch tag v$v (does it exist on GitHub?)"
  print "url    \"$url\""
  print "sha256 \"$sha\""
}

[[ $# -ge 1 ]] || usage
case "$1" in
  check) shift; cmd_check "$@" ;;
  bump)  shift; cmd_bump "$@" ;;
  sha)   shift; cmd_sha "$@" ;;
  *)     usage ;;
esac
