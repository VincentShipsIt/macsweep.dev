#!/bin/bash
# Installs only on an ephemeral GitHub-hosted macOS runner. Never run on a user's Mac.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "$(uname -s)" == Darwin ]] || {
  echo 'error: fresh install acceptance requires a GitHub-hosted macOS runner' >&2
  exit 2
}
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="$RUNNER_TEMP/macsweep-fresh-install"
mkdir -p "$EVIDENCE"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
unset HOMEBREW_CASK_OPTS HOMEBREW_NO_QUARANTINE
CASK=vincentshipsit/tap/macsweep
APP=/Applications/MacSweep.app
LAUNCH_ATTEMPTED=false
finish() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$LAUNCH_ATTEMPTED" == true ]]; then
    /usr/sbin/screencapture -x "$EVIDENCE/first-launch-desktop.png" 2>"$EVIDENCE/screenshot.log"
    /usr/bin/log show --last 3m --style compact --predicate 'process == "MacSweep" OR process == "syspolicyd"' \
      > "$EVIDENCE/launch-system.log" 2>&1
  fi
  python3 - "$EVIDENCE" "$status" <<'PY'
import json, pathlib, sys
root, status = pathlib.Path(sys.argv[1]), int(sys.argv[2])
receipt = {"automatedExitStatus": status, "automatedChecksPassed": status == 0,
           "interactiveFirstLaunchReview": "pending actual screenshot/dialog review",
           "fullIssue48Acceptance": False,
           "securityOverridesPerformed": False}
(root / "acceptance.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt))
PY
  {
    echo '### Fresh Homebrew install acceptance'
    echo "Automated check exit status: $status. See the uploaded receipts, install log and real first-launch screenshot."
    echo 'Interactive first-launch/onboarding review remains an explicit acceptance step; fixture snapshots are not fresh-machine evidence.'
    echo 'No quarantine removal, Gatekeeper override, administrator/unlock prompt or automated security-dialog approval was requested.'
  } >> "$GITHUB_STEP_SUMMARY"
  exit "$status"
}
trap finish EXIT
sw_vers > "$EVIDENCE/macos.txt"
brew --version > "$EVIDENCE/homebrew.txt"
/usr/sbin/spctl --status > "$EVIDENCE/gatekeeper-status.txt"
grep -qx 'assessments enabled' "$EVIDENCE/gatekeeper-status.txt"
[[ -w /Applications && ! -e "$APP" ]] || { echo 'Fresh writable Applications directory required' >&2; exit 1; }
# Do not remove existing state to manufacture a fresh-machine pass.
for entry in \
  "$HOME/Library/Preferences/dev.macsweep.app.plist" \
  "$HOME/Library/Application Support/macsweep.dev" \
  "$HOME/Library/Caches/dev.macsweep.app" \
  "$HOME/Library/Saved Application State/dev.macsweep.app.savedState"; do
  [[ ! -e "$entry" ]] || { echo 'Pre-existing MacSweep user state; runner is not fresh' >&2; exit 1; }
done
[[ -z "$(pgrep -x MacSweep || true)" ]] || { echo 'MacSweep already running' >&2; exit 1; }
[[ -z "$(brew list --cask --versions macsweep 2>/dev/null || true)" ]] || { echo 'MacSweep cask already installed' >&2; exit 1; }
[[ -z "$(brew list --formula --versions macsweep 2>/dev/null || true)" ]] || { echo 'MacSweep formula already installed' >&2; exit 1; }
printf 'No prior app, package, process or known user state found.\n' > "$EVIDENCE/freshness.txt"

gh api repos/VincentShipsIt/macsweep.dev/releases/latest > "$EVIDENCE/release.json"
TAG="$(python3 - "$EVIDENCE/release.json" <<'PY'
import json, re, sys
tag = json.load(open(sys.argv[1]))['tag_name']
assert re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag), 'Invalid latest release tag'
print(tag)
PY
)"
[[ -z "${REQUESTED_TAG:-}" || "$REQUESTED_TAG" == "$TAG" ]] || { echo 'Requested release is not current latest' >&2; exit 1; }
brew tap vincentshipsit/tap
# New Homebrew requires explicit third-party package trust. This is scoped to
# the exact cask/formula; it does not approve or disable macOS Gatekeeper.
if brew help trust >/dev/null 2>&1; then
  brew trust --formula "$CASK"
  brew trust --cask "$CASK"
  printf 'Exact MacSweep cask and formula trusted by the runner install.\n' > "$EVIDENCE/package-trust.txt"
