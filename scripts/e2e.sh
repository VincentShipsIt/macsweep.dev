#!/bin/zsh
# MacSweep CLI e2e safety smoke suite (#31).
#
# Deterministic, non-destructive end-to-end checks of the built `macsweep`
# binary: command parsing and exit codes, scan/dry-run behavior against a
# self-created fixture, protected-path refusal, and the apply confirmation
# gate. The suite NEVER modifies real user directories:
#   * scans are read-only by design;
#   * cleanup is exercised only via dry-run and via apply WITHOUT --yes
#     (stdin is not a tty here, so the CLI must stop at the confirmation gate);
#   * the shred refusal case targets a symlink whose target is a fixture file
#     owned by this script — if the refusal guard ever regressed, the only
#     casualty would be the fixture, and the content check would catch it.
#
# All fixtures live in a UUID-scoped directory under $TMPDIR (the per-user
# /var/folders/…/T/ root that SystemCacheModule deliberately scans) and are
# removed on exit.
#
# Usage:
#   zsh scripts/e2e.sh                 # builds the debug CLI, then runs
#   MACSWEEP_BIN=/path/to/macsweep zsh scripts/e2e.sh   # use a prebuilt binary
set -uo pipefail

REPO_ROOT="${0:A:h:h}"
PKG="$REPO_ROOT/MacSweep"

BIN="${MACSWEEP_BIN:-}"
if [[ -z "$BIN" ]]; then
  print "Building debug CLI…"
  swift build --package-path "$PKG" --product macsweep >/dev/null
  BIN="$(swift build --package-path "$PKG" --product macsweep --show-bin-path)/macsweep"
fi
[[ -x "$BIN" ]] || { print -u2 "error: macsweep binary not found at $BIN"; exit 1 }
print "Using binary: $BIN"

# Fixture root directly under the user temp dir (T/), where the system-cache
# module's temp-folder scan looks. Backdating the mtime moves it past the
# module's "modified within the last hour" in-use guard.
FIXTURE_ROOT="$(mktemp -d "${TMPDIR%/}/macsweep-e2e-XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

typeset -i failures=0
OUT=""

ok()   { print "ok   - $1" }
fail() { print -u2 "FAIL - $1"; failures+=1 }

# run_expect <expected-exit> <desc> <argv…> — runs the CLI with stdin closed
# (never interactive), captures combined output in $OUT, checks the exit code.
run_expect() {
  local expected="$1" desc="$2"; shift 2
  local rc
  OUT="$("$BIN" "$@" 2>&1 < /dev/null)"
  rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    ok "$desc (exit $rc)"
  else
    fail "$desc: expected exit $expected, got $rc"
    print -u2 "${OUT}" | head -20
  fi
}

# json_assert <desc> <python-expression over parsed dict d> — $OUT must be
# valid JSON and the expression must be truthy.
json_assert() {
  local desc="$1" expr="$2"
  if print -r -- "$OUT" | /usr/bin/python3 -c "
import json, sys
d = json.load(sys.stdin)
assert ($expr)
" 2>/dev/null; then
    ok "$desc"
  else
    fail "$desc"
  fi
}

# ---------------------------------------------------------------- basic CLI
run_expect 0 "version exits 0" version
run_expect 0 "version --format json emits JSON" version --format json
json_assert "version JSON has a version field" "'version' in json.dumps(d)"
run_expect 0 "help exits 0" help
run_expect 2 "unknown command is a usage error" definitely-not-a-command
run_expect 2 "unknown flag is a usage error" scan --definitely-not-a-flag
run_expect 2 "invalid module id is a usage error" scan --modules not-a-real-module --format json

# ------------------------------------------------------------- modules list
run_expect 0 "modules list emits JSON" modules list --format json
json_assert "modules list includes system-cache" "'system-cache' in json.dumps(d)"

# --------------------------------------------- fixture scan (system-cache)
# A >10KB fixture directory under T/ with an aged mtime must be surfaced by
# `scan --modules system-cache`.
SCAN_FIXTURE="$FIXTURE_ROOT/scan-target"
mkdir -p "$SCAN_FIXTURE"
dd if=/dev/urandom of="$SCAN_FIXTURE/junk.bin" bs=1024 count=64 2>/dev/null
touch -t 202401010000 "$SCAN_FIXTURE/junk.bin" "$SCAN_FIXTURE" "$FIXTURE_ROOT"

run_expect 0 "scan --modules system-cache emits JSON" scan --modules system-cache --format json
json_assert "scan JSON has metadata/findings/summary" \
  "'metadata' in d and 'findings' in d and 'summary' in d"
json_assert "scan surfaces the temp fixture" "'$FIXTURE_ROOT' in json.dumps(d)"

# ------------------------------------------------------- dry-run is dry
run_expect 0 "dry-run --modules system-cache emits JSON" dry-run --modules system-cache --format json
json_assert "dry-run JSON carries a cleanup preview" "'cleanup' in json.dumps(d)"
if [[ -f "$SCAN_FIXTURE/junk.bin" ]]; then
  ok "dry-run deleted nothing (fixture intact)"
else
  fail "dry-run DELETED the fixture — dry-run must never remove files"
fi

# -------------------------------------- apply without --yes must be gated
# stdin is not a tty, so the CLI must refuse with the confirmation-required
# exit code (3) BEFORE executing any cleanup.
run_expect 3 "apply without --yes stops at the confirmation gate" apply --modules system-cache --format json
if [[ -f "$SCAN_FIXTURE/junk.bin" ]]; then
  ok "gated apply deleted nothing (fixture intact)"
else
  fail "gated apply DELETED the fixture — confirmation gate regressed"
fi

# --------------------------------------------------- protected-path refusal
# Shred refuses symlinks (overwriting would destroy the link target). The
# target is our own fixture, so a guard regression damages nothing real —
# and the content comparison below would catch it loudly.
SHRED_TARGET="$FIXTURE_ROOT/shred-target.txt"
SHRED_LINK="$FIXTURE_ROOT/shred-link"
print "precious bytes" > "$SHRED_TARGET"
ln -s "$SHRED_TARGET" "$SHRED_LINK"

run_expect 5 "shred refuses a symlink (protected-path guard)" shred "$SHRED_LINK" --yes --format json
if [[ "$(cat "$SHRED_TARGET")" == "precious bytes" ]]; then
  ok "refused shred left the link target untouched"
else
  fail "shred guard regressed: the symlink target was modified"
fi

run_expect 4 "shred of a missing path exits not-found" shred "$FIXTURE_ROOT/does-not-exist" --yes

# ------------------------------------------------------------------- result
print ""
if (( failures > 0 )); then
  print -u2 "e2e smoke suite: $failures failure(s)"
  exit 1
fi
print "e2e smoke suite: all checks passed"
