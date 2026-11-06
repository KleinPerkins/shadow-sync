"""Shared, dependency-free GitHub App transport and exact-head policy gates."""
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess

REPO = 'KleinPerkins/shadow-sync'
DEPENDABOT_ID = 49699333
ACTIONS_APP_ID = 15368
SHA = re.compile(r'[a-f0-9]{40}')


class AutomationError(RuntimeError):
    pass


def api(path, *, payload=None, token=None, paginate=False, method=None):
    args = ['gh', 'api', path]
    if paginate:
        args += ['--paginate', '--slurp']
    if method or payload is not None:
        args += ['--method', method or 'POST']
    if payload is not None:
        args += ['--input', '-']
    env = dict(os.environ)
    if token is not None:
        if not token:
            raise AutomationError('Missing read-only CI token')
        env['GH_TOKEN'] = token
    result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, env=env)
    if result.returncode:
        status = re.search(r'HTTP \d{3}', result.stderr)
        # Avoid raw server/CLI output or command arguments containing credentials.
        reason = status.group() if status else f'CLI exit {result.returncode}'
        raise AutomationError(f'{method or ("POST" if payload is not None else "GET")} {path.split("?")[0]} failed ({reason})')
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise AutomationError('GitHub returned an invalid JSON response') from None


def pages(request, path, *, token=None, key=None):
    batches = request(path, paginate=True, **({'token': token} if token is not None else {}))
    if not isinstance(batches, list):
        raise AutomationError('Malformed paginated GitHub response')
    result = []
    for batch in batches:
        values = batch.get(key) if key and isinstance(batch, dict) else batch
        if not isinstance(values, list):
            raise AutomationError('Malformed GitHub result page')
        result.extend(values)
    return result


def same_repo_pr(pr):
    head, base = pr.get('head') or {}, pr.get('base') or {}
    return (pr.get('state') == 'open' and pr.get('draft') is False
            and type(pr.get('number')) is int and pr['number'] > 0
            and base.get('ref') == 'main'
            and (base.get('repo') or {}).get('full_name') == REPO
            and (head.get('repo') or {}).get('full_name') == REPO
            and isinstance(head.get('sha'), str) and SHA.fullmatch(head['sha']) is not None)


def dependabot_author(pr):
    user = pr.get('user') or {}
    return user.get('login') == 'dependabot[bot]' or user.get('id') == DEPENDABOT_ID


def dependency_pr(pr):
    user = pr.get('user') or {}
    return (same_repo_pr(pr) and user.get('login') == 'dependabot[bot]'
            and user.get('id') == DEPENDABOT_ID and user.get('type') == 'Bot'
            and pr['head'].get('ref', '').startswith('dependabot/'))


