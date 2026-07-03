#!/bin/zsh
# MacSweep coverage runner (#32).
#
# Runs the full suite with code coverage via scripts/test.sh (so both toolchain
# paths — full Xcode and CLT-only — work), then reports per-file line coverage
# for the safety-critical scope and FAILS if any enforced file drops below its
# floor. Informational files (floor 0) are reported but never fail the run.
#
# The floors are set a few points below the coverage measured when this gate
# was introduced: they exist to catch a safety-critical file losing its tests,
# not to block unrelated changes. Raise them as coverage grows.
#
# Output: a markdown table on stdout; if $GITHUB_STEP_SUMMARY is set (GitHub
# Actions), the same table is appended there so it shows in the job summary.
#
# Usage:
#   zsh scripts/coverage.sh          # run tests with coverage + enforce floors
set -euo pipefail

REPO_ROOT="${0:A:h:h}"
PKG="$REPO_ROOT/MacSweep"

zsh "$REPO_ROOT/scripts/test.sh" --enable-code-coverage

CODECOV_JSON="$(swift test --package-path "$PKG" --show-codecov-path)"
[[ -f "$CODECOV_JSON" ]] || { print -u2 "error: no coverage export at $CODECOV_JSON"; exit 1 }

/usr/bin/python3 - "$CODECOV_JSON" <<'EOF'
import json, os, sys

# path suffix -> minimum line coverage (%). 0 = informational only.
SCOPE = {
    # Deletion guard / preflight and the disposal primitive.
    "Sources/Core/Safety/SafetyChecker.swift": 85,
    "Sources/Core/Safety/CleanupFileRemover.swift": 90,
    # CLI command parser (agent-facing interface).
    "Sources/CLIKit/CLICommand.swift": 80,
    # Scan/clean orchestration.
    "Sources/Core/Scanning/ScanEngine.swift": 75,
    "Sources/Core/Scanning/Modules/SystemCacheModule.swift": 90,
    # Headless service boundary + serialization: tracked, not yet enforced.
    "Sources/Core/Headless/HeadlessService.swift": 0,
    "Sources/Core/Headless/HeadlessModels.swift": 0,
    "Sources/Core/Scanning/Modules/AppUninstallerModule.swift": 0,
    "Sources/Core/Maintenance/MaintenanceActions.swift": 0,
}

data = json.load(open(sys.argv[1]))
by_suffix = {}
for entry in data["data"][0]["files"]:
    for suffix in SCOPE:
        if entry["filename"].endswith(suffix):
            by_suffix[suffix] = entry["summary"]["lines"]

rows = ["| File | Lines | Coverage | Floor | Status |",
        "|------|-------|----------|-------|--------|"]
failures = []
for suffix, floor in SCOPE.items():
    lines = by_suffix.get(suffix)
    name = suffix.split("/")[-1]
    if lines is None:
        rows.append(f"| {name} | – | missing from export | {floor}% | ❌ |")
        failures.append(f"{name}: not present in coverage export")
        continue
    pct = lines["percent"]
    if floor > 0 and pct < floor:
        status = "❌"
        failures.append(f"{name}: {pct:.1f}% < required {floor}%")
    else:
        status = "✅" if floor > 0 else "ℹ️"
    floor_label = f"{floor}%" if floor > 0 else "—"
    rows.append(f"| {name} | {lines['covered']}/{lines['count']} | {pct:.1f}% | {floor_label} | {status} |")

table = "## Safety-critical coverage\n\n" + "\n".join(rows) + "\n"
print(table)

summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
if summary_path:
    with open(summary_path, "a") as fh:
        fh.write(table + "\n")

if failures:
    print("Coverage floor violations:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("All enforced coverage floors met.")
EOF
