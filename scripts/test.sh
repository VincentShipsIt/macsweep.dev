#!/bin/zsh
# Run the MacSweep test suite (swift-testing) on this host.
#
# The suite is written against `import Testing`. How SwiftPM runs it depends on
# the toolchain:
#
#   * Full Xcode:        plain `swift test` finds swift-testing and runs it.
#   * Command Line Tools: CLT bundles Testing.framework but NOT the `xctest` host
#     tool, so SwiftPM's default `.xctest`-bundle path builds a bundle that never
#     executes (silent pass). We pass `--disable-xctest` to build a STANDALONE
#     swift-testing runner instead, plus the CLT framework search path and the
#     two rpaths (Frameworks + usr/lib for lib_TestingInterop.dylib) inline so
#     they reach that synthesized runner product. Target-scoped flags in
#     Package.swift would NOT reach it — that's why they live here, not there.
#
# Works under CommandLineTools only — no Xcode, no xcodebuild required.
# Any extra args are forwarded to `swift test` (e.g. --filter SafetyCheckerTests).
set -euo pipefail

REPO_ROOT="${0:A:h:h}"   # scripts/ -> repo root
PKG="$REPO_ROOT/MacSweep"

CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

# A full Xcode install exposes an .xctest host; CLT-only does not. Each branch
# assembles the right `swift test` argv; the shared runner below executes it once.
typeset -a TEST_ARGS
if xcrun --find xctest >/dev/null 2>&1; then
  print "xctest host present — running plain swift test"
  TEST_ARGS=(--package-path "$PKG" "$@")
elif [[ -d "$CLT_FW/Testing.framework" ]]; then
  print "Command Line Tools host — running standalone swift-testing runner"
  TEST_ARGS=(
    --package-path "$PKG"
    --disable-xctest
    -Xswiftc -F -Xswiftc "$CLT_FW"
    -Xlinker -F -Xlinker "$CLT_FW"
    -Xlinker -rpath -Xlinker "$CLT_FW"
    -Xlinker -rpath -Xlinker "$CLT_LIB"
    "$@"
  )
else
  print -u2 "error: no xctest host and no CLT Testing.framework at $CLT_FW"
  print -u2 "       install Xcode, or a Command Line Tools build that ships swift-testing."
  exit 1
fi

# Run once, streaming output live (tee -> stderr) while also capturing it to a
# temp file so we can assert tests actually ran. We run the pipeline in *this*
# shell (not a $() subshell) so zsh's $pipestatus reflects `swift test` itself;
# errexit is dropped only around the pipeline so a failing run reaches the check.
LOG="$(mktemp -t macsweep-test)"
trap 'rm -f "$LOG"' EXIT

set +e
swift test "${TEST_ARGS[@]}" 2>&1 | tee "$LOG" >&2
STATUS=${pipestatus[1]}   # exit code of `swift test`, not `tee` (pipefail-equiv)
set -e

# Propagate a real test FAILURE verbatim.
[[ "$STATUS" -eq 0 ]] || exit "$STATUS"

# Guard against the silent-pass footgun: a build that never executes the suite
# can still exit 0 with no tests run. Require a positive run marker with a
# NON-zero test count.
#   swift-testing: "✔ Test run with 12 tests ... passed" / "Test run with 12 tests"
#   XCTest:        "Executed 12 tests"
if grep -Eq 'Test run with [1-9][0-9]* test|Executed [1-9][0-9]* test' "$LOG"; then
  exit 0
fi

print -u2 "error: swift test exited 0 but no tests appear to have run (0 tests or no run marker)."
print -u2 "       this is the silent-pass case this script exists to catch — check the toolchain/test setup."
exit 1
