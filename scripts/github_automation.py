"""Shared, dependency-free GitHub App transport and exact-head policy gates."""
import json
import os
from pathlib import Path
import re
import subprocess

REPO = 'KleinPerkins/shadow-sync'
REPOSITORY_ID = 1442961455
OWNER_LOGIN = 'KleinPerkins'
OWNER_ID = 49759187
REVIEWER_APP_ID = 4217367
REVIEWER_SLUG = 'chaos-scheduler-automerge'
REVIEWER_LOGIN = REVIEWER_SLUG + '[bot]'
REVIEWER_BOT_ID = 299927791
REVIEWER_INSTALLATION_ID = 144433991
CI_PATH = '.github/workflows/ci.yml'
WORKFLOW_PATH = '.github/workflows/app-auto-merge.yml'
DEPENDABOT_ID = 49699333
ACTIONS_APP_ID = 15368
SHA = re.compile(r'[a-f0-9]{40}')


class AutomationError(RuntimeError):
    pass


def api(path, *, payload=None, token=None, paginate=False, method=None):
    args = ['gh', 'api', '--hostname', 'github.com', path]
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
                            text=True, capture_output=True, env=env, timeout=30)
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


def owner_author(pr):
    user = pr.get('user') or {}
    return (user.get('login') == OWNER_LOGIN and type(user.get('id')) is int
            and user['id'] == OWNER_ID and user.get('type') == 'User')


def repository_identity(value):
    return (isinstance(value, dict) and value.get('full_name') == REPO
            and type(value.get('id')) is int and value['id'] == REPOSITORY_ID)


def same_repo_pr(pr):
    head, base = pr.get('head') or {}, pr.get('base') or {}
    return (pr.get('state') == 'open' and pr.get('draft') is False
            and type(pr.get('number')) is int and pr['number'] > 0
            and base.get('ref') == 'main'
            and repository_identity(base.get('repo')) and repository_identity(head.get('repo'))
            and all(isinstance(side.get('sha'), str) and SHA.fullmatch(side['sha'])
                    for side in (head, base)))


def dependabot_author(pr):
    user = pr.get('user') or {}
    return user.get('login') == 'dependabot[bot]' or user.get('id') == DEPENDABOT_ID


def dependency_pr(pr):
    # Exclusive ordinary-author policy: dependency automation has no write route.
    # Keep this admission function for callers of the staged maintenance script.
    return False


def ci_passed(sha, request, read_token, *, check_suite_id=None):
    if not SHA.fullmatch(sha) or not read_token:
        raise AutomationError('Expected a commit SHA and read-only CI token')
    checks = pages(request, f'repos/{REPO}/commits/{sha}/check-runs?check_name=ci-required&filter=latest&per_page=100',
                   token=read_token, key='check_runs')
    # A similarly named check from a different App cannot satisfy this policy.
    gates = [check for check in checks if check.get('name') == 'ci-required'
             and check.get('app', {}).get('id') == ACTIONS_APP_ID]
    return bool(gates) and all(check.get('head_sha') == sha and check.get('status') == 'completed'
                               and check.get('conclusion') == 'success'
                               and (check_suite_id is None or
                                    check.get('check_suite', {}).get('id') == check_suite_id)
                               for check in gates)


def reviewer_identity(request, login, installation_id):
    # The trusted pinned token action signs for the fixed App ID and supplies
    # these outputs. Public bot lookup alone is not proof of token issuance.
    if login != REVIEWER_LOGIN or installation_id != str(REVIEWER_INSTALLATION_ID):
        raise AutomationError('Unexpected reviewer App or installation')
    app = request(f'apps/{REVIEWER_SLUG}')
    if (type(app.get('id')) is not int or app['id'] != REVIEWER_APP_ID
            or app.get('slug') != REVIEWER_SLUG or not owner_author({'user': app.get('owner')})):
        raise AutomationError('Reviewer App identity mismatch')
    if app.get('permissions') != {'contents': 'write', 'pull_requests': 'write', 'metadata': 'read'}:
        raise AutomationError('Reviewer App permission contract changed')
    reviewer = request(f'users/{login}')
    if (reviewer.get('login') != REVIEWER_LOGIN or reviewer.get('type') != 'Bot'
            or type(reviewer.get('id')) is not int or reviewer['id'] != REVIEWER_BOT_ID):
        raise AutomationError('Reviewer bot identity mismatch')
    scope = request('installation/repositories?per_page=100')
    repositories = scope.get('repositories')
    if (type(scope.get('total_count')) is not int or scope['total_count'] != 1
            or not isinstance(repositories, list) or len(repositories) != 1
            or not repository_identity(repositories[0])):
        raise AutomationError('Reviewer token must be scoped to this repository only')
    return reviewer


