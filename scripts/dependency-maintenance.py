#!/usr/bin/env python3
"""Reconcile real Dependabot PRs of every update size; never publish releases."""
import os
import sys

from github_automation import (REPO, AutomationError, SHA, api, pages, dependency_pr,
                               ci_passed, reviewer_identity, approve_and_arm, enable_merge, Reporter)


def reconcile(*, request=api, merge=enable_merge, report=None, read_token, reviewer_login):
    report = report or Reporter()
    candidates = pages(request, f'repos/{REPO}/pulls?state=open&base=main&per_page=100')
    eligible = [pr for pr in candidates if dependency_pr(pr)]
    report(f'Inspected {len(candidates)} open main-target PR(s); {len(eligible)} eligible Dependabot update(s). Patch, minor and major updates share the same policy.')
    if not eligible:
        return 0
    reviewer = reviewer_identity(request, reviewer_login)
    failures = 0
    for candidate in eligible:
        number = candidate['number']
        try:
            path = f'repos/{REPO}/pulls/{number}'
            pr = request(path)
            if not dependency_pr(pr):
                report(f'PR #{number}: no longer eligible; skipped.')
                continue
            sha = pr['head']['sha']
            main_sha = request(f'repos/{REPO}/git/ref/heads/main')['object']['sha']
            if not SHA.fullmatch(main_sha):
                raise AutomationError('Invalid main revision')
            comparison = request(f'repos/{REPO}/compare/{main_sha}...{sha}')
            behind = comparison.get('behind_by')
            if type(behind) is not int or behind < 0:
                raise AutomationError('GitHub comparison did not report a valid behind count')
            # Repeat identity/head validation immediately before a possible write.
            latest = request(path)
            if not dependency_pr(latest) or latest['head']['sha'] != sha:
                report(f'PR #{number}: identity or head changed during inspection; deferred.')
                continue
            if behind:
                request(path + '/update-branch', method='PUT', payload={'expected_head_sha': sha})
                report(f'PR #{number}: branch refresh requested with expected head {sha}; waiting for new-commit CI.')
                continue
            if latest.get('mergeable') is False:
                raise AutomationError('Branch conflicts with main; no automatic code repair')
            if not ci_passed(sha, request, read_token):
                report(f'PR #{number}: waiting for successful current-commit ci-required.')
                continue
            if request(f'repos/{REPO}/git/ref/heads/main')['object']['sha'] != main_sha:
                report(f'PR #{number}: main changed during inspection; deferred to the next pass.')
                continue
            approve_and_arm(latest, request=request, merge=merge, reviewer=reviewer,
                            eligible=dependency_pr, read_token=read_token, report=report)
        except Exception as error:
            failures += 1
            # Our errors contain only controlled operation/status text. Never dump
            # arbitrary server responses, subprocess arguments, or PR body/title.
            reason = str(error) if isinstance(error, AutomationError) else type(error).__name__
            report(f'PR #{number}: {reason}', error=True)
    report(f'Dependency maintenance completed: {len(eligible)} candidate(s), {failures} failed operation(s).')
    return failures


def main():
    report = Reporter(os.environ.get('GITHUB_STEP_SUMMARY'))
    try:
        if os.environ.get('GITHUB_REPOSITORY') != REPO or os.environ.get('GITHUB_REF') != 'refs/heads/main':
            raise AutomationError('Dependency maintenance requires the trusted main workflow')
        if not os.environ.get('GH_TOKEN') or not os.environ.get('CI_READ_TOKEN'):
            raise AutomationError('Missing App mutation token or read-only CI token')
        return 1 if reconcile(report=report, read_token=os.environ['CI_READ_TOKEN'],
                              reviewer_login=os.environ.get('REVIEWER_LOGIN', '')) else 0
    except Exception as error:
        reason = str(error) if isinstance(error, AutomationError) else type(error).__name__
        report('Dependency maintenance failed: ' + reason, error=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
