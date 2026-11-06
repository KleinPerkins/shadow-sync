#!/usr/bin/env python3
"""Trusted workflow_run handler for ordinary PRs; dependency PRs have their own policy."""
import fnmatch
import json
import os
from pathlib import Path
import sys

from github_automation import (REPO, SHA, AutomationError, Reporter, api, pages, same_repo_pr,
                               dependabot_author, reviewer_identity, approve_and_arm, enable_merge)

PROTECTED = (
    '.github/*', '.gitleaks*', '_ops/*', 'Makefile', 'AGENTS.md', 'SECURITY.md',
    'LICENSE*', 'CODEOWNERS', 'scripts/*', 'Configuration/*', 'Package.*',
    'VERSION', 'BUILD_NUMBER', 'release-please*', '.release-please*',
    '*.xcodeproj/*', '*.xcworkspace/*', '*.entitlements',
    'Resources/Info.plist', 'Resources/*contract*.json', 'Resources/*release*.json',
    'Resources/PolicyAdapter.py', 'Resources/*appcast*',
    'Sources/ShadowSyncLifecycleCoordinator/*', 'Sources/ShadowSyncUpdateSupport/*',
    'Sources/ShadowSyncApp/AppUpdater.swift',
    'Sources/ShadowSyncApp/AppLifecycleRouter.swift', 'Sources/ShadowSyncApp/LifecycleMain.swift',
    'Sources/ShadowSyncCore/InstallationLifecycle.swift', 'Sources/ShadowSyncCore/HostControl.swift',
    'Sources/ShadowSyncCore/ReleaseIdentity.swift', 'Sources/ShadowSyncCore/SecureState.swift',
    'Sources/ShadowSyncCore/RepositoryAuthorityStore.swift', 'Sources/ShadowSyncCore/RepositoryPolicy.swift',
    'Sources/ShadowSyncCatalog/RepositorySelectionPolicy.swift',
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


def eligible(pr, run, files):
    if run.get('event') != 'pull_request' or run.get('conclusion') != 'success':
        return False
    if run.get('head_repository', {}).get('full_name') != REPO or not same_repo_pr(pr):
        return False
    if pr['head']['sha'] != run.get('head_sha'):
        return False
    if pr['head'].get('ref', '').startswith(('release-please--', 'dependabot/')) or dependabot_author(pr):
        return False
    if pr.get('author_association') not in ('OWNER', 'MEMBER', 'COLLABORATOR'):
        return False
    return bool(files) and not any(fnmatch.fnmatchcase(path, pattern) for path in files for pattern in PROTECTED)


def main():
    report = Reporter(os.environ.get('GITHUB_STEP_SUMMARY'))
    failures = 0
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        run = event['workflow_run']
        if event['repository']['full_name'] != REPO:
            raise AutomationError('Unexpected repository')
        if run.get('event') != 'pull_request' or run.get('conclusion') != 'success':
            return 0
        if not SHA.fullmatch(run.get('head_sha', '')):
            raise AutomationError('Invalid workflow commit SHA')
        candidates = pages(api, f"repos/{REPO}/commits/{run['head_sha']}/pulls?per_page=100")
        reviewer = None
        for candidate in candidates:
            number = candidate.get('number')
            if type(number) is not int or number <= 0:
                raise AutomationError('Invalid pull request number')
            try:
                path = f'repos/{REPO}/pulls/{number}'
                pr = api(path)
                # Author identity, not the actor of a synchronize/CI event, routes
                # Dependabot out of this ordinary-PR policy.
                if dependabot_author(pr):
                    report(f'PR #{number}: Dependabot maintenance owns this PR; skipped.')
                    continue
                entries = pages(api, path + '/files?per_page=100')
                files = complete_changed_files(pr, entries)
                if not eligible(pr, run, files):
                    report(f'PR #{number}: manual review, ineligible identity or newer head; skipped.')
                    continue
                if reviewer is None:
                    reviewer = reviewer_identity(api, os.environ.get('REVIEWER_LOGIN', ''))
                approve_and_arm(pr, request=api, merge=enable_merge, reviewer=reviewer,
                                eligible=lambda latest: eligible(latest, run, files),
                                read_token=os.environ.get('CI_READ_TOKEN', ''), report=report)
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
