#!/bin/zsh
# MacSweep release automation — version consistency + cut preparation.
#
# The version string lives in several places that MUST agree, or `brew install`
# builds one version while the binary reports another (exactly the 1.0.0/1.0.1
# drift this script exists to prevent):
#
#   1. MacSweep/project.yml            MARKETING_VERSION       (XcodeGen SSoT)
#   2. MacSweep/Sources/Core/MacSweepVersion.swift  .current  (CLI `version`)
#   3. Formula/macsweep.rb             url .../tags/vX.Y.Z     (brew tarball)
#   4. MacSweep/MacSweep.xcodeproj/...pbxproj  MARKETING_VERSION (generated)
#
# (4) is generated from (1) by `xcodegen generate`; it's checked in, so it can
# go stale if someone bumps project.yml without regenerating.
#
# No code signing / notarization yet: distribution is brew build-from-source.
# This script therefore performs NO outward-facing actions — it never creates a
# git tag, never pushes, never edits the formula's url/sha (that needs a tag that
# already exists on GitHub). It verifies, bumps local sources, and prints the
# remaining manual steps. Safe to run in CI or a pre-commit hook.
#
# Usage:
#   scripts/release.sh check          Verify all version sources agree (read-only).
#   scripts/release.sh bump X.Y.Z     Set X.Y.Z in project.yml + MacSweepVersion,
#                                      regenerate the xcodeproj, then re-verify.
#   scripts/release.sh sha [X.Y.Z]    Fetch the GitHub tag tarball and print its
#                                      sha256 for the formula (defaults to the
#                                      current version). Network read only.
#
# Exit codes: 0 = success / consistent, 1 = drift or error, 2 = usage.
set -euo pipefail

REPO_ROOT="${0:A:h:h}"   # scripts/ -> repo root
PKG="$REPO_ROOT/MacSweep"
PROJECT_YML="$PKG/project.yml"
VERSION_SWIFT="$PKG/Sources/Core/MacSweepVersion.swift"
FORMULA="$REPO_ROOT/Formula/macsweep.rb"
PBXPROJ="$PKG/MacSweep.xcodeproj/project.pbxproj"

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

# --- extractors: each prints the single version string from one source ----------
yml_version()     { grep 'MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*"\(.*\)".*/\1/'; }
swift_version()   { grep 'static let current' "$VERSION_SWIFT" | head -1 | sed 's/.*"\(.*\)".*/\1/'; }
formula_version() { grep 'url ' "$FORMULA" | head -1 | sed 's|.*/v\(.*\)\.tar\.gz.*|\1|'; }
# pbxproj has the value on multiple targets; assert they're uniform and print one.
pbxproj_version() {
  grep 'MARKETING_VERSION = ' "$PBXPROJ" | sed 's/.*= \(.*\);/\1/' | sort -u
}

die()  { print -u2 "error: $*"; exit 1; }
usage() { print -u2 "usage: release.sh {check|bump X.Y.Z|sha [X.Y.Z]}"; exit 2; }

cmd_check() {
  local yml swift formula pbx
  yml="$(yml_version)"
  swift="$(swift_version)"
  formula="$(formula_version)"
  pbx="$(pbxproj_version)"   # may be multiple lines if targets disagree

  print "version sources:"
  print "  project.yml          $yml"
  print "  MacSweepVersion.swift $swift"
  print "  Formula url tag       $formula"
  print "  pbxproj (generated)   ${pbx//$'\n'/, }"

  local ok=1
  [[ "$swift"   == "$yml" ]] || { print -u2 "  ✗ MacSweepVersion.swift ($swift) != project.yml ($yml)"; ok=0; }
  [[ "$formula" == "$yml" ]] || { print -u2 "  ✗ Formula url ($formula) != project.yml ($yml)"; ok=0; }
  # pbx must be exactly one distinct value AND equal to the SSoT.
  if [[ "$(print -r -- "$pbx" | wc -l | tr -d ' ')" != "1" || "$pbx" != "$yml" ]]; then
    print -u2 "  ✗ pbxproj MARKETING_VERSION ($pbx) != project.yml ($yml) — run: scripts/release.sh bump $yml"
    ok=0
  fi

  if [[ "$ok" == "1" ]]; then
    print "✓ all version sources agree on $yml"
    return 0
  fi
  return 1
}

cmd_bump() {
  local new="${1:-}"
  [[ -n "$new" ]] || usage
  [[ "$new" =~ $SEMVER_RE ]] || die "version must be X.Y.Z, got '$new'"
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"

  # Edit the two human-owned SSoT files in place.
  sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$new\"/" "$PROJECT_YML"
  sed -i '' "s/static let current = \".*\"/static let current = \"$new\"/" "$VERSION_SWIFT"

  # Regenerate the checked-in xcodeproj so its MARKETING_VERSION tracks the SSoT.
  ( cd "$PKG" && xcodegen generate >/dev/null )

  print "bumped project.yml + MacSweepVersion.swift -> $new and regenerated xcodeproj"
  print ""
  cmd_check || die "post-bump verification failed"
  print ""
  print "next (manual, outward-facing — left to you):"
  print "  1. commit the version bump"
  print "  2. git tag v$new && git push origin v$new"
  print "  3. scripts/release.sh sha $new   # then paste url+sha256 into Formula/macsweep.rb"
}

cmd_sha() {
  local v="${1:-$(yml_version)}"
  [[ "$v" =~ $SEMVER_RE ]] || die "version must be X.Y.Z, got '$v'"
  local url="https://github.com/VincentShipsIt/macsweep/archive/refs/tags/v$v.tar.gz"
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
