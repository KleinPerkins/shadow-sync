"""Policy, race, repeat-run, failure and workflow-boundary regression tests."""
import copy
import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import github_automation as github
SPEC = importlib.util.spec_from_file_location('maintenance', ROOT / 'scripts/dependency-maintenance.py')
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)
HEAD = 'a' * 40
MAIN = 'b' * 40
REVIEWER = {'login': 'shadow-sync-test-app[bot]', 'id': 12345, 'type': 'Bot'}


def pull(number=10):
    return {'number': number, 'state': 'open', 'draft': False,
            'title': 'chore(deps): bump example from 1.0.0 to 2.0.0',
            'user': {'login': 'dependabot[bot]', 'id': 49699333, 'type': 'Bot'},
            'base': {'ref': 'main', 'repo': {'full_name': github.REPO}},
            'head': {'ref': 'dependabot/github_actions/example-2.0.0', 'sha': HEAD,
                     'repo': {'full_name': github.REPO}},
            'auto_merge': None, 'mergeable': True, 'changed_files': 1}


def gate(**kwargs):
    return dict({'id': 1, 'name': 'ci-required', 'head_sha': HEAD, 'status': 'completed',
                 'conclusion': 'success', 'app': {'id': 15368}, 'check_suite': {'id': 20},
                 'details_url': f'https://github.com/{github.REPO}/actions/runs/10/job/1'}, **kwargs)


class Harness:
    def __init__(self, prs=None):
        self.prs = prs if prs is not None else [pull()]
        self.current = {p['number']: copy.deepcopy(p) for p in self.prs}
        self.calls, self.merges, self.logs = [], [], []
        self.behind, self.checks, self.reviews = 0, [gate()], []
        self.files = [{'filename': 'Dependencies/release-notes.md'}]
        self.failures, self.reads, self.moves = {}, {}, {}
        self.main_reads = 0
        self.move_main = False

    def request(self, path, *, payload=None, token=None, paginate=False, method=None):
        method = method or ('POST' if payload is not None else 'GET')
        self.calls.append((method, path, payload, token))
        for key, message in self.failures.items():
            if key in path:
                raise github.AutomationError(message)
        if '/pulls?' in path:
            assert paginate
            return [copy.deepcopy(self.prs)]
        if path.startswith('users/'):
            return REVIEWER
        if path.endswith('/git/ref/heads/main'):
            self.main_reads += 1
            return {'object': {'sha': 'c' * 40 if self.move_main and self.main_reads > 1 else MAIN}}
        if '/compare/' in path:
            return {'behind_by': self.behind}
        if '/check-runs?' in path:
            assert token == 'read-only-fixture' and paginate
            return [{'check_runs': copy.deepcopy(self.checks)}]
        if '/actions/' in path:
            assert token == 'read-only-fixture'
            if path.endswith('/workflows/ci.yml'):
                return {'id': 30, 'path': '.github/workflows/ci.yml', 'state': 'active'}
            if path.endswith('/runs/10'):
                return {'id': 10, 'workflow_id': 30, 'path': '.github/workflows/ci.yml',
                        'event': 'pull_request', 'head_sha': self.checks[0]['head_sha'],
                        'head_repository': {'full_name': github.REPO}, 'status': 'completed',
                        'conclusion': 'success', 'run_attempt': 1, 'check_suite_id': 20}
            assert path == f'repos/{github.REPO}/actions/runs/10/attempts/1/jobs?per_page=100' and paginate
            return [{'jobs': [{'name': 'ci-required', 'id': 1, 'run_id': 10, 'run_attempt': 1,
                              'head_sha': self.checks[0]['head_sha'], 'status': 'completed',
                              'conclusion': 'success',
                              'check_run_url': f'https://api.github.com/repos/{github.REPO}/check-runs/1'}]}]
        match = re.search(r'/pulls/(\d+)', path)
        number = int(match[1])
        if '/files?' in path:
            assert paginate
            return [copy.deepcopy(self.files)]
        if path.endswith('/update-branch'):
            return {'message': 'Updating'}
        if '/reviews?' in path:
            assert paginate
            return [copy.deepcopy(self.reviews)]
        if path.endswith('/reviews'):
            self.reviews.append({'id': 100, 'user': REVIEWER, 'state': 'APPROVED', 'commit_id': payload['commit_id']})
            return {}
        self.reads[number] = self.reads.get(number, 0) + 1
        if (number, self.reads[number]) in self.moves:
            self.current[number] = self.moves[number, self.reads[number]]
        return copy.deepcopy(self.current[number])

    def merge(self, number, sha):
        if 'merge' in self.failures:
            raise github.AutomationError(self.failures['merge'])
        self.merges.append((number, sha))
        self.current[number]['auto_merge'] = {'merge_method': 'squash'}

    def report(self, message, **kwargs):
        self.logs.append((message, kwargs.get('error', False)))

    def run(self):
        return maintenance.reconcile(request=self.request, merge=self.merge, report=self.report,
                                     read_token='read-only-fixture', reviewer_login=REVIEWER['login'])

    def writes(self):
        return [call for call in self.calls if call[0] != 'GET']


