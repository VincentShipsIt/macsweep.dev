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

# A full Xcode install exposes an .xctest host; CLT-only does not.
if xcrun --find xctest >/dev/null 2>&1; then
  print "xctest host present — running plain swift test"
  exec swift test --package-path "$PKG" "$@"
fi

if [[ ! -d "$CLT_FW/Testing.framework" ]]; then
  print -u2 "error: no xctest host and no CLT Testing.framework at $CLT_FW"
  print -u2 "       install Xcode, or a Command Line Tools build that ships swift-testing."
  exit 1
fi

print "Command Line Tools host — running standalone swift-testing runner"
exec swift test \
  --package-path "$PKG" \
  --disable-xctest \
  -Xswiftc -F -Xswiftc "$CLT_FW" \
  -Xlinker -F -Xlinker "$CLT_FW" \
  -Xlinker -rpath -Xlinker "$CLT_FW" \
  -Xlinker -rpath -Xlinker "$CLT_LIB" \
  "$@"