PROTECTED = (
    'install.sh', '*.lock', 'Resources/*.plist*',
    'Sources/ShadowSyncCore/QualifiedCommandGraph.swift',
    'Sources/ShadowSyncCore/RetainedCleanupRegistry.swift', 'Sources/ShadowSyncCore/Owned*',
    'config/*', '.planning/*', 'docs/adr/*', 'THIRD_PARTY_NOTICES.md',
    'Resources/policy*', 'Resources/command-graphs.json', 'Resources/PolicyRuntimeNotices/*',
    'Sources/ShadowSyncCore/Lifecycle*', 'Sources/ShadowSyncCore/Custody*',
    'Sources/ShadowSyncCore/CommandCust*', 'Sources/ShadowSyncCore/DiscoveryCustody*',
    'Sources/ShadowSyncCore/ClosedProcess*', 'Sources/ShadowSyncCore/Policy*',
    'Sources/ShadowSyncCore/HostPolicy*', 'Sources/ShadowSyncCore/PublisherPolicy*',
    'Sources/ShadowSyncCore/FreshStateInitialization.swift',
    'Sources/ShadowSyncCore/LegacyInstallationRelease.swift',
    'Sources/ShadowSyncCore/ProcessOwnership.swift', 'Sources/ShadowSyncCore/ProcessRunner.swift',
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


def protected_files(files):
    return any(fnmatch.fnmatchcase(path, pattern) for path in files for pattern in PROTECTED)


def ci_passed(sha, request, read_token):
    """Bind the required Check to this repository's current CI workflow attempt."""
    if not SHA.fullmatch(sha) or not read_token:
        raise AutomationError('Expected a commit SHA and read-only CI token')
    checks = pages(request, f'repos/{REPO}/commits/{sha}/check-runs?check_name=ci-required&filter=latest&per_page=100',
                   token=read_token, key='check_runs')
    gates = [check for check in checks if check.get('name') == 'ci-required'
             and check.get('app', {}).get('id') == ACTIONS_APP_ID]
    if len(gates) != 1:
        return False
    gate = gates[0]
    if not (gate.get('head_sha') == sha and gate.get('status') == 'completed'
            and gate.get('conclusion') == 'success' and type(gate.get('id')) is int):
        return False
    if not isinstance(gate.get('details_url'), str):
        return False
    match = re.fullmatch(r'https://github[.]com/' + re.escape(REPO)
                         + r'/actions/runs/([1-9][0-9]*)/job/([1-9][0-9]*)', gate.get('details_url', ''))
    if match is None or int(match[2]) != gate['id']:
        return False
    run_id, job_id = map(int, match.groups())
    read = lambda path: request(f'repos/{REPO}/' + path, token=read_token)
    workflow = read('actions/workflows/ci.yml')
    run = read(f'actions/runs/{run_id}')
    attempt = run.get('run_attempt')
    suite_id = gate.get('check_suite', {}).get('id')
    if not (type(workflow.get('id')) is int and workflow.get('path') == '.github/workflows/ci.yml'
            and workflow.get('state') == 'active'
            and run.get('id') == run_id and run.get('workflow_id') == workflow['id']
            and run.get('path') == workflow['path'] and run.get('event') == 'pull_request'
            and run.get('head_sha') == sha and run.get('head_repository', {}).get('full_name') == REPO
            and run.get('status') == 'completed' and run.get('conclusion') == 'success'
            and type(attempt) is int and attempt > 0
            and type(suite_id) is int and suite_id > 0 and run.get('check_suite_id') == suite_id):
        return False
    jobs = pages(request, f'repos/{REPO}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100',
                 token=read_token, key='jobs')
    required = [job for job in jobs if job.get('name') == 'ci-required']
    if len(required) != 1:
        return False
    job = required[0]
    return (all(type(job.get(key)) is int for key in ('id', 'run_id', 'run_attempt'))
            and job.get('id') == job_id and job.get('run_id') == run_id
            and job.get('run_attempt') == attempt and job.get('head_sha') == sha
            and job.get('status') == 'completed' and job.get('conclusion') == 'success'
            and job.get('check_run_url') == f'https://api.github.com/repos/{REPO}/check-runs/{gate["id"]}')


def reviewer_identity(request, login):
    if not re.fullmatch(r'[a-z0-9-]+\[bot\]', login or ''):
        raise AutomationError('Missing installed App reviewer identity')
    reviewer = request(f'users/{login}')
    if reviewer.get('login') != login or reviewer.get('type') != 'Bot' or type(reviewer.get('id')) is not int:
        raise AutomationError('Installed App reviewer identity could not be verified')
    return reviewer


def already_approved(pr_number, sha, request, reviewer):
    reviews = pages(request, f'repos/{REPO}/pulls/{pr_number}/reviews?per_page=100')
    own = [review for review in reviews if review.get('user', {}).get('id') == reviewer['id']
           and review.get('user', {}).get('login') == reviewer['login'] and review.get('state') != 'COMMENTED']
    latest = max(own, key=lambda review: review['id'], default={})
    return latest.get('state') == 'APPROVED' and latest.get('commit_id') == sha


def enable_merge(number, sha):
    result = subprocess.run(['gh', 'pr', 'merge', str(number), '--repo', REPO,
                             '--auto', '--squash', '--match-head-commit', sha], capture_output=True, text=True)
    if result.returncode:
        raise AutomationError(f'PR #{number}: native auto-merge failed (exit {result.returncode}); check permissions, head changes and branch rules')


def approve_and_arm(pr, *, request, merge, reviewer, eligible, read_token, report):
    number, sha = pr['number'], pr['head']['sha']
    path = f'repos/{REPO}/pulls/{number}'
    approved = already_approved(number, sha, request, reviewer)
    latest = request(path)
    if not eligible(latest) or latest['head']['sha'] != sha:
        report(f'PR #{number}: identity or head changed; deferred.')
        return
    if not ci_passed(sha, request, read_token):
        report(f'PR #{number}: current-commit ci-required is not successful; waiting.')
        return
    if not approved:
        request(path + '/reviews', payload={'event': 'APPROVE', 'commit_id': sha,
                'body': 'Policy-based automatic approval: required CI passed for this commit. This is not substantive code review.'})
    latest = request(path)
    if not eligible(latest) or latest['head']['sha'] != sha:
        report(f'PR #{number}: changed after approval; merge not armed.')
        return
    if latest.get('auto_merge') is None:
        merge(number, sha)
        report(f'PR #{number}: policy approval recorded; native squash auto-merge requested for {sha}.')
    else:
        if latest['auto_merge'].get('merge_method', '').lower() != 'squash':
            raise AutomationError(f'PR #{number}: existing auto-merge is not squash')
        report(f'PR #{number}: current commit already approved and squash auto-merge enabled.')


class Reporter:
    def __init__(self, summary=None):
        self.summary = Path(summary) if summary else None

    def __call__(self, message, *, error=False):
        if error:
            escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
            print('::error::' + escaped)
        else:
            print(message)
        if self.summary:
            with self.summary.open('a') as output:
                output.write(('- ERROR: ' if error else '- ') + message.replace('\n', ' ').replace('\r', ' ') + '\n')

