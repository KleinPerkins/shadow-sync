"""Read-only live controls for qualification and each ordinary reviewer write.

Effective rules are readable with Metadata read. Bypass actors are deliberately
not inferred from their omission: owner administration must separately verify
that the App has no bypass before activation. This helper grants no settings or
protected-administration authority.
"""
from github_automation import (REPO, SHA, ACTIONS_APP_ID, AutomationError, pages,
                               repository_identity)


def verify_controls(repository, rules):
    if (not repository_identity(repository) or repository.get('visibility') != 'public'
            or repository.get('private') is not False or repository.get('default_branch') != 'main'
            or repository.get('archived') is not False or repository.get('disabled') is not False):
        raise AutomationError('Public active repository identity required')
    for key, expected in dict(allow_squash_merge=True, allow_merge_commit=False,
                              allow_rebase_merge=False, allow_auto_merge=True,
                              delete_branch_on_merge=True).items():
        if repository.get(key) is not expected:
            raise AutomationError('Repository merge setting mismatch: ' + key)
    if not isinstance(rules, list):
        raise AutomationError('Effective branch rules unavailable')
    by_type = {}
    for rule in rules:
        if not isinstance(rule, dict) or not isinstance(rule.get('type'), str):
            raise AutomationError('Malformed effective rule')
        params = rule.get('parameters', {})
        if not isinstance(params, dict):
            raise AutomationError('Malformed effective rule parameters')
        by_type.setdefault(rule['type'], []).append(params)
    for name in ('required_linear_history', 'deletion', 'non_fast_forward'):
        if name not in by_type:
            raise AutomationError('Missing effective rule: ' + name)
    if not any(type(value.get('required_approving_review_count')) is int
               and value['required_approving_review_count'] >= 1
               and value.get('dismiss_stale_reviews_on_push') is True
               and value.get('required_review_thread_resolution') is True
               for value in by_type.get('pull_request', [])):
        raise AutomationError('Current approval and resolved conversations required')
    if not any(value.get('strict_required_status_checks_policy') is True
               and isinstance(value.get('required_status_checks'), list)
               and any(isinstance(check, dict) and check.get('context') == 'ci-required'
                       and type(check.get('integration_id')) is int
                       and check['integration_id'] == ACTIONS_APP_ID
                       for check in value['required_status_checks'])
               for value in by_type.get('required_status_checks', [])):
        raise AutomationError('Strict ci-required from GitHub Actions required')


def verify_live_controls(request, source_sha):
    if not isinstance(source_sha, str) or not SHA.fullmatch(source_sha):
        raise AutomationError('Immutable trusted source required')
    repository = request('repos/' + REPO)
    rules = pages(request, f'repos/{REPO}/rules/branches/main?per_page=100')
    verify_controls(repository, rules)
    if request(f'repos/{REPO}/git/ref/heads/main').get('object', {}).get('sha') != source_sha:
        raise AutomationError('Current main changed from the trusted source/base')
