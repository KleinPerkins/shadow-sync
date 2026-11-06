#!/usr/bin/env python3
"""Trusted workflow_run handler for ordinary PRs; dependency PRs have their own policy."""
import json
import os
from pathlib import Path
import sys

from github_automation import (REPO, SHA, AutomationError, Reporter, api, pages, same_repo_pr,
                               dependabot_author, reviewer_identity, approve_and_arm, enable_merge,
                               complete_changed_files, protected_files)



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
    return bool(files) and not protected_files(files)


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
