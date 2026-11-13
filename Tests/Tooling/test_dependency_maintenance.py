"""Dormant dependency admission must stay read-only under exclusive-author policy."""
import importlib.util
import io
import os
from pathlib import Path
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


class DependencyPolicyTests(unittest.TestCase):
    def test_every_dependency_size_and_author_is_disabled_before_writes(self):
        for version in ('1.0.1', '1.1.0', '2.0.0'):
            for user in ({'login': 'dependabot[bot]', 'id': github.DEPENDABOT_ID, 'type': 'Bot'},
                         {'login': github.OWNER_LOGIN, 'id': github.OWNER_ID, 'type': 'User'},
                         {'login': 'fixture-owner', 'id': 10, 'type': 'User'}):
                pr = {'number': 7, 'state': 'open', 'draft': False, 'user': user,
                      'title': f'Fixture dependency {version}', 'base': {'ref': 'main'},
                      'head': {'ref': 'dependabot/example', 'sha': 'a'*40}}
                calls = []
                def request(path, **kwargs):
                    self.assertNotIn('payload', kwargs)
                    self.assertNotIn('method', kwargs)
                    self.assertTrue(kwargs['paginate'])
                    self.assertEqual(path, f'repos/{github.REPO}/pulls?state=open&base=main&per_page=100')
                    calls.append(path)
                    return [[pr]]
                with patch.object(maintenance, 'reviewer_identity') as reviewer, \
                     patch.object(maintenance, 'approve_and_arm') as approve:
                    self.assertEqual(maintenance.reconcile(request=request, merge=lambda *a: self.fail('merge'),
                        report=lambda *a, **k: None, read_token='fixture-read', reviewer_login='fixture-app[bot]'), 0)
                    reviewer.assert_not_called(); approve.assert_not_called()
                self.assertFalse(github.dependency_pr(pr)); self.assertEqual(len(calls), 1)

    def test_workflow_has_no_active_dependency_writer(self):
        text = (ROOT / '.github/workflows/app-auto-merge.yml').read_text()
        self.assertNotIn('dependencies:', text)
        self.assertNotIn('dependency-maintenance.py', text)
        self.assertNotIn('schedule:', text)
        self.assertNotIn('pull_request_target:', text)
        self.assertIn("vars.REVIEWER_APP_ENABLED == 'true'", text)

    def test_pagination_retains_all_results_and_rejects_bad_shapes(self):
        self.assertEqual(github.pages(lambda *a, **k: [[1], [2]], 'unused'), [1, 2])
        self.assertEqual(github.pages(lambda *a, **k: [{'check_runs':[1]}, {'check_runs':[2]}],
                                     'unused', key='check_runs'), [1, 2])
        for value in ({}, [None], [{'wrong': []}]):
            with self.subTest(value=value), self.assertRaises(github.AutomationError):
                github.pages(lambda *a, **k: value, 'unused', key='check_runs')

    def test_cli_pins_merge_to_sha_and_api_separates_read_token(self):
        success = subprocess.CompletedProcess([], 0, '{}', '')
        with patch.object(github.subprocess, 'run', return_value=success) as run, \
             patch.dict(os.environ, {'GH_TOKEN': 'write-fixture', 'GH_HOST': 'example.invalid'}, clear=True):
            github.api('repos/fixture-owner/example/check-runs', token='read-fixture')
            self.assertEqual(run.call_args.kwargs['env']['GH_TOKEN'], 'read-fixture')
            self.assertEqual(run.call_args.args[0][2:4], ['--hostname', 'github.com'])
            github.api('repos/fixture-owner/example/pulls/7/reviews', payload={'event': 'APPROVE'})
            self.assertEqual(run.call_args.kwargs['env']['GH_TOKEN'], 'write-fixture')
            github.enable_merge(7, 'a'*40)
            self.assertEqual(run.call_args.args[0][-2:], ['--match-head-commit', 'a'*40])
            self.assertEqual(run.call_args.kwargs['env']['GH_HOST'], 'github.com')
            self.assertNotIn('--admin', run.call_args.args[0])

    def test_error_reporting_never_exposes_raw_transport_output(self):
        failed = subprocess.CompletedProcess([], 1, 'fixture-private-output', 'fixture-private-output HTTP 403')
        with patch.object(github.subprocess, 'run', return_value=failed), \
             self.assertRaisesRegex(github.AutomationError, 'HTTP 403') as error:
            github.api('repos/fixture-owner/example/pulls/7')
        self.assertNotIn('fixture-private-output', str(error.exception))
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()) as output:
            summary = Path(directory) / 'summary.md'
            github.Reporter(summary)('failure\nfor PR #7', error=True)
            self.assertIn('::error::failure%0Afor PR #7', output.getvalue())
            self.assertIn('ERROR:', summary.read_text())

    def test_wrong_runtime_repository_or_branch_fails_closed(self):
        for repo, branch in ((github.REPO, 'refs/heads/dependabot/example'), ('fixture-owner/repo', 'refs/heads/main')):
            with patch.dict(os.environ, {'GITHUB_REPOSITORY': repo, 'GITHUB_REF': branch}, clear=True), \
                 patch.object(maintenance, 'reconcile') as reconcile:
                self.assertEqual(maintenance.main(), 1)
                reconcile.assert_not_called()


if __name__ == '__main__':
    unittest.main()
