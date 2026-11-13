"""Offline ordinary App admission, live-control, race and readiness fixtures."""
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
import github_automation as github
import merge_controls
import qualify_reviewer
SPEC = importlib.util.spec_from_file_location('app_workflow', ROOT / 'scripts/auto-merge.py')
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)
HEAD, BASE = 'a' * 40, 'b' * 40
MERGED, NEXT = 'c' * 40, 'd' * 40


def identity():
    return {'full_name': github.REPO, 'id': github.REPOSITORY_ID}


def owner():
    return {'login': github.OWNER_LOGIN, 'id': github.OWNER_ID, 'type': 'User'}


def reviewer():
    return {'login': github.REVIEWER_LOGIN, 'id': github.REVIEWER_BOT_ID, 'type': 'Bot'}


def repository():
    return dict(identity(), visibility='public', private=False, default_branch='main',
                archived=False, disabled=False, allow_squash_merge=True,
                allow_merge_commit=False, allow_rebase_merge=False, allow_auto_merge=True,
                delete_branch_on_merge=True)


def rules():
    return [{'type': name} for name in ('required_linear_history', 'deletion', 'non_fast_forward')] + [
        {'type': 'pull_request', 'parameters': {'required_approving_review_count': 1,
         'dismiss_stale_reviews_on_push': True, 'required_review_thread_resolution': True}},
        {'type': 'required_status_checks', 'parameters': {'strict_required_status_checks_policy': True,
         'required_status_checks': [{'context': 'ci-required', 'integration_id': github.ACTIONS_APP_ID}]}}]