def trusted_context(environment, *, mode):
    if mode not in ('ordinary', 'qualify'):
        raise AutomationError('Invalid reviewer mode')
    switch = 'REVIEWER_APP_ENABLED' if mode == 'ordinary' else 'REVIEWER_APP_QUALIFY'
    sha = environment.get('TRUSTED_WORKFLOW_SHA', '')
    if (not environment.get('GH_TOKEN') or environment.get(switch) != 'true'
            or environment.get('GITHUB_ACTIONS') != 'true'
            or environment.get('GITHUB_EVENT_NAME') != 'workflow_run'
            or environment.get('GITHUB_REPOSITORY') != REPO
            or environment.get('GITHUB_REPOSITORY_ID') != str(REPOSITORY_ID)
            or environment.get('GITHUB_REF') != 'refs/heads/main'
            or environment.get('GITHUB_WORKFLOW_REF') != f'{REPO}/{WORKFLOW_PATH}@refs/heads/main'
            or not SHA.fullmatch(sha) or sha == '0' * 40
            or environment.get('GITHUB_SHA') != sha):
        raise AutomationError('Enabled trusted-main workflow context required')
    if (environment.get('REVIEWER_LOGIN') != REVIEWER_LOGIN
            or environment.get('REVIEWER_INSTALLATION_ID') != str(REVIEWER_INSTALLATION_ID)):
        raise AutomationError('Unexpected reviewer issuance context')
    return sha


def verify_run(event, request, read_token, *, mode):
    run = event.get('workflow_run') or {}
    if not repository_identity(event.get('repository')):
        raise AutomationError('Unexpected event repository')
    number = run.get('id')
    if type(number) is not int or number <= 0 or not read_token:
        raise AutomationError('Missing CI run identity or read token')
    latest = request(f'repos/{REPO}/actions/runs/{number}', token=read_token)
    fields = ('id', 'head_sha', 'path', 'event', 'check_suite_id', 'run_attempt', 'head_branch')
    if any(run.get(field) != latest.get(field) for field in fields):
        raise AutomationError('CI run changed or event identity mismatch')
    for value in (run, latest):
        if (not repository_identity(value.get('head_repository'))
                or not repository_identity(value.get('repository'))
                or value.get('path') != CI_PATH or value.get('status') != 'completed'
                or value.get('conclusion') != 'success'
                or not isinstance(value.get('head_sha'), str) or not SHA.fullmatch(value['head_sha'])
                or type(value.get('check_suite_id')) is not int or value['check_suite_id'] <= 0
                or type(value.get('run_attempt')) is not int or value['run_attempt'] <= 0):
            raise AutomationError('Successful exact CI workflow identity required')
    if mode == 'ordinary':
        if run['event'] != 'pull_request':
            raise AutomationError('Pull-request CI required')
    elif mode != 'qualify' or run['event'] not in ('push', 'workflow_dispatch') or run['head_branch'] != 'main':
        raise AutomationError('Successful main-branch CI required')
    return latest


def already_approved(pr_number, sha, request, reviewer):
    reviews = pages(request, f'repos/{REPO}/pulls/{pr_number}/reviews?per_page=100')
    own = [review for review in reviews if review.get('user', {}).get('id') == reviewer['id']
           and review.get('user', {}).get('login') == reviewer['login'] and review.get('state') != 'COMMENTED']
    latest = max(own, key=lambda review: review['id'], default={})
    return latest.get('state') == 'APPROVED' and latest.get('commit_id') == sha


def enable_merge(number, sha):
    result = subprocess.run(['gh', 'pr', 'merge', str(number), '--repo', REPO,
                             '--auto', '--squash', '--match-head-commit', sha], capture_output=True, text=True,
                            env=dict(os.environ, GH_HOST='github.com'), timeout=60)
    if result.returncode:
        raise AutomationError(f'PR #{number}: native auto-merge failed (exit {result.returncode}); check permissions, head changes and branch rules')


def app_actor(value):
    return (isinstance(value, dict) and value.get('login') == REVIEWER_LOGIN
            and type(value.get('id')) is int and value['id'] == REVIEWER_BOT_ID
            and value.get('type') == 'Bot')


def validate_auto_merge(pr):
    existing = pr.get('auto_merge')
    if existing is not None and (not isinstance(existing, dict)
            or existing.get('merge_method', '').lower() != 'squash'
            or not app_actor(existing.get('enabled_by'))):
        raise AutomationError('Existing auto-merge is not owned by the approved App')


