"""Fixture-only release orchestration; no Apple, GitHub or host credential access."""
from contextlib import contextmanager
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_candidate', ROOT / 'scripts/release-candidate.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
REVISION, DIGEST = '1' * 40, '2' * 64
ENV = dict(GITHUB_ACTIONS='true', GITHUB_EVENT_NAME='workflow_dispatch',
    GITHUB_REPOSITORY=module.REPO, GITHUB_REPOSITORY_ID=str(module.REPO_ID), GITHUB_REF='refs/heads/main',
    GITHUB_SHA=REVISION, TRUSTED_WORKFLOW_SHA=REVISION, RUNNER_OS='macOS', RUNNER_ARCH='ARM64',
    RUNNER_ENVIRONMENT='github-hosted', GITHUB_RUN_ID='17', GITHUB_RUN_ATTEMPT='1',
    GITHUB_WORKFLOW_REF=module.REPO + '/' + module.WORKFLOW + '@refs/heads/main')
ADMITTED = dict(revision=REVISION, source_sha256=DIGEST, ci_run_id=9, ci_run_attempt=1, ci_check_id=7)
META = dict(version='0.10.0', build='15', tag='candidate-v0.10.0-build15')


class FakeGitHub:
    def __init__(self):
        self.writes = []
        self.data = {
            '': dict(id=module.REPO_ID, full_name=module.REPO, private=False, default_branch='main', archived=False),
            '/git/ref/heads/main': {'object': {'type': 'commit', 'sha': REVISION,
                'url': module.API + '/git/commits/' + REVISION}},
            '/immutable-releases': {'enabled': True, 'enforced_by_owner': False},
            '/releases/latest': None,
        }
        self.run = dict(id=9, run_number=3, run_attempt=1, head_sha=REVISION, head_branch='main', event='push',
            path='.github/workflows/ci.yml', status='completed', conclusion='success',
            repository={'id': module.REPO_ID}, head_repository={'id': module.REPO_ID}, check_suite_id=8)
        self.check = dict(id=7, name='ci-required', check_suite={'id': 8}, app={'id': 15368}, head_sha=REVISION,
                          status='completed', conclusion='success')
        self.job = dict(name='ci-required', status='completed', conclusion='success', check_run_url=module.API + '/check-runs/7')
        self.tags, self.releases, self.assets = [], [], []
        self.alter_upload = False
        self.immutable_publication = True

    def request(self, path, method='GET', data=None, missing=False, asset=None):
        if method == 'GET':
            if path in self.data:
                return copy.deepcopy(self.data[path])
            if missing:
                return None
            raise AssertionError(path)
        self.writes.append((method, path, data))
        if path == '/git/refs':
            self.data['/git/ref/tags/' + META['tag']] = {'ref': data['ref'], 'object': {'type': 'commit', 'sha': data['sha']}}
            self.tags.append({'name': META['tag']})
            return {}
        if path == '/releases':
            self.data['/releases/12'] = dict(data, id=12, assets=[], immutable=False)
            self.releases.append(self.data['/releases/12'])
            return {'id': 12}
        if '/assets?name=' in path:
            self.assets.append(dict(name=asset.name, state='uploaded', size=asset.stat().st_size,
                digest='sha256:' + ('0' * 64 if self.alter_upload else module.sha(asset)),
                browser_download_url='https://github.com/' + module.REPO + '/releases/download/' + META['tag'] + '/' + asset.name))
            self.data['/releases/12']['assets'] = copy.deepcopy(self.assets)
            return self.assets[-1]
        if path == '/releases/12' and method == 'PATCH':
            self.data[path].update(data, immutable=self.immutable_publication)
            return copy.deepcopy(self.data[path])
        raise AssertionError(path)

    def pages(self, path, key=None):
        if path.startswith('/actions/workflows/ci.yml/runs?'):
            return [copy.deepcopy(self.run)]
        if '/check-runs?' in path:
            return [copy.deepcopy(self.check)]
        if path.startswith('/actions/runs/'):
            return [copy.deepcopy(self.job)]
        return copy.deepcopy({'/tags': self.tags, '/releases': self.releases, '/releases/12/assets': self.assets}[path])


class ReleaseCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-candidate-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.work = self.root / 'attempt'
        self.api = FakeGitHub()
        self.patch('source', return_value=DIGEST)
        self.immutable = self.patch('immutable_enabled')
        self.patch('work_directory', return_value=self.work)
        self.patch('metadata', return_value=META)

    def patch(self, name, **kwargs):
        patch = mock.patch.object(module, name, **kwargs)
        result = patch.start()
        self.addCleanup(patch.stop)
        return result

    def record(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def prepared(self):
        self.work.mkdir(mode=0o700)
        (self.work / 'python.pkg').write_bytes(b'fixture package')
        self.record(self.work / 'build/build.json', {'fixture': True})
        prepared = dict(ADMITTED, **META, run_id=17, release_id=12,
            package_sha256=module.sha(self.work / 'python.pkg'), build_sha256=module.sha(self.work / 'build/build.json'),
            orchestrator_sha256=module.sha(Path(module.__file__)))
        self.record(self.work / 'prepared.json', prepared)
        self.api.data['/git/ref/tags/' + META['tag']] = {'ref': 'refs/tags/' + META['tag'], 'object': {'sha': REVISION, 'type': 'commit'}}
        self.api.data['/releases/12'] = dict(id=12, tag_name=META['tag'], target_commitish=REVISION,
            body=module.reservation_body(prepared), prerelease=True, draft=True, assets=[])
        return prepared

    def packaged(self):
        prepared = self.prepared()
        self.record(self.work / 'credentials-removed.json', dict(revision=REVISION, temporary_credentials_removed=True))
        self.record(self.work / 'assembly/release-assembly.json', {'fixture': True})
        (self.work / 'notary').mkdir()
        artifact = self.work / 'notary/ShadowSync-0.10.0-build15-macos-arm64.dmg'
        artifact.write_bytes(b'fixture distribution, not a real DMG')
        artifact.chmod(0o644)
        package = dict(schema='shadow-sync-release-package/v1', revision=REVISION, source_sha256=DIGEST,
            assembly_sha256=module.sha(self.work / 'assembly/release-assembly.json'),
            packager_sha256=module.sha(ROOT / 'scripts/notarize-release-bundle.py'),
            publisher_team=module.assembly.json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier'],
            version='0.10.0', build='15', architecture='arm64', notarized=True, stapled=True, gatekeeper=True,
            published=False, installed=False, product_accepted=False,
            app_notary_id='11111111-1111-4111-8111-111111111111', dmg_notary_id='22222222-2222-4222-8222-222222222222',
            artifact=dict(name=artifact.name, bytes=artifact.stat().st_size, sha256=module.sha(artifact)))
        self.record(self.work / 'notary/release-package.json', package)
        return prepared, package, artifact

    def test_trusted_main_context_only(self):
        self.assertEqual(module.context(ENV), REVISION)
        for key, value in [('GITHUB_EVENT_NAME', 'pull_request'), ('GITHUB_REPOSITORY_ID', '123'),
                ('GITHUB_REF', 'refs/heads/feature'), ('GITHUB_WORKFLOW_REF', 'fixture-owner/project/other.yml@refs/heads/main'),
                ('TRUSTED_WORKFLOW_SHA', '3' * 40), ('RUNNER_ENVIRONMENT', 'self-hosted'),
                ('RUNNER_ARCH', 'X64'), ('GITHUB_RUN_ATTEMPT', '2')]:
            with self.subTest(key=key), self.assertRaises(module.Refusal):
                module.context(dict(ENV, **{key: value}))

    def test_complete_ci_and_immutable_admission(self):
        self.assertEqual(module.admission(self.api, ENV), ADMITTED)
        self.assertFalse(self.api.writes)

    def test_ci_wrong_app_source_attempt_or_incomplete_refuses(self):
        for target, key, value in [('run', 'conclusion', 'failure'), ('run', 'status', 'in_progress'),
                ('run', 'event', 'pull_request'), ('run', 'head_sha', '3' * 40),
                ('run', 'head_repository', {'id': 123}), ('run', 'path', '.github/workflows/other.yml'),
                ('check', 'app', {'id': 1}), ('check', 'conclusion', 'skipped'),
                ('check', 'check_suite', {'id': 6}), ('job', 'conclusion', 'cancelled'),
                ('job', 'check_run_url', module.API + '/check-runs/6')]:
            api = FakeGitHub()
            getattr(api, target)[key] = value
            with self.subTest(target=target, key=key), self.assertRaises(module.Refusal):
                module.admission(api, ENV)
            self.assertFalse(api.writes)

    def test_latest_ci_attempt_cannot_borrow_previous_attempt_success(self):
        old = dict(self.api.check, id=6)
        current = dict(self.api.check, conclusion='failure')
        pages = self.api.pages
        def listing(path, key=None):
            return [old, current] if '/check-runs?' in path else pages(path, key)
        with mock.patch.object(self.api, 'pages', side_effect=listing):
            with self.assertRaises(module.Refusal): module.admission(self.api, ENV)
            old['conclusion'], current['conclusion'] = 'failure', 'success'
            self.assertEqual(module.admission(self.api, ENV), ADMITTED)

    def test_main_source_and_repository_identity_refuse(self):
        for path, value in [('/git/ref/heads/main', {'object': {'type': 'commit', 'sha': '3' * 40}}),
                ('', dict(self.api.data[''], private=True))]:
            api = FakeGitHub(); api.data[path] = value
            with self.subTest(path=path), self.assertRaises(module.Refusal):
                module.admission(api, ENV)
        with self.assertRaises(module.Refusal):
            module.admission(self.api, ENV, '3' * 64)

    def test_missing_immutability_capability_refuses_before_allocation(self):
        self.immutable.side_effect = module.Refusal('fixture capability unavailable')
        with self.assertRaises(module.Refusal): module.prepare(self.api, ENV)
        self.assertFalse(self.api.writes)
        self.assertFalse(self.work.exists())

    def test_allocation_refuses_draft_tags_reused_build_and_unknown(self):
        module.unallocated(self.api, META)
        for tag in [META['tag'], 'candidate-v0.10.1-build15', 'candidate-v0.10.0-build14',
                    'candidate-v0.11.0-build16', 'v0.9.0']:
            for field in ('tags', 'releases'):
                api = FakeGitHub()
                setattr(api, field, [{'name' if field == 'tags' else 'tag_name': tag}])
                with self.subTest(tag=tag, field=field), self.assertRaises(module.Refusal):
                    module.unallocated(api, META)
                self.assertFalse(api.writes)

    def test_preparation_fetches_and_builds_without_credentials_before_reservation(self):
        events = []
        def build(root, context, job):
            self.assertNotIn('GH_TOKEN', os.environ)
            self.assertFalse(any(key in os.environ for key in module.APPLE))
            self.assertEqual(job, 'package-contract')
            events.append('build')
            self.record(root / 'build.json', {'fixture': True})
        payload = b'fixture pinned package'
        pin = dict(package_url='https://www.python.org/ftp/python/fixture.pkg',
                   package_bytes=len(payload), package_sha256=hashlib.sha256(payload).hexdigest())
        def fetch(*args, **kwargs):
            self.assertFalse(self.api.writes)
            events.append('fetch')
            return io.BytesIO(payload)
        with mock.patch.object(module.assembly.build, 'prepare', side_effect=build), \
                mock.patch.object(module.assembly.runtime, 'load_pin', return_value=pin), \
                mock.patch.object(module.urllib.request, 'urlopen', side_effect=fetch):
            module.prepare(self.api, dict(ENV, GH_TOKEN='fixture-token'))
        self.assertEqual(events, ['build', 'fetch'])
        self.assertEqual([row[:2] for row in self.api.writes], [('POST', '/git/refs'), ('POST', '/releases')])
        self.assertEqual(module.read(self.work / 'prepared.json')['release_id'], 12)
        with self.assertRaises(module.Refusal):
            module.prepare(self.api, ENV)

    def test_prepare_refuses_credentials_before_any_api(self):
        api = mock.Mock()
        with self.assertRaises(module.Refusal):
            module.prepare(api, dict(ENV, APPLE_PASSWORD='fixture-value'))
        api.assert_not_called()
        self.assertFalse(api.mock_calls)

    def test_failed_reservation_never_retries_or_deletes(self):
        self.api.tags = [{'name': META['tag']}]
        with self.assertRaises(module.Refusal):
            module.prepare(self.api, ENV)
        self.assertFalse(self.api.writes)

    def test_closed_environment_strips_unknown_secrets_and_restores_parent(self):
        with mock.patch.dict(os.environ, {'GH_TOKEN': 'fixture', 'UNRELATED_SECRET': 'fixture'}, clear=True):
            with module.closed_environment(dict(HOME=str(self.root), PATH='/usr/bin', APPLE_PASSWORD='fixture')):
                self.assertEqual(dict(os.environ), {'HOME': str(self.root), 'PATH': '/usr/bin'})
            self.assertEqual(dict(os.environ), {'GH_TOKEN': 'fixture', 'UNRELATED_SECRET': 'fixture'})

    def test_notary_failure_uses_existing_cleanup_and_does_not_resubmit(self):
        self.prepared()
        calls = []
        @contextmanager
        def keychain(work, certificate, env):
            calls.append('keychain')
            try: yield work / 'fixture.keychain'
            finally: calls.append('cleanup')
        env = dict(ENV, APPLE_SIGNING_IDENTITY='fixture identity', APPLE_ID='fixture@example.invalid',
                   APPLE_PASSWORD='fixture', APPLE_TEAM_ID='FIXTURE123')
        self.patch('apple_configuration', return_value=b'fixture')
        def command(*args):
            self.assertFalse(any(key in os.environ for key in module.APPLE))
            return SimpleNamespace(stdout='  1) ' + 'A' * 40 + ' "fixture identity"\n')
        with mock.patch.object(module.execution, 'signing_keychain', keychain), \
                mock.patch.object(module.execution, 'command', side_effect=command), \
                mock.patch.object(module.assembly.runtime, 'build') as runtime, \
                mock.patch.object(module.assembly, 'assemble') as assemble, \
                mock.patch.object(module.notary, 'package', side_effect=module.Refusal('fixture')) as package:
            with self.assertRaises(module.Refusal): module.sign(self.api, env)
            self.assertEqual(calls, ['keychain', 'cleanup'])
            runtime.assert_called_once(); assemble.assert_called_once(); package.assert_called_once()
            self.assertFalse(package.call_args.args[0].resume)
            self.assertFalse((self.work / 'credentials-removed.json').exists())
            with self.assertRaises(FileExistsError): module.sign(self.api, env)
            package.assert_called_once()

    def test_changed_prepared_inputs_refuse_signing(self):
        self.prepared()
        (self.work / 'python.pkg').write_bytes(b'changed')
        with self.assertRaises(module.Refusal): module.prepared_attempt(ENV)

    def test_assembly_notary_and_distribution_substitution_refuse(self):
        prepared, package, artifact = self.packaged()
        for key, value in [('revision', '3' * 40), ('source_sha256', '3' * 64),
                ('assembly_sha256', '3' * 64), ('packager_sha256', '3' * 64),
                ('notarized', False), ('stapled', False), ('build', '16')]:
            self.record(self.work / 'notary/release-package.json', dict(package, **{key: value}))
            with self.subTest(key=key), self.assertRaises(module.Refusal):
                module.package_assets(self.work, prepared)
        self.record(self.work / 'notary/release-package.json', package)
        artifact.write_bytes(b'substitute')
        with self.assertRaises(module.Refusal): module.package_assets(self.work, prepared)

    def test_public_receipt_excludes_arbitrary_producer_fields(self):
        prepared, package, _ = self.packaged()
        package['private_path'] = str(self.root)
        self.record(self.work / 'notary/release-package.json', package)
        paths = module.package_assets(self.work, prepared)
        result = module.read(paths[1])
        self.assertNotIn('private_path', result)
        self.assertNotIn(str(self.root), paths[1].read_text())
        self.assertFalse(result['installed'])
        self.assertFalse(result['downloaded_bytes_verified'])

    def publish_fixture(self):
        self.patch('download_digest', side_effect=lambda url, size: module.sha(
            self.work / ('candidate.json' if url.endswith('candidate.json') else 'notary/' + url.rsplit('/', 1)[1])))
        with mock.patch.object(module.execution, 'cleanup'):
            module.publish(self.api, ENV)

    def test_publish_immutable_nonlatest_and_download_same_bytes(self):
        self.packaged()
        self.publish_fixture()
        patches = [row for row in self.api.writes if row[0] == 'PATCH']
        self.assertEqual(patches, [('PATCH', '/releases/12', {'draft': False, 'prerelease': True, 'make_latest': 'false'})])
        self.assertEqual(len(self.api.assets), 2)
        self.assertTrue(module.read(self.work / 'published.json')['downloaded_bytes_verified'])

    def test_upload_substitution_refuses_before_publication(self):
        self.packaged(); self.api.alter_upload = True
        with self.assertRaises(module.Refusal): self.publish_fixture()
        self.assertFalse(any(row[0] == 'PATCH' for row in self.api.writes))

    def test_nonimmutable_publication_never_claims_success(self):
        self.packaged(); self.api.immutable_publication = False
        with self.assertRaises(module.Refusal): self.publish_fixture()
        self.assertFalse((self.work / 'published.json').exists())

    def test_cleanup_failure_blocks_all_uploads(self):
        self.packaged()
        with mock.patch.object(module.execution, 'cleanup', side_effect=module.Refusal('fixture')):
            with self.assertRaises(module.Refusal): module.publish(self.api, ENV)
        self.assertFalse(self.api.writes)

    def test_changed_tag_or_existing_assets_blocks_upload(self):
        prepared, _, _ = self.packaged()
        self.api.data['/git/ref/tags/' + prepared['tag']]['object']['sha'] = '3' * 40
        with self.assertRaises(module.Refusal): self.publish_fixture()
        self.assertFalse(self.api.writes)

    def test_existing_asset_prevents_overwrite(self):
        self.packaged()
        self.api.data['/releases/12']['assets'] = [{'name': 'existing'}]
        with self.assertRaises(module.Refusal): self.publish_fixture()
        self.assertFalse(self.api.writes)

    def test_changed_download_or_latest_never_claims_success(self):
        self.packaged()
        with mock.patch.object(module.execution, 'cleanup'), \
                mock.patch.object(module, 'download_digest', return_value='0' * 64):
            with self.assertRaises(module.Refusal): module.publish(self.api, ENV)
        self.assertFalse((self.work / 'published.json').exists())

    def test_uploads_remain_bound_to_the_original_digest(self):
        prepared, _, artifact = self.packaged()
        paths = module.package_assets(self.work, prepared)
        expected = {p.name: module.sha(p) for p in paths}
        artifact.write_bytes(b'changed after package validation')
        for path in paths:
            self.api.request('/releases/12/assets?name=' + path.name, method='POST', asset=path)
        with self.assertRaises(module.Refusal):
            module.asset_inventory(self.api, prepared, paths, expected)

    def test_failed_token_revocation_cannot_write_success_receipt(self):
        client = mock.Mock()
        client.revoke_and_confirm.side_effect = module.app_credentials.Refusal('fixture')
        with mock.patch.object(module, 'ROOT', self.root), \
                mock.patch.object(module.app_credentials, 'GitHubReadClient', return_value=client), \
                self.assertRaises(module.app_credentials.Refusal):
            module.revoke_admin(dict(ENV, APP_SLUG='fixture-app', REVOCATION_PHASE='prepare'))
        self.assertFalse((self.root / 'outputs').exists())

    def test_verified_token_revocation_is_source_bound_in_evidence(self):
        with mock.patch.object(module, 'ROOT', self.root), \
                mock.patch.object(module.app_credentials, 'GitHubReadClient') as client:
            module.revoke_admin(dict(ENV, APP_SLUG='fixture-app', REVOCATION_PHASE='prepare'))
            module.evidence(ENV)
        client.return_value.revoke_and_confirm.assert_called_once()
        result = module.read(self.root / 'outputs/release-candidate/attempt.json')
        self.assertEqual(result['read_token_revocations'], {'prepare': True, 'sign': False, 'publish': False})
        self.assertTrue(result['reconciliation_required'])

    def test_failure_evidence_retains_submission_id_but_no_private_logs(self):
        self.prepared()
        notary = self.work / 'notary'
        binding = dict(filename='submission.zip', sha256='4' * 64)
        self.record(notary / 'app-intent.json', binding)
        self.record(notary / 'app-submitted.json', dict(binding, id='11111111-1111-4111-8111-111111111111'))
        self.record(notary / 'app-notary-log.json', {'private': str(self.root), 'credential': 'fixture-value'})
        with mock.patch.object(module, 'ROOT', self.root): module.evidence(ENV)
        output = self.root / 'outputs/release-candidate/attempt.json'
        result = module.read(output)
        self.assertEqual(result['submissions']['app']['submitted']['id'], '11111111-1111-4111-8111-111111111111')
        self.assertTrue(result['reconciliation_required'])
        self.assertNotIn(str(self.root), output.read_text())
        self.assertNotIn('fixture-value', output.read_text())

    def test_evidence_rejects_private_text_in_allowlisted_digest(self):
        prepared = self.prepared()
        prepared['source_sha256'] = str(self.root)
        self.record(self.work / 'prepared.json', prepared)
        with mock.patch.object(module, 'ROOT', self.root), self.assertRaises(module.Refusal):
            module.evidence(ENV)
        self.assertFalse((self.root / 'outputs/release-candidate/attempt.json').exists())

    def test_api_pagination_reads_every_page(self):
        api = module.GitHub('fixture')
        with mock.patch.object(api, 'request', side_effect=[list(range(100)), [100]]) as request:
            self.assertEqual(api.pages('/tags'), list(range(101)))
        self.assertEqual(request.call_args_list[-1].args[0], '/tags?per_page=100&page=2')

    def test_workflow_is_protected_pinned_and_has_no_sparkle_or_pr_trigger(self):
        text = (ROOT / module.WORKFLOW).read_text()
        self.assertIn('environment: release', text)
        self.assertIn('runs-on: macos-26', text)
        self.assertIn("github.repository_id == '1442961455'", text)
        self.assertNotIn('pull_request:', text)
        self.assertNotIn('SPARKLE_', text)
        self.assertNotIn('workflow_run:', text)
        self.assertIn('persist-credentials: false', text)
        self.assertEqual(text.count('permission-administration: read'), 3)
        self.assertEqual(text.count('scripts/release-candidate.py admin-revoke'), 3)
        self.assertNotIn('permission-administration: write', text)
        self.assertNotIn('permission-pull-requests:', text)
        self.assertIn('retention-days: 14', text)
        for row in text.splitlines():
            if 'uses:' in row:
                self.assertRegex(row, r'@[0-9a-f]{40}(?: |$)')
        self.assertLess(text.index('scripts/release-candidate.py prepare'), text.index('APPLE_CERTIFICATE:'))


class ImmutabilityClientTests(unittest.TestCase):
    def test_only_fixed_read_endpoint_receives_admin_token(self):
        response = mock.MagicMock()
        response.status = 200
        response.geturl.return_value = module.API + '/immutable-releases'
        response.read.return_value = b'{"enabled": true, "enforced_by_owner": false}'
        response.__enter__.return_value = response
        client = mock.Mock(token='fixture-token')
        client.opener.open.return_value = response
        with mock.patch.object(module.app_credentials, 'GitHubReadClient', return_value=client), \
                mock.patch.object(module.app_credentials, 'qualify') as qualify:
            module.immutable_enabled(dict(ENV, APP_TOKEN='fixture-token', APP_SLUG='fixture-app'))
        qualify.assert_called_once()
        request = client.opener.open.call_args.args[0]
        self.assertEqual(request.method, 'GET')
        self.assertEqual(request.full_url, module.API + '/immutable-releases')
        self.assertIsNone(request.data)

    def test_disabled_immutable_setting_and_redirect_refuse(self):
        for url, payload in [(module.API + '/immutable-releases', b'{"enabled": false}'),
                             ('https://example.invalid', b'{"enabled": true}')]:
            response = mock.MagicMock(status=200)
            response.geturl.return_value = url
            response.read.return_value = payload
            response.__enter__.return_value = response
            client = mock.Mock(token='fixture-token')
            client.opener.open.return_value = response
            with mock.patch.object(module.app_credentials, 'GitHubReadClient', return_value=client), \
                    mock.patch.object(module.app_credentials, 'qualify'), self.assertRaises(module.Refusal):
                module.immutable_enabled(ENV)


if __name__ == '__main__':
    unittest.main()
