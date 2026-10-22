#!/usr/bin/env python3
"""Confirm only the observed notarized-app first-open prompt on a disposable runner."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
APP = Path('/Applications/MacSweep.app')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def checked(command, log, timeout=60):
    with log.open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout, check=True)


def authorize(evidence):
    aligned = json.loads((evidence / 'installed-alignment.json').read_text())
    metadata = json.loads((evidence / 'metadata.json').read_text())
    signature = (evidence / 'signature.txt').read_text()
    assessment = (evidence / 'gatekeeper-assessment.txt').read_text()
    require(aligned['appAndCLIAligned'] is True and metadata['metadataAligned'] is True, 'Version alignment missing')
    require(aligned['version'] == metadata['version'], 'Installed version drift')
    require('Authority=Developer ID Application:' in signature and 'Timestamp=' in signature, 'Signature gate missing')
    require('runtime' in signature and 'source=Notarized Developer ID' in assessment, 'Notarization gate missing')
    require('/Applications/MacSweep.app: accepted' in assessment, 'Gatekeeper did not accept the installed app')
    require('The validate action worked!' in (evidence / 'stapler.txt').read_text(), 'Stapled ticket gate missing')
    require((evidence / 'quarantine-before.txt').read_text().strip(), 'Quarantine evidence missing')
    require(os.getxattr(APP, 'com.apple.quarantine'), 'Current quarantine missing')
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == 'dev.macsweep.app', 'Installed bundle identity changed')
    require(info['CFBundleShortVersionString'] == info['CFBundleVersion'] == metadata['version'], 'App version changed')
    team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', signature, re.MULTILINE)
    require(team is not None, 'Verified Developer ID team missing')
    data = (APP / 'Contents/MacOS/MacSweep').read_bytes()
    authorization = {'appPath': str(APP), 'executableSHA256': hashlib.sha256(data).hexdigest(),
                     'version': metadata['version'], 'teamIdentifier': team[1], 'verified': True}
    (evidence / 'first-open-authorization.json').write_text(json.dumps(authorization, indent=2) + '\n')


def prepare_xctest(evidence):
    project = ROOT / 'scripts/FirstOpenUI/FirstOpenUI.xcodeproj'
    derived = evidence.parent / 'macsweep-first-open-ui-derived'
    # Read-only preflight. Modern macOS may not expose the legacy debug right;
    # that alone does not establish whether XCTest's native UI service works.
    with (evidence / 'developer-tools-status.txt').open('w') as output:
        subprocess.run(['/usr/sbin/DevToolsSecurity', '-status'], stdout=output,
                       stderr=subprocess.STDOUT, timeout=10, check=False)
    require('currently disabled' not in (evidence / 'developer-tools-status.txt').read_text().lower(),
            'Developer tools access is disabled; no administrator prompt will be requested')
    checked(['xcodebuild', 'build-for-testing', '-project', str(project), '-scheme', 'FirstOpenUITests',
             '-destination', 'platform=macOS', '-derivedDataPath', str(derived)],
            evidence / 'first-open-ui-build.log', timeout=120)
    runs = list((derived / 'Build/Products').glob('*.xctestrun'))
    require(len(runs) == 1, 'Expected one dedicated UI test run specification')
    run = plistlib.loads(runs[0].read_bytes())
    target = run['FirstOpenUITests']
    target.setdefault('EnvironmentVariables', {}).update(
        GITHUB_ACTIONS='true', RUNNER_ENVIRONMENT='github-hosted', MACSWEEP_ACCEPTANCE_EVIDENCE=str(evidence))
    target['TestExecutionOrdering'] = 'alphabetical'
    run_path = runs[0].parent / 'MacSweepFirstOpen.xctestrun'
    run_path.write_bytes(plistlib.dumps(run))
    return ['xcodebuild', 'test-without-building', '-xctestrun', str(run_path),
            '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', str(evidence / 'first-open-ui.xcresult')]


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise RuntimeError('First-open UI interaction requires the disposable GitHub-hosted runner')
    require(len(sys.argv) == 2, 'Usage: first-open.py EVIDENCE')
    evidence = Path(sys.argv[1]).resolve()
    require(evidence.is_relative_to(Path(os.environ['RUNNER_TEMP']).resolve()), 'Evidence must be runner-owned')
    authorize(evidence)
    helper = evidence / 'first-open-ax'
    checked(['xcrun', 'swiftc', '-parse-as-library', str(ROOT / 'scripts/FirstOpenPolicy.swift'),
             str(ROOT / 'scripts/FirstOpenAX.swift'), '-o', str(helper)], evidence / 'first-open-ax-build.log')
    capabilities = subprocess.run([str(helper), '--capabilities'], capture_output=True, text=True,
                                  timeout=10, check=True)
    (evidence / 'ui-capabilities.json').write_text(capabilities.stdout)
    available = json.loads(capabilities.stdout)
    require(type(available['accessibilityTrusted']) is bool, 'Unknown Accessibility capability')
    backend = 'accessibility' if available['accessibilityTrusted'] else 'xctest'
    command = [str(helper), str(evidence)] if backend == 'accessibility' else prepare_xctest(evidence)
    (evidence / 'first-open-backend.json').write_text(json.dumps({'backend': backend, 'accessibilityPromptRequested': False, 'uiTestAuthorizationManagedBySystem': backend == 'xctest'}) + '\n')
    with (evidence / 'launch-services.log').open('w') as log:
        request = subprocess.Popen(['/usr/bin/open', '-n', '--stdout', str(evidence / 'app-stdout.txt'),
                                    '--stderr', str(evidence / 'app-stderr.txt'), str(APP)], stdout=log, stderr=log)
        try:
            checked(command, evidence / 'first-open-confirmation.log', timeout=150)
            request.wait(timeout=20)
            require(request.returncode == 0, 'Launch Services request failed after confirmation')
        finally:
            if request.poll() is None:
                # This is our pending open-request client, not MacSweep or a system agent.
                request.terminate()
                request.wait(timeout=5)


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, KeyError, RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'Normal first-open confirmation failed: {error}', file=sys.stderr)
        sys.exit(1)