def verify_merged_revision(pr, base_sha, request):
    # After a squash merge, merge_commit_sha identifies the actual squash
    # commit. The response's base.sha is not a frozen pre-merge base: inspect
    # the immutable commit's parent instead, then prove it reached main.
    merged_sha = pr.get('merge_commit_sha')
    if (pr.get('state') != 'closed' or not app_actor(pr.get('merged_by'))
            or not isinstance(merged_sha, str) or not SHA.fullmatch(merged_sha)
            or merged_sha == '0' * 40):
        raise AutomationError('Merged outcome identity unavailable; outcome needs reconciliation')
    commit = request(f'repos/{REPO}/git/commits/{merged_sha}')
    parents = commit.get('parents') if isinstance(commit, dict) else None
    if (not isinstance(commit, dict) or commit.get('sha') != merged_sha
            or not isinstance(parents, list) or len(parents) != 1
            or not isinstance(parents[0], dict) or parents[0].get('sha') != base_sha):
        raise AutomationError('Squash commit does not have the admitted base as its sole parent; outcome needs reconciliation')
    main = request(f'repos/{REPO}/git/ref/heads/main').get('object', {}).get('sha')
    if not isinstance(main, str) or not SHA.fullmatch(main) or main == '0' * 40:
        raise AutomationError('Current main revision unavailable; outcome needs reconciliation')
    if main != merged_sha:
        # A subsequent legitimate merge may have advanced main. Compare frozen
        # SHAs, not a moving branch name; do not infer membership from PR state.
        ancestry = request(f'repos/{REPO}/compare/{merged_sha}...{main}')
        if (not isinstance(ancestry, dict) or ancestry.get('base_commit', {}).get('sha') != merged_sha
                or ancestry.get('merge_base_commit', {}).get('sha') != merged_sha
                or ancestry.get('status') != 'ahead'
                or type(ancestry.get('behind_by')) is not int or ancestry['behind_by'] != 0
                or type(ancestry.get('ahead_by')) is not int or ancestry['ahead_by'] <= 0):
            raise AutomationError('Squash commit is not proven on current main; outcome needs reconciliation')
    return merged_sha


def approve_and_arm(pr, *, request, merge, reviewer, eligible, read_token, report,
                    controls, check_suite_id):
    number, sha, base_sha = pr['number'], pr['head']['sha'], pr['base']['sha']
    if not owner_author(pr) or not app_actor(reviewer) or type(check_suite_id) is not int or check_suite_id <= 0:
        raise AutomationError('Exclusive author, reviewer and CI identity required')
    path = f'repos/{REPO}/pulls/{number}'

    def prewrite():
        # Live settings, source, App scope and run identity, then current checks
        # and PR state immediately before every write. Server strict checks and
        # expected head remain required; later approval/target changes also need
        # outcome reconciliation because these observations are not atomic.
        controls()
        if not ci_passed(sha, request, read_token, check_suite_id=check_suite_id):
            report(f'PR #{number}: current CI gate unavailable; deferred.')
            return None
        latest = request(path)
        if (latest.get('number') != number or not owner_author(latest) or not eligible(latest)
                or latest.get('head', {}).get('sha') != sha
                or latest.get('base', {}).get('sha') != base_sha):
            report(f'PR #{number}: identity, head or base changed; deferred.')
            return None
        validate_auto_merge(latest)
        return latest

    approved = already_approved(number, sha, request, reviewer)
    latest = prewrite()
    if latest is None:
        return
    if not approved:
        request(path + '/reviews', payload={'event': 'APPROVE', 'commit_id': sha,
                'body': 'Policy-based automatic approval: required CI passed for this commit. This is not substantive code review.'})
    # Read back this App's current-head approval, including dismissal races.
    if not already_approved(number, sha, request, reviewer):
        raise AutomationError('Current App approval could not be verified')
    latest = prewrite()
    if latest is None:
        return
    # This read must follow the LAST controls/checks/PR pass, immediately before
    # arming (or accepting an existing arm). The earlier approval readback can
    # become stale during those reads. Native auto-merge can be armed without a
    # current approval, so its server rules alone cannot enforce this App gate.
    if not already_approved(number, sha, request, reviewer):
        raise AutomationError('Current App approval changed during final controls; arming refused')
    was_armed = latest.get('auto_merge') is not None
    if not was_armed:
        merge(number, sha)
    # Both new and existing arms get the same fresh outcome proof. An existing
    # native request may complete while this handler is reading its controls.
    result = request(path)
    head, base = result.get('head') or {}, result.get('base') or {}
    if (type(result.get('number')) is not int or result['number'] != number
            or not owner_author(result) or result.get('draft') is not False
            or not repository_identity(head.get('repo')) or not repository_identity(base.get('repo'))
            or head.get('sha') != sha or head.get('ref') != pr['head'].get('ref')
            or base.get('ref') != 'main'
            or not isinstance(base.get('sha'), str) or not SHA.fullmatch(base['sha'])):
        raise AutomationError('Outcome repository, target, author or head changed; outcome needs reconciliation')
    merged_sha = None
    if result.get('merged') is True:
        merged_sha = verify_merged_revision(result, base_sha, request)
    else:
        validate_auto_merge(result)
        if result.get('auto_merge') is None or base['sha'] != base_sha or not eligible(result):
            raise AutomationError('App auto-merge outcome could not be verified; outcome needs reconciliation')
    # Read approval after every outcome observation, including merge ancestry.
    # A late dismissal is a reconciliation failure, never verified success.
    # There is no compensating disable/merge or attempt to bypass server rules.
    if not already_approved(number, sha, request, reviewer):
        raise AutomationError('Current App approval absent at outcome; outcome needs reconciliation')
    if merged_sha is not None:
        report(f'PR #{number}: verified App approval and squash merge {merged_sha} on main from {base_sha}.')
    elif not was_armed:
        report(f'PR #{number}: verified App approval and native squash request for {sha}.')
    else:
        report(f'PR #{number}: verified current App approval and existing App-owned squash auto-merge.')


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

