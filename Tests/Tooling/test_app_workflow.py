"""Exercise ordinary App policy without GitHub writes or credential access."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
SPEC = importlib.util.spec_from_file_location('app_workflow', ROOT / 'scripts/auto-merge.py')
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)


class AppWorkflowTests(unittest.TestCase):
    def exercise(self, *, rename=False, moved_head=False, passing_gate=True,
                 dependabot=False, approval_error=False, merge_error=False, already=False,
                 file_entries=None, changed_files=1, candidate_number=7):
        head = 'a' * 40
        reviewer = {'login': 'shadow-sync-test-app[bot]', 'id': 12345, 'type': 'Bot'}
        pr = {'number': 7, 'state': 'open', 'draft': False,
              'base': {'ref': 'main', 'repo': {'full_name': app.REPO}},
              'head': {'sha': head, 'ref': 'ordinary-tests', 'repo': {'full_name': app.REPO}},
              'author_association': 'OWNER', 'changed_files': changed_files,
              'auto_merge': {'merge_method': 'squash'} if already else None}
        if dependabot:
            pr['user'] = {'login': 'dependabot[bot]', 'id': 49699333, 'type': 'Bot'}
        run = {'id': 10, 'event': 'pull_request', 'conclusion': 'success',
               'head_sha': head, 'head_repository': {'full_name': app.REPO},
               'actor': {'login': 'some-app[bot]'}}
        entry = {'filename': 'Tests/test_example.py'}
        if rename:
            entry['previous_filename'] = 'scripts/release.py'
        reviews, reads = [], 0

        def fake_api(path, *, payload=None, token=None, paginate=False, **kwargs):
            nonlocal reads
            if path.startswith('users/'):
                return reviewer
            if '/check-runs?' in path:
                self.assertEqual(token, 'fixture-read-token')
                return [{'check_runs': [{'name': 'ci-required', 'head_sha': head, 'status': 'completed',
                                         'conclusion': 'success' if passing_gate else 'failure', 'app': {'id': 15368},
                                         'id': 1, 'check_suite': {'id': 20},
                                         'details_url': f'https://github.com/{app.REPO}/actions/runs/10/job/1'}]}]
            if '/actions/' in path:
                self.assertEqual(token, 'fixture-read-token')
                if path.endswith('/workflows/ci.yml'):
                    return {'id': 30, 'path': '.github/workflows/ci.yml', 'state': 'active'}
                if path.endswith('/runs/10'):
                    return {**run, 'workflow_id': 30, 'path': '.github/workflows/ci.yml',
                            'status': 'completed', 'run_attempt': 1, 'check_suite_id': 20}
                self.assertTrue(paginate)
                self.assertEqual(path, f'repos/{app.REPO}/actions/runs/10/attempts/1/jobs?per_page=100')
                return [{'jobs': [{'name': 'ci-required', 'id': 1, 'run_id': 10, 'run_attempt': 1,
                                  'head_sha': head, 'status': 'completed', 'conclusion': 'success',
                                  'check_run_url': f'https://api.github.com/repos/{app.REPO}/check-runs/1'}]}]
            if '/commits/' in path:
                return [[{'number': candidate_number}]]
            if '/files?' in path:
                self.assertTrue(paginate)
                return [[entry] if file_entries is None else file_entries]
            if '/reviews?' in path:
                return [[{'id': 1, 'user': reviewer, 'state': 'APPROVED', 'commit_id': head}]] if already else [[]]
            if path.endswith('/reviews'):
                if approval_error:
                    raise app.AutomationError('Approval failed (HTTP 403)')
                reviews.append(payload)
                return {}
            self.assertEqual(path, f'repos/{app.REPO}/pulls/7')
            reads += 1
            result = copy.deepcopy(pr)
            if moved_head and reads > 1:
                result['head']['sha'] = 'b' * 40
            return result

        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / 'event.json'
            event.write_text(json.dumps({'repository': {'full_name': app.REPO}, 'workflow_run': run}))
            with patch.dict(app.os.environ, {'GITHUB_EVENT_PATH': str(event), 'CI_READ_TOKEN': 'fixture-read-token',
                                             'REVIEWER_LOGIN': reviewer['login']}), \
                 patch.object(app, 'api', side_effect=fake_api), \
                 patch.object(app, 'enable_merge', side_effect=app.AutomationError('Merge failed') if merge_error else None) as merge:
                result = app.main()
                return result, reviews, merge.call_args_list

    def test_renaming_a_protected_file_cannot_gain_app_approval(self):
        result, reviews, commands = self.exercise(rename=True)
        self.assertEqual((result, reviews, commands), (0, [], []))

    def test_push_between_eligibility_and_review_prevents_approval(self):
        result, reviews, commands = self.exercise(moved_head=True)
        self.assertEqual((result, reviews, commands), (0, [], []))

    def test_successful_run_without_current_required_gate_cannot_merge(self):
        result, reviews, commands = self.exercise(passing_gate=False)
        self.assertEqual((result, reviews, commands), (0, [], []))

    def test_ordinary_review_and_merge_are_bound_to_the_verified_commit(self):
        result, reviews, commands = self.exercise()
        self.assertEqual(result, 0)
        self.assertEqual(reviews[0]['event'], 'APPROVE')
        self.assertEqual(reviews[0]['commit_id'], 'a' * 40)
        self.assertEqual(commands[0].args, (7, 'a' * 40))

    def test_app_triggered_dependabot_events_never_use_ordinary_policy(self):
        self.assertEqual(self.exercise(dependabot=True), (0, [], []))

    def test_approval_and_merge_errors_are_not_swallowed(self):
        self.assertEqual(self.exercise(approval_error=True)[0], 1)
        self.assertEqual(self.exercise(merge_error=True)[0], 1)

    def test_repeated_run_does_not_duplicate_approval_or_auto_merge(self):
        self.assertEqual(self.exercise(already=True), (0, [], []))

    def test_incomplete_malformed_or_duplicate_files_prevent_every_write(self):
        cases = [([], 1), ([{'filename': 'README.md'}], 2),
                 ([{'filename': 'README.md'}], True),
                 ([{'filename': 'README.md'}], 3001),
                 ([{'filename': 'README.md'}, {'filename': 'README.md'}], 2),
                 ([{}], 1), ([{'filename': '../scripts/release.py'}], 1),
                 ([{'filename': 'README.md', 'previous_filename': ''}], 1),
                 ([{'filename': '/scripts/release.py'}], 1),
                 ([{'filename': 'docs//file.md'}], 1),
                 ([{'filename': 'docs\\file.md'}], 1),
                 ([{'filename': 'docs/\nfile.md'}], 1)]
        for entries, count in cases:
            with self.subTest(entries=entries, count=count):
                self.assertEqual(self.exercise(file_entries=entries, changed_files=count), (1, [], []))

    def test_nonpositive_boolean_and_text_pr_identifiers_fail_before_review(self):
        for number in (0, -1, True, '7', None):
            with self.subTest(number=number):
                self.assertEqual(self.exercise(candidate_number=number), (1, [], []))

    def test_shadow_sync_authority_paths_cannot_receive_ordinary_approval(self):
        paths = ['install.sh', 'Dependencies/fixture.lock',
                 'Resources/com.kleinperkins.shadow-sync.plist.template',
                 'Sources/ShadowSyncCore/QualifiedCommandGraph.swift',
                 'Sources/ShadowSyncCore/RetainedCleanupRegistry.swift',
                 'Sources/ShadowSyncCore/CommandCustodian.swift',
                 'Sources/ShadowSyncCore/OwnedSpawnAnchor.swift',
                 'config/ci-suites.json', 'Resources/policy-runtime-source.json',
                 'Sources/ShadowSyncCore/FreshStateInitialization.swift',
                 'Sources/ShadowSyncCore/CustodyResources.swift',
                 'Sources/ShadowSyncCore/LifecyclePublisher.swift',
                 'Sources/ShadowSyncCore/ClosedProcessRunner.swift',
                 '.github/workflows/release.yml', 'scripts/install-app.sh',
                 'Sources/ShadowSyncCore/InstallationLifecycle.swift',
                 'Sources/ShadowSyncCore/ReleaseIdentity.swift',
                 'Sources/ShadowSyncCore/SecureState.swift',
                 'Sources/ShadowSyncCore/HostControl.swift',
                 'Sources/ShadowSyncCore/RepositoryPolicy.swift',
                 'Sources/ShadowSyncCore/RepositoryAuthorityStore.swift',
                 'Sources/ShadowSyncApp/AppLifecycleRouter.swift',
                 'Sources/ShadowSyncLifecycleCoordinator/main.swift',
                 'Resources/PolicyAdapter.py', 'Resources/awa-contract.json',
                 'Resources/Info.plist', 'ShadowSync.xcodeproj/project.pbxproj',
                 'Configuration/Signing.entitlements', 'BUILD_NUMBER', 'Package.resolved']
        for path in paths:
            for entry in ({'filename': path},
                          {'filename': path, 'previous_filename': 'Tests/moved.py'},
                          {'filename': 'Tests/moved.py', 'previous_filename': path}):
                with self.subTest(entry=entry):
                    self.assertEqual(self.exercise(file_entries=[entry]), (0, [], []))

    def test_full_file_roster_includes_both_names_of_a_rename(self):
        self.assertEqual(app.complete_changed_files({'changed_files': 2}, [
            {'filename': 'README.md'},
            {'filename': 'docs/retired.md', 'previous_filename': 'scripts/install-app.sh'},
        ]), ['README.md', 'docs/retired.md', 'scripts/install-app.sh'])


if __name__ == '__main__':
    unittest.main()