fi
git -C "$(brew --repository vincentshipsit/tap)" rev-parse HEAD > "$EVIDENCE/tap-commit.txt"
brew info --json=v2 --cask "$CASK" > "$EVIDENCE/cask.json"
brew info --json=v2 --formula "$CASK" > "$EVIDENCE/formula.json"
for item in 'MacSweep/Sources/Core/MacSweepVersion.swift:MacSweepVersion.swift' 'MacSweep/MacSweep.xcodeproj/project.pbxproj:project.pbxproj'; do
  gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/VincentShipsIt/macsweep.dev/contents/${item%:*}?ref=$TAG" > "$EVIDENCE/${item#*:}"
done
gh release download "$TAG" --repo VincentShipsIt/macsweep.dev --pattern "macsweep-$TAG-macos.zip.sha256" --output "$EVIDENCE/app.sha256"
gh release download "$TAG" --repo VincentShipsIt/macsweep.dev --pattern "macsweep-$TAG.tar.gz.sha256" --output "$EVIDENCE/source.sha256"
python3 "$REPO_ROOT/scripts/release-acceptance.py" "$EVIDENCE"

# Homebrew quarantines cask downloads by default. Do not set any bypass option.
brew install --cask --require-sha "$CASK" 2>&1 | tee "$EVIDENCE/install.log"
brew info --json=v2 --cask "$CASK" > "$EVIDENCE/installed-cask.json"
brew info --json=v2 --formula "$CASK" > "$EVIDENCE/installed-formula.json"
/usr/bin/xattr -p com.apple.quarantine "$APP" > "$EVIDENCE/quarantine-before.txt"
[[ -s "$EVIDENCE/quarantine-before.txt" ]]
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP" 2> "$EVIDENCE/codesign-verify.txt"
/usr/bin/codesign -dvv "$APP" 2> "$EVIDENCE/signature.txt"
grep -q '^Authority=Developer ID Application:' "$EVIDENCE/signature.txt"
grep -q '^Timestamp=' "$EVIDENCE/signature.txt"
grep -q 'flags=.*runtime' "$EVIDENCE/signature.txt"
xcrun stapler validate "$APP" > "$EVIDENCE/stapler.txt" 2>&1
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP" > "$EVIDENCE/gatekeeper-assessment.txt" 2>&1
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" > "$EVIDENCE/app-version.txt"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" > "$EVIDENCE/app-build.txt"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" > "$EVIDENCE/app-id.txt"
"$(brew --prefix)/bin/macsweep" version > "$EVIDENCE/cli-version.txt"
python3 "$REPO_ROOT/scripts/release-acceptance.py" --installed "$EVIDENCE"
# Recheck release identity so a concurrent publication cannot silently relabel this as current.
[[ "$(gh api repos/VincentShipsIt/macsweep.dev/releases/latest --jq .tag_name)" == "$TAG" ]]
xcrun swiftc -parse-as-library "$REPO_ROOT/scripts/FreshInstallProbe.swift" -o "$EVIDENCE/window-probe"
LAUNCH_ATTEMPTED=true
python3 - "$APP" "$EVIDENCE" <<'PYOPEN'
import pathlib, subprocess, sys
app, root = sys.argv[1], pathlib.Path(sys.argv[2])
with (root / 'launch-services.log').open('w') as log:
    subprocess.run(['/usr/bin/open', '-n', '--stdout', str(root / 'app-stdout.txt'),
                    '--stderr', str(root / 'app-stderr.txt'), app],
                   timeout=20, check=True, stdout=log, stderr=log)
PYOPEN
"$EVIDENCE/window-probe" "$APP" "$EVIDENCE/first-launch.json"
/usr/bin/xattr -p com.apple.quarantine "$APP" > "$EVIDENCE/quarantine-after.txt"
[[ -s "$EVIDENCE/quarantine-after.txt" ]]
