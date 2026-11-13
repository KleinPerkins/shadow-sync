#!/usr/bin/env python3
"""Trusted-main ordinary PR handler; exclusive owner author, no protected-path bypass."""
import fnmatch
import json
import os
from pathlib import Path
import sys

from github_automation import (REPO, SHA, AutomationError, Reporter, api, pages, same_repo_pr,
                               owner_author, reviewer_identity, approve_and_arm, enable_merge,
                               trusted_context, verify_run, repository_identity)
from merge_controls import verify_live_controls

PROTECTED = (
    'delivery/*', 'docs/*', '.planning/*', '.githooks/*', '.gitignore',
    '.codex/*', '.cursor/*', '.claude/*', '.agents/*', 'THIRD_PARTY_NOTICES.md',
    '.github/*', '.gitleaks*', '_ops/*', 'Makefile', 'AGENTS.md', 'SECURITY.md',
    'LICENSE*', 'CODEOWNERS', 'scripts/*', 'Configuration/*', 'Package.*',
    'VERSION', 'BUILD_NUMBER', 'release-please*', '.release-please*',
    '*.xcodeproj/*', '*.xcworkspace/*', '*.entitlements',
    'install.sh', 'Resources/*.plist.template', 'Resources/command-graphs.json',
    'Resources/Info.plist', 'Resources/*contract*.json', 'Resources/*release*.json',
    'Resources/PolicyAdapter.py', 'Resources/*appcast*',
    'Sources/ShadowSyncLifecycleCoordinator/*', 'Sources/ShadowSyncUpdateSupport/*',
    'Sources/ShadowSyncApp/AppUpdater.swift',
    'Sources/ShadowSyncApp/AppLifecycleRouter.swift', 'Sources/ShadowSyncApp/LifecycleMain.swift',
    'Sources/ShadowSyncCore/InstallationLifecycle.swift', 'Sources/ShadowSyncCore/HostControl.swift',
    'Sources/ShadowSyncCore/ReleaseIdentity.swift', 'Sources/ShadowSyncCore/SecureState.swift',
    'Sources/ShadowSyncCore/RepositoryAuthorityStore.swift', 'Sources/ShadowSyncCore/RepositoryPolicy.swift',
    'Sources/ShadowSyncCatalog/RepositorySelectionPolicy.swift',
    # Installation/policy authority extends beyond the original extraction files.
    # Protect the closed families so adding a coordinator or custody seam does
    # not accidentally make protected administration an ordinary App change.
    'Sources/ShadowSyncCore/Installation*.swift', 'Sources/ShadowSyncCore/Lifecycle*.swift',
    'Sources/ShadowSyncCore/LegacyInstallationRelease.swift',
    'Sources/ShadowSyncCore/FreshStateInitialization.swift',
    'Sources/ShadowSyncCore/Custody*.swift', 'Sources/ShadowSyncCore/CommandCustod*.swift',
    'Sources/ShadowSyncCore/RetainedCleanupRegistry.swift',
    'Sources/ShadowSyncCore/Publisher*.swift', 'Sources/ShadowSyncCore/Policy*.swift',
    'Sources/ShadowSyncCore/HostPolicy*.swift',
    'Resources/source-export.json', 'config/*',
    'Tests/ShadowSyncSelfTests/*', 'Tests/Fixtures/production-test-markers.json',
)


def complete_changed_files(pr, entries):
    """Reject incomplete, duplicate or malformed file evidence before approval."""
    count = pr.get('changed_files')
    if type(count) is not int or not 0 < count <= 3000 or len(entries) != count:
        raise AutomationError('Incomplete changed-file evidence')
    files, current = [], set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise AutomationError('Malformed changed-file evidence')
        name = entry.get('filename')
        status = entry.get('status')
        if status not in ('added', 'removed', 'modified', 'renamed', 'copied', 'changed', 'unchanged'):
            raise AutomationError('Missing or invalid changed-file status')
        if status == 'renamed' and 'previous_filename' not in entry:
            raise AutomationError('Missing renamed-file origin')
        names = [name]
        if 'previous_filename' in entry:
            names.append(entry['previous_filename'])
        for value in names:
            if (not isinstance(value, str) or not value or value.startswith('/')
                    or '\\' in value or any(ord(char) < 32 or ord(char) == 127 for char in value)
                    or any(part in ('', '.', '..') for part in value.split('/'))):
                raise AutomationError('Unsafe changed-file path')
        if name in current:
            raise AutomationError('Duplicate changed-file evidence')
        current.add(name)
        files.extend(names)
    return files


