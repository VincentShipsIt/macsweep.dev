#!/bin/zsh
# Hermetic checks for scripts/release.sh. Fixtures live outside the checkout,
# and the copied release script resolves its version sources from that fixture.
set -uo pipefail

REPO_ROOT="${0:A:h:h}"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/macsweep-release-test-XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

mkdir -p \
  "$FIXTURE_ROOT/scripts" \
  "$FIXTURE_ROOT/MacSweep/Sources/Core" \
  "$FIXTURE_ROOT/MacSweep/MacSweep.xcodeproj"
cp "$REPO_ROOT/scripts/release.sh" "$FIXTURE_ROOT/scripts/release.sh"

typeset -i failures=0
OUT=""

ok()   { print "ok   - $1" }
fail() { print -u2 "FAIL - $1"; failures+=1 }

write_versions() {
  local swift="$1" marketing="$2" build="$3"
  print "public enum MacSweepVersion {" \
    > "$FIXTURE_ROOT/MacSweep/Sources/Core/MacSweepVersion.swift"
  print "    public static let current = \"$swift\"" \
    >> "$FIXTURE_ROOT/MacSweep/Sources/Core/MacSweepVersion.swift"
  print "}" >> "$FIXTURE_ROOT/MacSweep/Sources/Core/MacSweepVersion.swift"

  {
    print "MARKETING_VERSION = $marketing;"
    print "CURRENT_PROJECT_VERSION = $build;"
    print "MARKETING_VERSION = $marketing;"
    print "CURRENT_PROJECT_VERSION = $build;"
  } > "$FIXTURE_ROOT/MacSweep/MacSweep.xcodeproj/project.pbxproj"
}

run_check() {
  local expected="$1" desc="$2"
  local rc
  OUT="$(zsh "$FIXTURE_ROOT/scripts/release.sh" check 2>&1)"
  rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    ok "$desc (exit $rc)"
  else
    fail "$desc: expected exit $expected, got $rc"
    print -u2 -- "$OUT"
  fi
}

output_contains() {
  local desc="$1" pattern="$2"
  if print -r -- "$OUT" | grep -Fq -- "$pattern"; then
    ok "$desc"
  else
    fail "$desc"
  fi
}

output_excludes() {
  local desc="$1" pattern="$2"
  if print -r -- "$OUT" | grep -Fq -- "$pattern"; then
    fail "$desc"
  else
    ok "$desc"
  fi
}

write_versions "1.2.3" "1.2.3" "1.2.3"
run_check 0 "matching semantic versions pass"
output_contains "success names the aligned version" \
  "all version sources agree on 1.2.3"

write_versions "1.2.3" "1.2.4" "1.2.3"
run_check 1 "marketing-version drift fails"
output_contains "drift identifies MARKETING_VERSION" \
  "pbxproj MARKETING_VERSION"

write_versions "1.2" "1.2" "1.2"
run_check 1 "matching malformed versions fail"
output_contains "malformed source gets an actionable diagnostic" \
  "MacSweepVersion.swift (1.2) is not X.Y.Z"
output_excludes "malformed versions are never reported as aligned" \
  "all version sources agree"

print ""
if (( failures > 0 )); then
  print -u2 "release checks: $failures failure(s)"
  exit 1
fi
print "release checks: all passed"