class DependencyPolicyTests(unittest.TestCase):
    def test_protected_or_incomplete_files_refuse_every_dependency_write(self):
        cases = [[], [{'filename': 'Package.resolved'}],
                 [{'filename': 'Dependencies/fixture.lock'}],
                 [{'filename': 'install.sh'}],
                 [{'filename': 'Resources/com.kleinperkins.shadow-sync.plist.template'}],
                 [{'filename': 'Sources/ShadowSyncCore/QualifiedCommandGraph.swift'}],
                 [{'filename': 'Sources/ShadowSyncCore/RetainedCleanupRegistry.swift'}],
                 [{'filename': '.github/workflows/ci.yml'}],
                 [{'filename': 'Dependencies/release-notes.md', 'previous_filename': 'scripts/release.py'}],
                 [{'filename': '../unsafe'}],
                 [{'filename': 'Dependencies/release-notes.md'}] * 2]
        protected = [row[0]['filename'] for row in cases if len(row) == 1
                     and github.protected_files([row[0]['filename']])]
        for name in protected:
            cases.extend([[{'filename': name, 'previous_filename': 'Dependencies/release-notes.md'}],
                          [{'filename': 'Dependencies/release-notes.md', 'previous_filename': name}]])
        for files in cases:
            with self.subTest(files=files):
                h = Harness(); h.files = files; h.behind = 1
                h.run()
                self.assertEqual(h.writes(), []); self.assertEqual(h.merges, [])

    def test_patch_minor_and_major_use_identical_current_ci_policy(self):
        for version in ('1.0.1', '1.1.0', '2.0.0'):
            with self.subTest(version=version):
                pr = pull(); pr['title'] = f'chore(deps): bump example from 1.0.0 to {version}'
                pr['head']['ref'] = f'dependabot/swift/example-{version}'
                h = Harness([pr]); self.assertEqual(h.run(), 0)
                self.assertEqual(h.merges, [(10, HEAD)])
                approval = h.writes()[0][2]
                self.assertEqual(approval['commit_id'], HEAD)
                self.assertIn('not substantive code review', approval['body'])

    def test_identity_repository_state_target_and_branch_are_all_required(self):
        changes = [('user', {'login': 'dependabot[bot]', 'id': 1, 'type': 'Bot'}),
                   ('user', {'login': 'human', 'id': 49699333, 'type': 'Bot'}),
                   ('user', {'login': 'dependabot[bot]', 'id': 49699333, 'type': 'User'}),
                   ('state', 'closed'), ('draft', True)]
        for field, value in changes:
            pr = pull(); pr[field] = value
            self.assertFalse(github.dependency_pr(pr))
        for side in ('head', 'base'):
            pr = pull(); pr[side]['repo']['full_name'] = 'other/fork'
            self.assertFalse(github.dependency_pr(pr))
            pr = pull(); pr[side]['repo'] = None
            self.assertFalse(github.dependency_pr(pr))
        for branch in ('release-please--branches--main', 'ordinary'):
            pr = pull(); pr['head']['ref'] = branch
            self.assertFalse(github.dependency_pr(pr))
        pr = pull(); pr['base']['ref'] = 'develop'; self.assertFalse(github.dependency_pr(pr))
        pr = pull(); pr['head']['sha'] = '../main'; self.assertFalse(github.dependency_pr(pr))

    def test_current_ci_required_rejects_all_nonpassing_and_foreign_evidence(self):
        cases = [[], [gate(name='unit-tests')], [gate(app={'id': 42})], [gate(head_sha='c' * 40)],
                 [gate(status='in_progress')], [gate(), gate(status='queued', conclusion=None)]]
        cases += [[gate(conclusion=value)] for value in (None, 'failure', 'cancelled', 'skipped', 'neutral', 'timed_out', 'action_required', 'stale')]
        for checks in cases:
            with self.subTest(checks=checks):
                h = Harness(); h.checks = checks
                self.assertEqual(h.run(), 0)
                self.assertEqual(h.writes(), []); self.assertEqual(h.merges, [])

    def test_behind_branch_is_refreshed_with_expected_head_and_never_approved(self):
        h = Harness(); h.behind = 3
        self.assertEqual(h.run(), 0)
        self.assertEqual(h.writes(), [('PUT', f'repos/{github.REPO}/pulls/10/update-branch', {'expected_head_sha': HEAD}, None)])
        self.assertEqual(h.merges, [])
        self.assertFalse(any('/check-runs?' in call[1] for call in h.calls))

    def test_new_head_after_refresh_requires_its_own_successful_ci(self):
        h = Harness(); h.behind = 1; h.run()
        h.behind = 0; h.current[10]['head']['sha'] = 'd' * 40
        h.calls.clear(); h.run()
        self.assertEqual(h.writes(), []); self.assertEqual(h.merges, [])
        h.checks = [gate(head_sha='d' * 40)]; self.assertEqual(h.run(), 0)
        self.assertEqual(h.merges, [(10, 'd' * 40)])

    def test_concurrent_head_change_before_update_approval_or_merge_is_safe(self):
        for read, behind in ((2, 1), (3, 0), (4, 0)):
            with self.subTest(read=read):
                h = Harness(); h.behind = behind
                changed = pull(); changed['head']['sha'] = 'e' * 40
                h.moves[10, read] = changed
                self.assertEqual(h.run(), 0); self.assertEqual(h.merges, [])
                if read < 4: self.assertEqual(h.writes(), [])
                else: self.assertEqual(h.writes()[0][2]['commit_id'], HEAD)

    def test_changed_identity_and_main_are_rechecked_before_writing(self):
        h = Harness(); changed = pull(); changed['draft'] = True; h.moves[10, 2] = changed
        self.assertEqual(h.run(), 0); self.assertEqual(h.writes(), [])
        h = Harness(); h.move_main = True
        self.assertEqual(h.run(), 0); self.assertEqual(h.writes(), [])

    def test_repeat_pass_skips_own_current_approval_and_existing_auto_merge(self):
        h = Harness(); h.run(); h.calls.clear(); h.merges.clear()
        self.assertEqual(h.run(), 0)
        self.assertEqual(h.writes(), []); self.assertEqual(h.merges, [])

    def test_old_dismissed_or_other_app_approvals_do_not_count(self):
        for review in ({'id': 1, 'user': REVIEWER, 'state': 'APPROVED', 'commit_id': 'f' * 40},
                       {'id': 1, 'user': REVIEWER, 'state': 'DISMISSED', 'commit_id': HEAD},
                       {'id': 1, 'user': dict(REVIEWER, id=888), 'state': 'APPROVED', 'commit_id': HEAD}):
            h = Harness(); h.reviews = [review]; h.run()
            self.assertEqual(len(h.writes()), 1)

    def test_failures_are_visible_and_later_prs_still_process(self):
        for endpoint, behind in (('/pulls/10/update-branch', 2), ('/pulls/10/reviews', 0), ('/pulls/10', 0)):
            with self.subTest(endpoint=endpoint):
                h = Harness([pull(10), pull(11)]); h.behind = behind
                h.failures[endpoint] = 'GitHub request failed (HTTP 403 or 422)'
                self.assertEqual(h.run(), 1)
                self.assertTrue(any(error and 'PR #10:' in msg for msg, error in h.logs))
                self.assertTrue(any('/pulls/11' in call[1] and call[0] != 'GET' for call in h.calls))

    def test_merge_guard_error_and_conflict_fail_the_pass(self):
        h = Harness(); h.failures['merge'] = 'Head changed (HTTP 409)'
        self.assertEqual(h.run(), 1); self.assertTrue(any(error for _, error in h.logs))
        h = Harness(); h.current[10]['mergeable'] = False
        self.assertEqual(h.run(), 1); self.assertEqual(h.writes(), [])

    def test_ci_recheck_before_approval_rejects_a_new_pending_run(self):
        h = Harness()
        request = h.request
        checks_read = 0

        def changing_checks(path, **kwargs):
            nonlocal checks_read
            if '/check-runs?' in path:
                checks_read += 1
                if checks_read > 1:
                    h.checks = [gate(status='queued', conclusion=None)]
            return request(path, **kwargs)

        h.request = changing_checks
        self.assertEqual(h.run(), 0)
        self.assertEqual(h.writes(), []); self.assertEqual(h.merges, [])

    def test_merge_failure_continues_to_the_next_pr(self):
        h = Harness([pull(10), pull(11)])
        merge = h.merge

        def first_fails(number, sha):
            if number == 10:
                raise github.AutomationError('Concurrent head refused (HTTP 409)')
            merge(number, sha)

        h.merge = first_fails
        self.assertEqual(h.run(), 1)
        self.assertEqual(h.merges, [(11, HEAD)])
        self.assertTrue(any(error and 'PR #10:' in message for message, error in h.logs))

    def test_existing_auto_merge_still_requires_current_app_approval(self):
        h = Harness(); h.current[10]['auto_merge'] = {'merge_method': 'squash'}
        self.assertEqual(h.run(), 0)
        self.assertEqual(len(h.writes()), 1)
        self.assertEqual(h.writes()[0][2]['commit_id'], HEAD)
        self.assertEqual(h.merges, [])

    def test_pagination_retains_all_results_and_rejects_bad_shapes(self):
        self.assertEqual(github.pages(lambda *a, **k: [[1], [2]], 'unused'), [1, 2])
        self.assertEqual(github.pages(lambda *a, **k: [{'check_runs': [1]}, {'check_runs': [2]}], 'unused', key='check_runs'), [1, 2])
        for value in ({}, [None], [{'wrong': []}]):
            with self.subTest(value=value), self.assertRaises(github.AutomationError):
                github.pages(lambda *a, **k: value, 'unused', key='check_runs')

    def test_cli_pins_merge_to_sha_and_api_separates_read_token(self):
        success = subprocess.CompletedProcess([], 0, '{}', '')
        with patch.object(github.subprocess, 'run', return_value=success) as run, patch.dict(os.environ, {'GH_TOKEN': 'write-fixture'}):
            github.api('repos/example/check-runs', token='read-fixture')
            self.assertEqual(run.call_args.kwargs['env']['GH_TOKEN'], 'read-fixture')
            github.api('repos/example/pulls/10/update-branch', method='PUT', payload={'expected_head_sha': HEAD})
            self.assertEqual(run.call_args.kwargs['env']['GH_TOKEN'], 'write-fixture')
            self.assertIn('PUT', run.call_args.args[0])
            github.enable_merge(10, HEAD)
            self.assertEqual(run.call_args.args[0][-2:], ['--match-head-commit', HEAD])
            self.assertNotIn('--admin', run.call_args.args[0])

    def test_error_reporting_is_actionable_and_does_not_expose_raw_output(self):
        failed = subprocess.CompletedProcess([], 1, 'secret-output', 'secret-output HTTP 403')
        with patch.object(github.subprocess, 'run', return_value=failed), self.assertRaisesRegex(github.AutomationError, 'HTTP 403') as error:
            github.api('repos/example/pulls/10')
        self.assertNotIn('secret-output', str(error.exception))
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()) as output:
            summary = Path(directory) / 'summary.md'
            maintenance.Reporter(summary)('failure\nfor PR #10', error=True)
            self.assertIn('::error::failure%0Afor PR #10', output.getvalue())
            self.assertIn('ERROR:', summary.read_text())

    def test_wrong_runtime_repository_or_branch_fails_closed(self):
        for repo, branch in ((github.REPO, 'refs/heads/dependabot/example'), ('other/repo', 'refs/heads/main')):
            with patch.dict(os.environ, {'GITHUB_REPOSITORY': repo, 'GITHUB_REF': branch}, clear=True), patch.object(maintenance, 'reconcile') as reconcile:
                self.assertEqual(maintenance.main(), 1)
                reconcile.assert_not_called()

    def test_no_eligible_updates_is_an_observable_noop(self):
        pr = pull(); pr['head']['ref'] = 'release-please--branches--main'
        h = Harness([pr]); self.assertEqual(h.run(), 0)
        self.assertEqual(h.writes(), []); self.assertEqual(h.merges, [])
        self.assertTrue(any('0 eligible' in message for message, _ in h.logs))

    def test_workflow_recovers_events_without_executing_untrusted_pr_code(self):
        text = (ROOT / '.github/workflows/app-auto-merge.yml').read_text()
        for expected in ('17,47 * * * *', 'workflow_dispatch:', 'push:', 'branches: [main]',
                         'group: shadow-sync-app-maintenance', 'cancel-in-progress: false', 'checks: read',
                         'python3 scripts/dependency-maintenance.py', '${{ github.workflow_sha }}',
                         'CI_READ_TOKEN: ${{ github.token }}', 'permission-pull-requests: write'):
            self.assertIn(expected, text)
        self.assertEqual(text.count('persist-credentials: false'), 2)
        self.assertNotIn('|| true', text)
        self.assertNotIn('pull_request_target:', text)
        self.assertNotIn('github.actor', text)
        self.assertNotIn('workflow_run.head_sha }}', text)
        config = (ROOT / '.github/dependabot.yml').read_text()
        self.assertEqual(config.count('rebase-strategy: auto'), 2)
        self.assertNotIn('ignore:', config)
        self.assertNotIn('semver-major', config)


if __name__ == '__main__':
    unittest.main()