def immutable_changed_files(pr, request):
    if not same_repo_pr(pr):
        raise AutomationError('Immutable same-repository base/head required')
    base, head = pr['base']['sha'], pr['head']['sha']
    # Compare lists at most 300 files. Refuse the boundary and larger PRs rather
    # than accepting possibly truncated evidence. No author bypass is permitted.
    count = pr.get('changed_files')
    if type(count) is not int or not 0 < count < 300:
        raise AutomationError('Change exceeds immutable comparison coverage')
    observed = request(f'repos/{REPO}/compare/{base}...{head}')
    if (not isinstance(observed, dict) or observed.get('base_commit', {}).get('sha') != base
            or observed.get('merge_base_commit', {}).get('sha') != base
            or observed.get('status') != 'ahead' or observed.get('behind_by') != 0
            or type(observed.get('behind_by')) is not int):
        raise AutomationError('Current-base comparison identity mismatch')
    entries = observed.get('files')
    if not isinstance(entries, list):
        raise AutomationError('Immutable changed-file evidence unavailable')
    return base, complete_changed_files(pr, entries)


def eligible(pr, run, files, *, base_sha):
    if (run.get('event') != 'pull_request' or run.get('conclusion') != 'success'
            or run.get('path') != '.github/workflows/ci.yml'
            or not repository_identity(run.get('head_repository')) or not same_repo_pr(pr)
            or not owner_author(pr)):
        return False
    if pr['head']['sha'] != run.get('head_sha') or pr['base']['sha'] != base_sha:
        return False
    if pr['head'].get('ref', '').startswith(('release-please--', 'dependabot/')):
        return False
    # Git paths are case-sensitive, but the supported Mac filesystem may not be.
    return bool(files) and not any(fnmatch.fnmatchcase(path.casefold(), pattern.casefold())
                                  for path in files for pattern in PROTECTED)


def main():
    report = Reporter(os.environ.get('GITHUB_STEP_SUMMARY'))
    failures = 0
    try:
        source_sha = trusted_context(os.environ, mode='ordinary')
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        read_token = os.environ.get('CI_READ_TOKEN', '')
        run = verify_run(event, api, read_token, mode='ordinary')
        verify_live_controls(api, source_sha)
        candidates = pages(api, f"repos/{REPO}/commits/{run['head_sha']}/pulls?per_page=100")
        for candidate in candidates:
            number = candidate.get('number')
            if type(number) is not int or number <= 0:
                raise AutomationError('Invalid pull request number')
            try:
                pr = api(f'repos/{REPO}/pulls/{number}')
                if not same_repo_pr(pr) or not owner_author(pr):
                    report(f'PR #{number}: outside the exclusive ordinary-author policy; skipped.')
                    continue
                base_sha, files = immutable_changed_files(pr, api)
                if base_sha != source_sha or not eligible(pr, run, files, base_sha=base_sha):
                    report(f'PR #{number}: protected paths, stale source or ineligible state; skipped.')
                    continue
                reviewer = reviewer_identity(api, os.environ.get('REVIEWER_LOGIN', ''),
                                              os.environ.get('REVIEWER_INSTALLATION_ID', ''))

                def controls():
                    if trusted_context(os.environ, mode='ordinary') != source_sha:
                        raise AutomationError('Trusted source changed')
                    verify_run(event, api, read_token, mode='ordinary')
                    reviewer_identity(api, os.environ.get('REVIEWER_LOGIN', ''),
                                      os.environ.get('REVIEWER_INSTALLATION_ID', ''))
                    verify_live_controls(api, base_sha)

                approve_and_arm(pr, request=api, merge=enable_merge, reviewer=reviewer,
                                eligible=lambda latest: eligible(latest, run, files, base_sha=base_sha)
                                and type(latest.get('changed_files')) is int
                                and latest['changed_files'] == pr['changed_files'],
                                read_token=read_token, report=report, controls=controls,
                                check_suite_id=run['check_suite_id'])
            except Exception as error:
                failures += 1
                reason = str(error) if isinstance(error, AutomationError) else type(error).__name__
                report(f'PR #{number}: {reason}', error=True)
        return 1 if failures else 0
    except Exception as error:
        reason = str(error) if isinstance(error, AutomationError) else type(error).__name__
        report('Ordinary PR automation failed: ' + reason, error=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
