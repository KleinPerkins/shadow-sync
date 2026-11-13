#!/usr/bin/env python3
"""Trusted-main read-only readiness; no approval, arming or ordinary-merge claim."""
import json
import os
from pathlib import Path
import sys

from github_automation import (REPO, REPOSITORY_ID, REVIEWER_APP_ID, REVIEWER_INSTALLATION_ID,
                               AutomationError, Reporter, api, trusted_context,
                               verify_run, reviewer_identity, ci_passed)
from merge_controls import verify_live_controls


def qualify(event, environment, request):
    source_sha = trusted_context(environment, mode='qualify')
    read_token = environment.get('CI_READ_TOKEN', '')
    run = verify_run(event, request, read_token, mode='qualify')
    if run['head_sha'] != source_sha:
        raise AutomationError('Current merged-main CI must match trusted workflow source')
    verify_live_controls(request, source_sha)
    reviewer = reviewer_identity(request, environment.get('REVIEWER_LOGIN', ''),
                                  environment.get('REVIEWER_INSTALLATION_ID', ''))
    if not ci_passed(source_sha, request, read_token, check_suite_id=run['check_suite_id']):
        raise AutomationError('Current merged-main CI gate unavailable')
    # Freeze the readiness receipt to the same live run and source after reads.
    verify_run(event, request, read_token, mode='qualify')
    verify_live_controls(request, source_sha)
    return dict(schema='shadow-sync/reviewer-controls-readiness/v1', repository=REPO,
                repository_id=REPOSITORY_ID, source_revision=source_sha, app_id=REVIEWER_APP_ID,
                installation_id=REVIEWER_INSTALLATION_ID, reviewer_login=reviewer['login'],
                reviewer_id=reviewer['id'], ci_run_id=run['id'], check_suite_id=run['check_suite_id'],
                effective_controls_verified=True, single_repository_scope=True,
                ordinary_pr_delivery_qualified=False, owner_no_bypass_readback_required=True,
                token_revocation_verified=False,
                limits='Read-only readiness only. Owner bootstrap and no-bypass readback, verified token '
                       'cleanup and the next legitimate ordinary App merge remain separate evidence.')


def main():
    try:
        trusted_context(os.environ, mode='qualify')
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        result = qualify(event, os.environ, api)
        output = Path('outputs')
        if output.exists() and (not output.is_dir() or output.is_symlink()):
            raise AutomationError('Invalid readiness output directory')
        output.mkdir(mode=0o700, exist_ok=True)
        descriptor = os.open(output / 'reviewer-controls-readiness.json',
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(json.dumps(result, sort_keys=True, indent=2) + '\n')
        Reporter(os.environ.get('GITHUB_STEP_SUMMARY'))(
            'Read-only controls readiness passed; ordinary App delivery is not yet qualified.')
        return 0
    except Exception as error:
        reason = str(error) if isinstance(error, AutomationError) else type(error).__name__
        Reporter(os.environ.get('GITHUB_STEP_SUMMARY'))('Reviewer readiness failed: ' + reason, error=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