class Harness:
    def __init__(self):
        self.pr = {'number': 7, 'state': 'open', 'draft': False, 'user': owner(),
                   'base': {'ref': 'main', 'sha': BASE, 'repo': identity()},
                   'head': {'sha': HEAD, 'ref': 'feature', 'repo': identity()},
                   'changed_files': 1, 'auto_merge': None}
        self.run = {'id': 10, 'event': 'pull_request', 'status': 'completed', 'conclusion': 'success',
                    'path': github.CI_PATH, 'head_sha': HEAD, 'head_branch': 'feature',
                    'repository': identity(), 'head_repository': identity(),
                    'check_suite_id': 20, 'run_attempt': 1}
        self.event = {'repository': identity(), 'workflow_run': self.run}
        self.repo, self.rules = repository(), rules()
        self.main = BASE
        self.merge_commit = {'sha': MERGED, 'parents': [{'sha': BASE}]}
        self.ancestry = {'base_commit': {'sha': MERGED}, 'merge_base_commit': {'sha': MERGED},
                         'status': 'ahead', 'behind_by': 0, 'ahead_by': 1}
        self.comparison = {'base_commit': {'sha': BASE}, 'merge_base_commit': {'sha': BASE},
                           'behind_by': 0, 'status': 'ahead',
                           'files': [{'filename': 'Sources/ShadowSyncCore/ReportModel.swift', 'status': 'modified'}]}
        self.bot = reviewer()
        self.app = {'id': github.REVIEWER_APP_ID, 'slug': github.REVIEWER_SLUG, 'owner': owner(),
                    'permissions': {'contents': 'write', 'pull_requests': 'write', 'metadata': 'read'}}
        self.scope = {'total_count': 1, 'repositories': [identity()]}
        self.checks = [{'name': 'ci-required', 'app': {'id': github.ACTIONS_APP_ID},
                        'head_sha': HEAD, 'status': 'completed', 'conclusion': 'success',
                        'check_suite': {'id': 20}}]
        self.reviews, self.writes, self.merges, self.calls = [], [], [], []
        self.reads = 0
        self.messages = []
        self.hook = lambda path, payload: None
        self.env = {'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': 'workflow_run',
                    'GITHUB_REPOSITORY': github.REPO, 'GITHUB_REPOSITORY_ID': str(github.REPOSITORY_ID),
                    'GITHUB_REF': 'refs/heads/main', 'GITHUB_WORKFLOW_REF':
                    f'{github.REPO}/{github.WORKFLOW_PATH}@refs/heads/main',
                    'GITHUB_SHA': BASE, 'TRUSTED_WORKFLOW_SHA': BASE,
                    'REVIEWER_LOGIN': github.REVIEWER_LOGIN,
                    'REVIEWER_INSTALLATION_ID': str(github.REVIEWER_INSTALLATION_ID),
                    'REVIEWER_APP_ENABLED': 'true', 'CI_READ_TOKEN': 'fixture-read-token', 'GH_TOKEN': 'fixture-app-token'}

    def request(self, path, *, payload=None, token=None, paginate=False):
        self.calls.append(path)
        self.hook(path, payload)
        if path == f'repos/{github.REPO}':
            return copy.deepcopy(self.repo)
        if '/rules/branches/' in path:
            assert paginate
            return [copy.deepcopy(self.rules)]
        if path.endswith('/git/ref/heads/main'):
            return {'object': {'sha': self.main}}
        if '/actions/runs/' in path:
            assert token == 'fixture-read-token'
            return copy.deepcopy(self.run)
        if path.startswith('apps/'):
            return copy.deepcopy(self.app)
        if path.startswith('users/'):
            return copy.deepcopy(self.bot)
        if path.startswith('installation/'):
            return copy.deepcopy(self.scope)
        if '/check-runs?' in path:
            assert token == 'fixture-read-token' and paginate
            return [{'check_runs': copy.deepcopy(self.checks)}]
        if path == f'repos/{github.REPO}/git/commits/{MERGED}':
            assert not paginate and payload is None
            return copy.deepcopy(self.merge_commit)
        if '/commits/' in path:
            assert paginate
            return [[{'number': self.pr['number']}]]
        if '/compare/' in path:
            if path == f'repos/{github.REPO}/compare/{MERGED}...{self.main}':
                return copy.deepcopy(self.ancestry)
            assert path.endswith(f'{BASE}...{HEAD}')
            return copy.deepcopy(self.comparison)
        if '/reviews?' in path:
            assert paginate
            return [copy.deepcopy(self.reviews)]
        if path.endswith('/reviews'):
            self.writes.append(copy.deepcopy(payload))
            self.reviews.append({'id': len(self.reviews) + 1, 'state': 'APPROVED',
                                 'commit_id': payload['commit_id'], 'user': reviewer()})
            return copy.deepcopy(self.reviews[-1])
        assert path == f'repos/{github.REPO}/pulls/7'
        self.reads += 1
        return copy.deepcopy(self.pr)

    def merge(self, number, sha):
        self.merges.append((number, sha))
        self.pr['auto_merge'] = {'merge_method': 'squash', 'enabled_by': reviewer()}

    def seed_armed(self):
        self.pr['auto_merge'] = {'merge_method': 'squash', 'enabled_by': reviewer()}
        self.reviews = [{'id': 1, 'state': 'APPROVED', 'commit_id': HEAD, 'user': reviewer()}]

    def complete_merge(self):
        self.pr.update(merged=True, state='closed', merged_by=reviewer(),
                       merge_commit_sha=MERGED, auto_merge=None)
        self.main = MERGED
        self.pr['base']['sha'] = MERGED

    def exercise(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / 'event.json'
            event.write_text(json.dumps(self.event))
            with patch.dict(app.os.environ, dict(self.env, GITHUB_EVENT_PATH=str(event)), clear=True), \
                 patch.object(app, 'api', side_effect=self.request), \
                 patch.object(app, 'Reporter', return_value=lambda message, **_: self.messages.append(message)), \
                 patch.object(app, 'enable_merge', side_effect=self.merge):
                result = app.main()
        return result, self.writes, self.merges

    def qualification(self):
        self.env.pop('REVIEWER_APP_ENABLED', None)
        self.env['REVIEWER_APP_QUALIFY'] = 'true'
        self.run.update(event='push', head_sha=BASE, head_branch='main')
        self.checks[0]['head_sha'] = BASE
        return qualify_reviewer.qualify(copy.deepcopy(self.event), self.env, self.request)


class AppWorkflowTests(unittest.TestCase):
    def test_ordinary_review_and_merge_are_bound_to_the_verified_commit(self):
        h = Harness()
        result, writes, merges = h.exercise()
        self.assertEqual(result, 0)
        self.assertEqual(writes[0]['event'], 'APPROVE')
        self.assertEqual(writes[0]['commit_id'], HEAD)
        self.assertEqual(merges, [(7, HEAD)])
        self.assertGreaterEqual(h.calls.count(f'repos/{github.REPO}/rules/branches/main?per_page=100'), 3)

    def test_exclusive_owner_identity_rejects_every_other_human_bot_and_partial_match(self):
        cases = [None, {}, {'login': 'fixture-owner', 'id': 10, 'type': 'User'},
                 dict(owner(), id=10), dict(owner(), login='fixture-owner'), dict(owner(), type='Bot'),
                 dict(owner(), id=str(github.OWNER_ID)), dict(owner(), id=True),
                 {'login': 'dependabot[bot]', 'id': github.DEPENDABOT_ID, 'type': 'Bot'}, reviewer()]
        for user in cases:
            with self.subTest(user=user):
                h = Harness(); h.pr['user'] = user
                self.assertEqual(h.exercise(), (0, [], []))

    def test_shadow_sync_authority_paths_cannot_receive_ordinary_approval(self):
        paths = ['.github/workflows/release.yml', 'scripts/install-app.sh',
                 'Sources/ShadowSyncCore/InstallationLifecycle.swift',
                 'Sources/ShadowSyncCore/ReleaseIdentity.swift',
                 'Sources/ShadowSyncCore/SecureState.swift',
                 'Sources/ShadowSyncCore/HostControl.swift',
                 'Sources/ShadowSyncCore/RepositoryPolicy.swift',
                 'Sources/ShadowSyncCore/RepositoryAuthorityStore.swift',
                 'Sources/ShadowSyncCore/InstallationControlRecord.swift',
                 'Sources/ShadowSyncCore/LifecycleCoordinatorMain.swift',
                 'Sources/ShadowSyncCore/LegacyInstallationRelease.swift',
                 'Sources/ShadowSyncCore/FreshStateInitialization.swift',
                 'Sources/ShadowSyncCore/CustodyCatalog.swift',
                 'Sources/ShadowSyncCore/CommandCustodyContext.swift',
                 'Sources/ShadowSyncCore/RetainedCleanupRegistry.swift',
                 'Sources/ShadowSyncCore/PublisherPolicyResources.swift',
                 'Sources/ShadowSyncCore/PolicyAuthorityFile.swift',
                 'Sources/ShadowSyncCore/HostPolicyBinding.swift',
                 'Sources/ShadowSyncLifecycleCoordinator/main.swift',
                 'Sources/ShadowSyncApp/AppLifecycleRouter.swift',
                 'Resources/source-export.json', 'Resources/PolicyAdapter.py',
                 'Resources/awa-contract.json', 'Resources/Info.plist',
                 'Tests/ShadowSyncSelfTests/CISuites.swift', 'Tests/Fixtures/production-test-markers.json',
                 'Configuration/Signing.entitlements', 'BUILD_NUMBER', 'Package.resolved',
                 'delivery/worker/src/index.js', 'delivery/schema.sql', 'config/ci-suites.json',
                 'docs/adr/future-policy.md', '.planning/doc-warden.json', '.githooks/pre-commit',
                 '.GITHUB/workflows/release.yml', 'DELIVERY/access.py']
        for path in paths:
            for entry in ({'filename': path, 'status': 'modified'},
                          {'filename': 'Sources/Report.swift', 'previous_filename': path, 'status': 'renamed'}):
                with self.subTest(entry=entry):
                    h = Harness(); h.comparison['files'] = [entry]
                    self.assertEqual(h.exercise(), (0, [], []))

    def test_installer_launch_template_and_command_graph_require_owner_path(self):
        paths = ['install.sh', 'Resources/com.kleinperkins.shadow-sync.plist.template',
                 'Resources/command-graphs.json']
        for original in paths:
            for path in (original, original.upper()):
                for entry in ({'filename': path, 'status': 'added'},
                              {'filename': path, 'status': 'modified'},
                              {'filename': path, 'status': 'removed'},
                              {'filename': 'Sources/Report.swift', 'previous_filename': path,
                               'status': 'renamed'}):
                    with self.subTest(entry=entry):
                        h = Harness(); h.comparison['files'] = [entry]
                        self.assertEqual(h.exercise(), (0, [], []))

    def test_incomplete_malformed_duplicate_or_capped_files_prevent_every_write(self):
        cases = [([], 1), ([{'filename': 'README.md'}], 2), ([{'filename': 'README.md'}], True),
                 ([{'filename': 'README.md'}], 300),
                 ([{'filename': 'README.md'}, {'filename': 'README.md'}], 2),
                 ([{}], 1), ([{'filename': '../scripts/release.py'}], 1),
                 ([{'filename': 'README.md', 'previous_filename': ''}], 1),
                 ([{'filename': '/scripts/release.py'}], 1), ([{'filename': 'docs//file.md'}], 1),
                 ([{'filename': 'docs\\file.md'}], 1), ([{'filename': 'docs/\nfile.md'}], 1)]
        for entries, count in cases:
            with self.subTest(entries=entries, count=count):
                h = Harness(); h.comparison['files'] = [dict(entry, status='modified') for entry in entries]; h.pr['changed_files'] = count
                self.assertEqual(h.exercise(), (1, [], []))

    def test_missing_status_or_rename_origin_cannot_hide_protected_paths(self):
        for entry in ({'filename': 'Sources/Report.swift'},
                      {'filename': 'Sources/Report.swift', 'status': 'renamed'},
                      {'filename': 'Sources/Report.swift', 'status': 'unknown'}):
            h = Harness(); h.comparison['files'] = [entry]
            self.assertEqual(h.exercise(), (1, [], []))

    def test_comparison_must_be_against_exact_current_base_without_behind_commits(self):
        for field, value in [('base_commit', {'sha': 'c'*40}), ('merge_base_commit', {'sha': 'c'*40}),
                             ('status', 'diverged'), ('behind_by', 1), ('behind_by', False)]:
            with self.subTest(field=field):
                h = Harness(); h.comparison[field] = value
                self.assertEqual(h.exercise(), (1, [], []))

    def test_head_base_author_draft_and_file_count_races_prevent_approval_or_arming(self):
        changes = [lambda h: h.pr['head'].update(sha='c'*40),
                   lambda h: h.pr['base'].update(sha='c'*40),
                   lambda h: h.pr.update(user={'login':'fixture-owner','id':10,'type':'User'}),
                   lambda h: h.pr.update(draft=True), lambda h: h.pr.update(changed_files=2)]
        for change in changes:
            for at_read in (2, 3):
                with self.subTest(change=change, at_read=at_read):
                    h = Harness()
                    def race(path, payload):
                        if path == f'repos/{github.REPO}/pulls/7' and h.reads + 1 == at_read:
                            change(h)
                    h.hook = race
                    result, writes, merges = h.exercise()
                    self.assertEqual(result, 0); self.assertEqual(merges, [])
                    self.assertEqual(len(writes), 0 if at_read == 2 else 1)

    def test_controls_and_app_identity_changes_are_rechecked_before_both_writes(self):
        changes = [lambda h: setattr(h, 'rules', []), lambda h: h.repo.update(allow_merge_commit=True),
                   lambda h: setattr(h, 'main', 'c'*40), lambda h: h.bot.update(id=10),
                   lambda h: h.app.update(id=10), lambda h: h.scope.update(total_count=2)]
        for change in changes:
            for after_approval in (False, True):
                with self.subTest(change=change, after_approval=after_approval):
                    h = Harness()
                    def race(path, payload):
                        if ((not after_approval and '/reviews?' in path)
                                or (after_approval and h.writes and '/reviews?' in path)):
                            change(h)
                    h.hook = race
                    result, writes, merges = h.exercise()
                    self.assertEqual(result, 1); self.assertEqual(merges, [])
                    self.assertEqual(len(writes), 1 if after_approval else 0)

    def test_ci_missing_foreign_skipped_and_wrong_workflow_suite_never_approves(self):
        cases = [[], [{'name': 'other'}]]
        baseline = Harness().checks[0]
        cases += [[dict(baseline, **change)] for change in (
            {'conclusion':'skipped'}, {'conclusion':'failure'}, {'conclusion':'cancelled'},
            {'status':'queued'}, {'head_sha':'c'*40}, {'app':{'id':10}}, {'check_suite':{'id':21}})]
        cases += [[baseline, dict(baseline, status='in_progress')]]
        for checks in cases:
            with self.subTest(checks=checks):
                h = Harness(); h.checks = checks
                self.assertEqual(h.exercise(), (0, [], []))

    def test_ci_regression_or_dismissed_approval_prevents_arming(self):
        for dismissed in (False, True):
            h = Harness()
            def race(path, payload):
                if h.writes and '/reviews?' in path:
                    if dismissed:
                        h.reviews[-1]['state'] = 'DISMISSED'
                    else:
                        h.checks[0]['status'] = 'queued'
            h.hook = race
            result, writes, merges = h.exercise()
            self.assertEqual(result, int(dismissed)); self.assertEqual(len(writes), 1)
            self.assertEqual(merges, [])

    def test_repeated_run_does_not_duplicate_approval_or_auto_merge(self):
        h = Harness(); self.assertEqual(h.exercise()[0], 0)
        h.writes.clear(); h.merges.clear(); h.reads = 0
        self.assertEqual(h.exercise(), (0, [], []))

    def test_foreign_auto_merge_owner_or_method_is_refused_before_approval(self):
        for actor, method in ((owner(), 'squash'), (reviewer(), 'merge'), ({}, 'squash')):
            h = Harness(); h.pr['auto_merge'] = {'enabled_by': actor, 'merge_method': method}
            self.assertEqual(h.exercise(), (1, [], []))

    def test_approval_and_merge_errors_and_missing_readback_are_visible(self):
        for stage in ('approve', 'merge', 'readback'):
            h = Harness()
            if stage == 'approve':
                def reject(path, payload):
                    if payload is not None: raise github.AutomationError('Fixture approval refused')
                h.hook = reject
            elif stage == 'merge':
                def reject(number, sha): raise github.AutomationError('Fixture merge refused')
                h.merge = reject
            else:
                h.merge = lambda number, sha: h.merges.append((number, sha))
            self.assertEqual(h.exercise()[0], 1)

    def test_late_approval_dismissal_during_final_controls_checks_or_pr_refuses_arming(self):
        for armed in (False, True):
            for boundary in ('rules', 'ci', 'pr'):
                with self.subTest(armed=armed, boundary=boundary):
                    h = Harness()
                    if armed:
                        h.seed_armed()
                    def dismiss(path, payload):
                        last_rules = '/rules/branches/' in path and h.calls.count(path) == 3
                        last_ci = '/check-runs?' in path and h.calls.count(path) == 2
                        last_pr = path.endswith('/pulls/7') and h.reads == 2
                        if {'rules': last_rules, 'ci': last_ci, 'pr': last_pr}[boundary]:
                            h.reviews[-1]['state'] = 'DISMISSED'
                    h.hook = dismiss
                    result, writes, merges = h.exercise()
                    self.assertEqual(result, 1)
                    self.assertEqual(len(writes), 0 if armed else 1)
                    self.assertEqual(merges, [])
                    self.assertIn('arming refused', h.messages[-1])
                    self.assertFalse(any(message.startswith('PR #7: verified') for message in h.messages))

    def test_final_approval_must_still_belong_to_app_and_admitted_head(self):
        for armed in (False, True):
            for change in (lambda h: h.reviews.clear(),
                           lambda h: h.reviews[-1].update(commit_id=NEXT),
                           lambda h: h.reviews[-1].update(user=owner()),
                           lambda h: h.reviews[-1].update(state='CHANGES_REQUESTED')):
                with self.subTest(armed=armed, change=change):
                    h = Harness()
                    if armed:
                        h.seed_armed()
                    def replace(path, payload):
                        if path.endswith('/pulls/7') and h.reads == 2:
                            change(h)
                    h.hook = replace
                    self.assertEqual(h.exercise()[0], 1)
                    self.assertEqual(h.merges, [])
                    self.assertIn('arming refused', h.messages[-1])

    def test_outcome_requires_current_approval_for_new_and_existing_open_and_merged_arms(self):
        for armed in (False, True):
            for merged in (False, True):
                with self.subTest(armed=armed, merged=merged):
                    h = Harness()
                    if armed:
                        h.seed_armed()
                    def dismiss_at_outcome(path, payload):
                        if path.endswith('/pulls/7') and h.reads == 3:
                            if merged:
                                h.complete_merge()
                            h.reviews[-1]['state'] = 'DISMISSED'
                    h.hook = dismiss_at_outcome
                    result, writes, merges = h.exercise()
                    self.assertEqual(result, 1)
                    self.assertEqual(len(writes), 0 if armed else 1)
                    self.assertEqual(merges, [] if armed else [(7, HEAD)])
                    self.assertIn('Current App approval absent at outcome', h.messages[-1])
                    self.assertFalse(any(message.startswith('PR #7: verified') for message in h.messages))

    def test_approval_is_checked_after_merged_commit_and_main_ancestry_reads(self):
        for armed in (False, True):
            for boundary in ('commit', 'main', 'ancestry'):
                with self.subTest(armed=armed, boundary=boundary):
                    h = Harness()
                    if armed:
                        h.seed_armed()
                    def dismiss(path, payload):
                        if path.endswith('/pulls/7') and h.reads == 3:
                            h.complete_merge()
                            h.main = NEXT
                        if h.pr.get('merged'):
                            matches = {'commit': '/git/commits/' in path,
                                       'main': path.endswith('/git/ref/heads/main'),
                                       'ancestry': path.endswith(f'/compare/{MERGED}...{NEXT}')}
                            if matches[boundary]:
                                h.reviews[-1]['state'] = 'DISMISSED'
                    h.hook = dismiss
                    self.assertEqual(h.exercise()[0], 1)
                    self.assertIn('Current App approval absent at outcome', h.messages[-1])

    def test_open_and_merged_outcomes_retain_repository_main_owner_and_head_identity(self):
        changes = [lambda h: h.pr['base'].update(ref='other-target', sha=NEXT),
                   lambda h: h.pr['base']['repo'].update(id=10),
                   lambda h: h.pr['base']['repo'].update(full_name='owner/fork'),
                   lambda h: h.pr['head']['repo'].update(id=10),
                   lambda h: h.pr['head']['repo'].update(full_name='owner/fork'),
                   lambda h: h.pr.update(user={'login': 'fixture-owner', 'id': 10, 'type': 'User'}),
                   lambda h: h.pr['user'].update(type='Bot'),
                   lambda h: h.pr.update(number=8),
                   lambda h: h.pr['head'].update(sha=NEXT),
                   lambda h: h.pr['head'].update(ref='other-head'),
                   lambda h: h.pr.update(draft=True)]
        for armed in (False, True):
            for merged in (False, True):
                for change in changes:
                    with self.subTest(armed=armed, merged=merged, change=change):
                        h = Harness()
                        if armed:
                            h.seed_armed()
                        def change_outcome(path, payload):
                            if path.endswith('/pulls/7') and h.reads == 3:
                                if merged:
                                    h.complete_merge()
                                change(h)
                        h.hook = change_outcome
                        self.assertEqual(h.exercise()[0], 1)
                        self.assertIn('Outcome repository, target, author or head changed', h.messages[-1])
                        self.assertFalse(any(message.startswith('PR #7: verified') for message in h.messages))

    def test_open_outcome_refuses_changed_base_state_arm_owner_or_method(self):
        changes = [lambda h: h.pr['base'].update(sha=NEXT),
                   lambda h: h.pr.update(state='closed'),
                   lambda h: h.pr.update(auto_merge=None),
                   lambda h: h.pr['auto_merge'].update(enabled_by=owner()),
                   lambda h: h.pr['auto_merge'].update(merge_method='merge')]
        for armed in (False, True):
            for change in changes:
                with self.subTest(armed=armed, change=change):
                    h = Harness()
                    if armed:
                        h.seed_armed()
                    def change_outcome(path, payload):
                        if path.endswith('/pulls/7') and h.reads == 3:
                            change(h)
                    h.hook = change_outcome
                    self.assertEqual(h.exercise()[0], 1)
                    self.assertFalse(any(message.startswith('PR #7: verified') for message in h.messages))

    def test_squash_outcome_accepts_actual_parent_with_advanced_response_base_and_main(self):
        for armed in (False, True):
            for response_base in (BASE, MERGED, NEXT):
                for main in (MERGED, NEXT):
                    with self.subTest(armed=armed, response_base=response_base, main=main):
                        h = Harness()
                        if armed:
                            h.seed_armed()
                        def finish(path, payload):
                            if path.endswith('/pulls/7') and h.reads == 3:
                                h.complete_merge()
                                h.pr['base']['sha'] = response_base
                                h.main = main
                        h.hook = finish
                        result, writes, merges = h.exercise()
                        self.assertEqual(result, 0)
                        self.assertEqual(len(writes), 0 if armed else 1)
                        self.assertEqual(merges, [] if armed else [(7, HEAD)])
                        self.assertIn(f'squash merge {MERGED} on main from {BASE}', h.messages[-1])
                        self.assertIn(f'repos/{github.REPO}/git/commits/{MERGED}', h.calls)
                        ancestry_path = f'repos/{github.REPO}/compare/{MERGED}...{NEXT}'
                        self.assertEqual(ancestry_path in h.calls, main == NEXT)
                        self.assertTrue(h.calls[-1].endswith('/reviews?per_page=100'))

    def test_squash_outcome_refuses_wrong_merge_identity_revision_and_actual_parent(self):
        changes = [lambda h: h.pr.update(merged_by=owner()),
                   lambda h: h.pr.update(state='open'),
                   lambda h: h.pr.update(merge_commit_sha=None),
                   lambda h: h.pr.update(merge_commit_sha='0' * 40),
                   lambda h: h.pr.update(merge_commit_sha='../main'),
                   lambda h: h.merge_commit.update(sha=NEXT),
                   lambda h: h.merge_commit.update(parents=[]),
                   lambda h: h.merge_commit.update(parents=[{'sha': NEXT}]),
                   lambda h: h.merge_commit.update(parents=[{'sha': BASE}, {'sha': HEAD}]),
                   lambda h: h.merge_commit.update(parents=[None]),
                   lambda h: h.merge_commit.update(parents=None)]
        for armed in (False, True):
            for change in changes:
                with self.subTest(armed=armed, change=change):
                    h = Harness()
                    if armed:
                        h.seed_armed()
                    def finish(path, payload):
                        if path.endswith('/pulls/7') and h.reads == 3:
                            h.complete_merge()
                            # An unchanged response base must not mask a merge
                            # performed on another actual parent.
                            h.pr['base']['sha'] = BASE
                            change(h)
                    h.hook = finish
                    self.assertEqual(h.exercise()[0], 1)
                    self.assertIn('outcome needs reconciliation', h.messages[-1])
                    self.assertFalse(any(message.startswith('PR #7: verified') for message in h.messages))

    def test_merged_revision_must_be_reachable_from_main_by_immutable_comparison(self):
        changes = [lambda h: setattr(h, 'main', None),
                   lambda h: setattr(h, 'main', '0' * 40),
                   lambda h: h.ancestry.update(base_commit={'sha': BASE}),
                   lambda h: h.ancestry.update(merge_base_commit={'sha': BASE}),
                   lambda h: h.ancestry.update(status='behind'),
                   lambda h: h.ancestry.update(status='diverged'),
                   lambda h: h.ancestry.update(behind_by=1),
                   lambda h: h.ancestry.update(behind_by=False),
                   lambda h: h.ancestry.update(ahead_by=0),
                   lambda h: h.ancestry.update(ahead_by=True)]
        for armed in (False, True):
            for change in changes:
                with self.subTest(armed=armed, change=change):
                    h = Harness()
                    if armed:
                        h.seed_armed()
                    def finish(path, payload):
                        if path.endswith('/pulls/7') and h.reads == 3:
                            h.complete_merge()
                            h.main = NEXT
                            change(h)
                    h.hook = finish
                    self.assertEqual(h.exercise()[0], 1)
                    self.assertIn('outcome needs reconciliation', h.messages[-1])
                    self.assertFalse(any(message.startswith('PR #7: verified') for message in h.messages))

    def test_disabled_untrusted_or_wrong_issuance_context_never_reads_network(self):
        changes = {'GH_TOKEN': '', 'REVIEWER_APP_ENABLED': '', 'GITHUB_ACTIONS': 'false',
                   'GITHUB_REPOSITORY_ID': '10', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                   'GITHUB_REF': 'refs/heads/feature', 'GITHUB_WORKFLOW_REF': 'owner/fork',
                   'GITHUB_SHA': 'c'*40, 'REVIEWER_LOGIN': 'fixture-app[bot]',
                   'REVIEWER_INSTALLATION_ID': '10'}
        for key, value in changes.items():
            h = Harness(); h.env[key] = value
            self.assertEqual(h.exercise(), (1, [], [])); self.assertEqual(h.calls, [])

    def test_run_path_repository_status_attempt_and_suite_are_strict(self):
        changes = {'path': '.github/workflows/other.yml', 'status': 'in_progress',
                   'repository': {'id': 10, 'full_name': github.REPO}, 'check_suite_id': True,
                   'run_attempt': 0, 'head_repository': {'id': github.REPOSITORY_ID, 'full_name': 'owner/fork'}}
        for key, value in changes.items():
            h = Harness(); h.run[key] = value
            self.assertEqual(h.exercise(), (1, [], []))
        h = Harness()
        def rerun(path, payload):
            if '/actions/runs/' in path: h.run['run_attempt'] += 1
        h.hook = rerun
        self.assertEqual(h.exercise(), (1, [], []))

    def test_app_permission_scope_and_numeric_identity_contract_is_exact(self):
        for change in [lambda h: h.app['permissions'].update(administration='read'),
                       lambda h: h.app['owner'].update(id=10), lambda h: h.bot.update(type='User'),
                       lambda h: h.bot.update(id=str(github.REVIEWER_BOT_ID)),
                       lambda h: h.scope['repositories'][0].update(id=10),
                       lambda h: h.scope.update(total_count=True)]:
            h = Harness(); change(h)
            self.assertEqual(h.exercise(), (1, [], []))

    def test_live_controls_require_each_strict_setting_and_effective_rule(self):
        for field in ('allow_squash_merge', 'allow_merge_commit', 'allow_rebase_merge',
                      'allow_auto_merge', 'delete_branch_on_merge'):
            h = Harness(); h.repo[field] = not h.repo[field]
            self.assertEqual(h.exercise(), (1, [], []))
        for index in range(len(rules())):
            h = Harness(); del h.rules[index]
            self.assertEqual(h.exercise(), (1, [], []))
        for section, key, value in [(-2, 'required_approving_review_count', True),
                                    (-2, 'dismiss_stale_reviews_on_push', False),
                                    (-2, 'required_review_thread_resolution', False),
                                    (-1, 'strict_required_status_checks_policy', False),
                                    (-1, 'required_status_checks', [{'context':'ci-required','integration_id':None}])]:
            h = Harness(); h.rules[section]['parameters'][key] = value
            self.assertEqual(h.exercise(), (1, [], []))

    def test_read_only_qualification_has_no_pr_writes_or_delivery_claim(self):
        h = Harness(); result = h.qualification()
        self.assertEqual(result['source_revision'], BASE)
        self.assertTrue(result['effective_controls_verified'])
        self.assertFalse(result['ordinary_pr_delivery_qualified'])
        self.assertTrue(result['owner_no_bypass_readback_required'])
        self.assertFalse(result['token_revocation_verified'])
        self.assertEqual(h.writes, []); self.assertEqual(h.merges, [])
        self.assertFalse(any('/pulls/' in call for call in h.calls))

    def test_read_only_qualification_refuses_unmatched_source_ci_or_live_controls(self):
        for change in [lambda h: setattr(h, 'rules', []), lambda h: setattr(h, 'main', HEAD),
                       lambda h: h.checks[0].update(conclusion='failure'),
                       lambda h: h.env.update(GITHUB_SHA=HEAD),
                       lambda h: h.env.update(REVIEWER_INSTALLATION_ID='10')]:
            h = Harness(); change(h)
            with self.assertRaises(github.AutomationError): h.qualification()
            self.assertEqual(h.writes, []); self.assertEqual(h.merges, [])

    def test_workflow_only_uses_pinned_named_app_with_disabled_owner_switches(self):
        text = (ROOT / '.github/workflows/app-auto-merge.yml').read_text()
        self.assertIn("vars.REVIEWER_APP_ENABLED == 'true'", text)
        self.assertIn("vars.REVIEWER_APP_QUALIFY == 'true'", text)
        self.assertEqual(text.count("app-id: '4217367'"), 2)
        self.assertEqual(text.count('repositories: shadow-sync'), 2)
        self.assertEqual(text.count('persist-credentials: false'), 2)
        self.assertEqual(text.count('ref: ${{ github.workflow_sha }}'), 2)
        self.assertEqual(text.count('REVIEWER_INSTALLATION_ID: ${{ steps.app.outputs.installation-id }}'), 2)
        for forbidden in ('dependency-maintenance.py', 'permission-administration:', 'pull_request_target:',
                          'secrets.AUTOMERGE_APP_ID', 'github.actor', 'skip-token-revoke:', '|| true'):
            self.assertNotIn(forbidden, text)
        self.assertIn('retention-days: 14', text)


if __name__ == '__main__':
    unittest.main()
