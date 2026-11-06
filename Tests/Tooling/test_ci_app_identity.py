"""App approvals require genuine exact-attempt CI; no API writes or credentials."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import github_automation as github

HEAD = 'a' * 40


class CIAppIdentityTests(unittest.TestCase):
    def setUp(self):
        self.gate = dict(id=1, name='ci-required', head_sha=HEAD, status='completed',
            conclusion='success', app={'id': 15368}, check_suite={'id': 20},
            details_url=f'https://github.com/{github.REPO}/actions/runs/10/job/1')
        self.workflow = dict(id=30, path='.github/workflows/ci.yml', state='active')
        self.run = dict(id=10, workflow_id=30, path='.github/workflows/ci.yml',
            event='pull_request', head_sha=HEAD, head_repository={'full_name': github.REPO},
            status='completed', conclusion='success', run_attempt=2, check_suite_id=20)
        self.job = dict(id=1, name='ci-required', run_id=10, run_attempt=2, head_sha=HEAD,
            status='completed', conclusion='success',
            check_run_url=f'https://api.github.com/repos/{github.REPO}/check-runs/1')
        self.calls = []

    def check(self, *, gate=None, workflow=None, run=None, jobs=None, gates=None):
        def read(path, *, token, paginate=False):
            self.assertEqual(token, 'fixture-read-token')
            self.calls.append(path)
            if '/check-runs?' in path:
                self.assertTrue(paginate)
                return [{'check_runs': gates if gates is not None else [gate or self.gate]}]
            if path.endswith('/workflows/ci.yml'):
                return workflow or self.workflow
            if path.endswith('/runs/10'):
                return run or self.run
            self.assertTrue(paginate)
            self.assertEqual(path, f'repos/{github.REPO}/actions/runs/10/attempts/2/jobs?per_page=100')
            return [{'jobs': jobs if jobs is not None else [self.job]}]
        return github.ci_passed(HEAD, read, 'fixture-read-token')

    def test_complete_exact_workflow_attempt_and_read_only_token(self):
        self.assertTrue(self.check())
        self.assertEqual(len(self.calls), 4)

    def test_ambiguous_missing_or_foreign_checks_refuse(self):
        for gates in ([], [self.gate, self.gate], [{**self.gate, 'app': {'id': 42}}]):
            with self.subTest(gates=gates): self.assertFalse(self.check(gates=gates))
        for change in ({'id': True}, {'status': 'queued'}, {'conclusion': 'neutral'},
                       {'head_sha': 'b' * 40}, {'check_suite': {'id': 99}}):
            with self.subTest(change=change): self.assertFalse(self.check(gate={**self.gate, **change}))

    def test_foreign_or_malformed_check_url_refuses(self):
        for url in (None, '', self.gate['details_url'] + '?x=1',
                    self.gate['details_url'].replace('github.com', 'example.invalid'),
                    self.gate['details_url'].replace('/job/1', '/job/2'),
                    self.gate['details_url'].replace(github.REPO, 'fixture-owner/other')):
            with self.subTest(url=url): self.assertFalse(self.check(gate={**self.gate, 'details_url': url}))

    def test_wrong_workflow_identity_path_or_disabled_state_refuses(self):
        for change in ({'id': 99}, {'id': True}, {'path': '.github/workflows/other.yml'}, {'state': 'disabled_manually'}):
            with self.subTest(change=change): self.assertFalse(self.check(workflow={**self.workflow, **change}))

    def test_wrong_run_head_origin_event_or_state_refuses(self):
        for change in ({'id': 11}, {'workflow_id': 99}, {'path': '.github/workflows/other.yml'},
                       {'event': 'push'}, {'head_sha': 'b' * 40}, {'head_repository': {'full_name': 'fixture-owner/fork'}},
                       {'status': 'in_progress'}, {'conclusion': 'failure'}, {'run_attempt': True},
                       {'run_attempt': 0}, {'check_suite_id': 99}):
            with self.subTest(change=change): self.assertFalse(self.check(run={**self.run, **change}))

    def test_missing_duplicate_or_foreign_required_job_refuses(self):
        for jobs in ([], [self.job, self.job], [{**self.job, 'name': 'ci-tooling'}]):
            with self.subTest(jobs=jobs): self.assertFalse(self.check(jobs=jobs))

    def test_stale_attempt_or_mismatched_job_cannot_reuse_success(self):
        for change in ({'id': True}, {'id': 2}, {'run_id': 11}, {'run_attempt': 1},
                       {'head_sha': 'b' * 40}, {'status': 'queued'}, {'conclusion': 'cancelled'},
                       {'check_run_url': self.job['check_run_url'].replace('/1', '/2')}):
            with self.subTest(change=change): self.assertFalse(self.check(jobs=[{**self.job, **change}]))


if __name__ == '__main__':
    unittest.main()
