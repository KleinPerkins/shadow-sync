"""Fixture-only release orchestration; no Apple, GitHub or host credential access."""
from contextlib import contextmanager, ExitStack
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import sqlite3
import stat
import subprocess
import sys
import tarfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_candidate', ROOT / 'scripts/release-candidate.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
REVISION, DIGEST = '1' * 40, '2' * 64
ENV = dict(RELEASE_SOURCE_REVISION=REVISION, RELEASE_ATTEMPT_ID='17')

ADMITTED = dict(revision=REVISION, source_sha256=DIGEST, ci_run_id=9, ci_run_attempt=1, ci_check_id=7, owner_controls={'synthetic': True})
META = dict(version='0.10.0', build='15', tag='candidate-v0.10.0-build15')


class FakeGitHub:
    def __init__(self):
        self.writes = []
        self.data = {
            '/owner-principal': dict(login='KleinPerkins', id=49759187, type='User'),
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
        if path.endswith('/pulls'):
            return [dict(merged_at='fixture', merge_commit_sha=REVISION, base={'ref': 'main', 'repo': {'id': module.REPO_ID}})]
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
        self.config_path = self.root / 'config.json'
        self.record(self.config_path, {})
        self.env = dict(ENV, RELEASE_DELIVERY_CONFIG=str(self.config_path))
        self.api = FakeGitHub()
        self.patch('source', return_value=DIGEST)
        self.immutable = self.patch('immutable_enabled', return_value=ADMITTED['owner_controls'])
        self.configuration = self.patch('private_configuration', return_value={})
        self.patch('prepare_signer', side_effect=lambda work: (work / 'sign_update').write_bytes(b'fixture signer'))
        signer = mock.patch.object(module.execution, 'SIGNER_SHA256', hashlib.sha256(b'fixture signer').hexdigest())
        signer.start(); self.addCleanup(signer.stop)
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
        (self.work / 'sign_update').write_bytes(b'fixture signer')
        (self.work / 'python.pkg').write_bytes(b'fixture package')
        self.record(self.work / 'build/build.json', {'fixture': True})
        prepared = dict(ADMITTED, **META, run_id=17, release_id=12,
            package_sha256=module.sha(self.work / 'python.pkg'), build_sha256=module.sha(self.work / 'build/build.json'),
            orchestrator_sha256=module.sha(Path(module.__file__)), signer_sha256=module.sha(self.work / 'sign_update'), delivery_config_sha256=module.sha(self.config_path))
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

    def test_owner_local_context_only(self):
        self.assertEqual(module.context(ENV), REVISION)
        for change in ({'GITHUB_ACTIONS': 'true'}, {'RELEASE_SOURCE_REVISION': 'bad'},
                       {'RELEASE_ATTEMPT_ID': '0'}, {'RELEASE_SOURCE_REVISION': '0' * 40}):
            with self.subTest(change=change), self.assertRaises(module.Refusal):
                module.context(dict(ENV, **change))

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
            module.prepare(self.api, dict(self.env, GH_TOKEN='fixture-token'))
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
        env = dict(self.env, APPLE_SIGNING_IDENTITY='fixture identity', APPLE_ID='fixture@example.invalid',
                   APPLE_PASSWORD='fixture', APPLE_TEAM_ID='FIXTURE123')
        self.patch('apple_configuration', return_value=b'fixture')
        def command(*args):
            self.assertFalse(any(key in os.environ for key in module.APPLE))
            return SimpleNamespace(stdout='  1) ' + 'A' * 40 + ' "fixture identity"\n')
        with mock.patch.object(module.execution, 'configuration'), \
                mock.patch.object(module.execution, 'signing_keychain', keychain), \
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
        with self.assertRaises(module.Refusal): module.prepared_attempt(self.env)

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

    def test_detached_producer_binds_both_artifacts_without_installed_acceptance(self):
        prepared, _, artifact = self.packaged()
        self.record(self.work / 'notary/app-stapled.json', {'entries': {'fixture': 'signed'}})
        calls = []
        def command(stage, *args, **kwargs):
            calls.append(stage)
            if stage == 'final-stapled-archive': (self.work / 'ShadowSync.zip').write_bytes(b'fixture archived stapled app')
            return SimpleNamespace(stdout='A' * 86 + '==')
        with mock.patch.object(module.notary, 'app_tree', return_value={'fixture': 'signed'}), \
                mock.patch.object(module.assembly, 'verify_code'), \
                mock.patch.object(module.execution, 'command', side_effect=command), \
                mock.patch.object(module, 'verify_detached') as verify, \
                mock.patch.object(module.delivery, 'validate_manifest'):
            module.detached_assets(self.work, prepared, dict(SPARKLE_PRIVATE_ED_KEY='fixture-private', SPARKLE_PUBLIC_ED_KEY='fixture-public'))
        self.assertEqual(verify.call_count, 2)
        self.assertEqual(calls.count('detached-sign'), 2)
        value = module.read(self.work / 'manifest.json')
        self.assertEqual(value['channel'], 'qualification'); self.assertFalse(value['qualified'])
        self.assertEqual(value['first_install']['sha256'], module.sha(artifact))
        self.assertEqual(value['archive']['sha256'], module.sha(self.work / 'ShadowSync.zip'))
        self.assertNotIn('operator_acceptance', module.read(self.work / 'qualification.json')['checks'])
        self.assertNotIn('fixture-private', (self.work / 'detached.json').read_text())

    def private_fixture(self):
        prepared, package, artifact = self.packaged()
        archive = self.work / 'ShadowSync.zip'
        archive.write_bytes(b'fixture final archive')
        descriptor = lambda path, kind: dict(path=f'/v1/apps/{module.delivery.APP}/releases/{META["tag"]}/{kind}',
            sha256=module.sha(path), size=path.stat().st_size, ed25519_signature='A' * 86 + '==')
        value = dict(schema='shadow-sync/release/v1', app_id=module.delivery.APP, bundle_id=module.delivery.APP,
            team_id='J2V7GRV5CM', channel='qualification', qualified=False, version='0.10.0', build=15,
            minimum_macos='26.0', architecture='arm64', data_schema_version=1, source_revision=REVISION,
            qualification_id=META['tag'], archive=descriptor(archive, 'archive'), first_install=descriptor(artifact, 'package'))
        receipt = dict(schema='shadow-sync/qualification/v1', app_id=module.delivery.APP,
            qualification_id=META['tag'], source_revision=REVISION, build=15,
            archive_sha256=value['archive']['sha256'], archive_size=value['archive']['size'],
            first_install_sha256=value['first_install']['sha256'], first_install_size=value['first_install']['size'],
            checks={key: True for key in module.delivery.CHECKS})
        self.record(self.work / 'manifest.json', value)
        self.record(self.work / 'qualification.json', receipt)
        self.record(self.work / 'detached.json', dict(public_key='fixture',
            manifest_sha256=module.sha(self.work / 'manifest.json'), receipt_sha256=module.sha(self.work / 'qualification.json')))
        config = self.root / 'config.json'; self.record(config, {})
        self.env = dict(ENV, RELEASE_DELIVERY_CONFIG=str(config))
        self.patch('verify_detached')
        validation = mock.patch.object(module.delivery, 'validate_manifest', side_effect=lambda v: v)
        validation.start(); self.addCleanup(validation.stop)
        return value, receipt, archive, artifact

    def test_private_publish_uses_existing_delivery_and_never_uploads_public_assets(self):
        value, receipt, archive, artifact = self.private_fixture()
        with mock.patch.object(module.execution, 'cleanup'), \
                mock.patch.object(module.delivery, 'Cloudflare') as provider, \
                mock.patch.object(module.delivery, 'publish') as publish:
            module.publish(self.api, self.env)
        publish.assert_called_once()
        self.assertEqual(publish.call_args.args, (provider.return_value, value, receipt, archive, artifact))
        publish.call_args.kwargs['before_promote']()
        self.assertFalse(self.api.writes)
        result = module.read(self.work / 'published.json')
        self.assertTrue(result['downloaded_bytes_verified'])
        self.assertFalse(result['installed']); self.assertFalse(result['product_accepted'])
        self.assertEqual(result['channel'], 'qualification')

    def test_public_target_changed_bytes_and_missing_signature_refuse_before_provider(self):
        value, receipt, archive, artifact = self.private_fixture()
        for change in ('stable', 'bytes', 'signature'):
            with self.subTest(change=change):
                if change == 'stable':
                    changed = dict(value, channel='stable', qualified=True)
                    self.record(self.work / 'manifest.json', changed)
                elif change == 'bytes':
                    self.record(self.work / 'manifest.json', value)
                    archive.write_bytes(b'changed')
                else:
                    archive.write_bytes(b'fixture final archive')
                    module.verify_detached.side_effect = module.Refusal('invalid detached signature')
                with mock.patch.object(module.execution, 'cleanup'), \
                        mock.patch.object(module.delivery, 'Cloudflare') as provider, self.assertRaises(module.Refusal):
                    module.publish(self.api, self.env)
                provider.assert_not_called()

    def test_cleanup_failure_blocks_provider(self):
        self.private_fixture()
        with mock.patch.object(module.execution, 'cleanup', side_effect=module.Refusal('cleanup')), \
                mock.patch.object(module.delivery, 'Cloudflare') as provider, self.assertRaises(module.Refusal):
            module.publish(self.api, self.env)
        provider.assert_not_called()

    def test_changed_reservation_or_public_assets_blocks_provider(self):
        self.private_fixture()
        tag = self.api.data['/git/ref/tags/' + META['tag']]
        for changed_tag in (True, False):
            tag['object']['sha'] = '3' * 40 if changed_tag else REVISION
            self.api.data['/releases/12']['assets'] = [] if changed_tag else [{'name': 'unexpected'}]
            with self.subTest(changed_tag=changed_tag), mock.patch.object(module.execution, 'cleanup'), \
                    mock.patch.object(module.delivery, 'Cloudflare') as provider, self.assertRaises(module.Refusal):
                module.publish(self.api, self.env)
            provider.assert_not_called()

    def test_exclusive_publication_intent_is_durable_before_provider_construction(self):
        self.private_fixture()
        intent, events = self.work / 'publication-intent.json', []
        fsync = os.fsync
        def sync(descriptor):
            info = os.fstat(descriptor)
            if intent.exists():
                if stat.S_ISDIR(info.st_mode):
                    self.assertEqual(info.st_ino, self.work.stat().st_ino)
                    events.append('intent-directory-sync')
                elif info.st_ino == intent.stat().st_ino:
                    events.append('intent-file-sync')
            return fsync(descriptor)
        def provider(*args, **kwargs):
            self.assertEqual(events, ['intent-file-sync', 'intent-directory-sync'])
            events.append('provider')
        with mock.patch.object(module.execution, 'cleanup'), \
                mock.patch.object(os, 'fsync', side_effect=sync), \
                mock.patch.object(module.delivery, 'Cloudflare', side_effect=provider), \
                mock.patch.object(module.delivery, 'publish'):
            module.publish(self.api, self.env)
        self.assertEqual(events[:3], ['intent-file-sync', 'intent-directory-sync', 'provider'])

    def test_publication_intent_creation_failure_precedes_provider(self):
        self.private_fixture()
        intent, original = self.work / 'publication-intent.json', Path.open
        def opening(path, *args, **kwargs):
            if path == intent and args and args[0] == 'x':
                raise OSError('fixture exclusive creation failed')
            return original(path, *args, **kwargs)
        with mock.patch.object(module.execution, 'cleanup'), \
                mock.patch.object(Path, 'open', opening), \
                mock.patch.object(module.delivery, 'Cloudflare') as provider, self.assertRaises(OSError):
            module.publish(self.api, self.env)
        provider.assert_not_called()
        self.assertFalse(intent.exists())
        self.assertTrue((self.work / 'publication-inputs.json').is_file())

    def test_publication_intent_sync_failure_retains_attempt_without_retry(self):
        self.private_fixture()
        intent = self.work / 'publication-intent.json'
        original_work = self.work
        # Independent retained attempts exercise both persistence failure cuts.
        for failure in ('file', 'directory'):
            import shutil
            self.work = self.root / ('attempt-' + failure)
            shutil.copytree(original_work, self.work)
            module.work_directory.return_value = self.work
            intent = self.work / 'publication-intent.json'
            fsync = os.fsync
            def sync(descriptor):
                info = os.fstat(descriptor)
                target = intent.exists() and ((failure == 'directory' and stat.S_ISDIR(info.st_mode)) or
                    (failure == 'file' and info.st_ino == intent.stat().st_ino))
                if target: raise OSError('fixture durability failure')
                return fsync(descriptor)
            with self.subTest(failure=failure), mock.patch.object(module.execution, 'cleanup'), \
                    mock.patch.object(module.delivery, 'Cloudflare') as provider:
                with mock.patch.object(os, 'fsync', side_effect=sync), self.assertRaises(OSError):
                    module.publish(self.api, self.env)
                self.assertTrue(intent.is_file())
                with self.assertRaises(FileExistsError): module.publish(self.api, self.env)
                provider.assert_not_called()
                self.assertFalse((self.work / 'published.json').exists())

    def test_all_effect_intents_share_exclusive_file_then_directory_sync(self):
        self.work.mkdir(mode=0o700)
        for name in ('allocation-intent.json', 'signing-intent.json', 'publication-intent.json'):
            events, fsync = [], os.fsync
            def sync(descriptor):
                events.append('directory' if stat.S_ISDIR(os.fstat(descriptor).st_mode) else 'file')
                return fsync(descriptor)
            with self.subTest(name=name), mock.patch.object(os, 'fsync', side_effect=sync):
                module.write(self.work / name, {'fixture': True})
                with self.assertRaises(FileExistsError): module.write(self.work / name, {'fixture': False})
            self.assertEqual(events, ['file', 'directory'])
            self.assertEqual(module.read(self.work / name), {'fixture': True})

    def test_ambiguous_provider_effect_is_retained_and_not_retried(self):
        self.private_fixture()
        with mock.patch.object(module.execution, 'cleanup'), \
                mock.patch.object(module.delivery, 'Cloudflare'), \
                mock.patch.object(module.delivery, 'publish', side_effect=module.delivery.DeliveryError('ambiguous')) as publish:
            with self.assertRaises(module.delivery.DeliveryError): module.publish(self.api, self.env)
            with self.assertRaises(FileExistsError): module.publish(self.api, self.env)
        publish.assert_called_once()
        self.assertTrue((self.work / 'publication-intent.json').is_file())
        self.assertFalse((self.work / 'published.json').exists())
        self.assertFalse(self.api.writes)

    def test_free_proof_failure_precedes_any_provider_effect(self):
        self.private_fixture()
        self.configuration.side_effect = module.delivery.DeliveryError('Free proof absent or expired')
        with mock.patch.object(module.delivery, 'Cloudflare') as provider, self.assertRaises(module.delivery.DeliveryError):
            module.publish(self.api, self.env)
        provider.assert_not_called()
        self.assertFalse((self.work / 'publication-intent.json').exists())

    def test_api_pagination_reads_every_page(self):
        api = module.GitHub('fixture')
        with mock.patch.object(api, 'request', side_effect=[list(range(100)), [100]]) as request:
            self.assertEqual(api.pages('/tags'), list(range(101)))
        self.assertEqual(request.call_args_list[-1].args[0], '/tags?per_page=100&page=2')

    def test_workflow_is_fixture_only_without_credentials_or_artifacts(self):
        text = (ROOT / module.WORKFLOW).read_text()
        self.assertIn('runs-on: macos-26', text)
        self.assertIn('persist-credentials: false', text)
        self.assertIn('test_release_candidate.py', text)
        for forbidden in ('secrets.', 'contents: write', 'permission-administration', 'upload-artifact@',
                          'scripts/release-candidate.py prepare', 'scripts/release-candidate.py sign',
                          'scripts/release-candidate.py publish', 'pull_request:', 'self-hosted'):
            self.assertNotIn(forbidden, text)
        for row in text.splitlines():
            if 'uses:' in row: self.assertRegex(row, r'@[0-9a-f]{40}(?: |$)')


class PrivateBoundaryTests(unittest.TestCase):
    def test_real_free_gate_rejects_missing_stale_future_wrong_account_or_long_proof(self):
        now = int(time.time())
        proof = dict(schema='shadow-sync/free-plan-observation/v1', account_id='a' * 32,
            observed_plan='Workers Free', source='owner-dashboard-observation', source_reference='synthetic fixture',
            observed_at=now - 10, expires_at=now + 100)
        config = dict(account_id='a' * 32, free_plan_proof='/fixture/proof.json')
        with mock.patch.object(module.delivery, 'private_json', return_value=proof):
            self.assertEqual(module.delivery.require_free(config, now=now), proof)
        for change in ({'expires_at': now}, {'observed_at': now + 1}, {'account_id': 'b' * 32},
                       {'expires_at': now + 3601}, {'observed_plan': 'Paid'}, {'source': 'unverified'}):
            with mock.patch.object(module.delivery, 'private_json', return_value=dict(proof, **change)), \
                    self.subTest(change=change), self.assertRaises(module.delivery.DeliveryError):
                module.delivery.require_free(config, now=now)
        with mock.patch.object(module.delivery, 'private_json', side_effect=FileNotFoundError), \
                self.assertRaises(module.delivery.DeliveryError):
            module.delivery.require_free(config, now=now)

    def test_existing_delivery_readback_then_final_admission_precedes_channel_write(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-private-route-') as folder:
            root = Path(folder).resolve(); root.chmod(0o700)
            assets = root / 'assets'; assets.mkdir(mode=0o700)
            payload = root / 'artifact'; payload.write_bytes(b'fixture private payload')
            digest = module.sha(payload)
            descriptor = lambda kind: dict(path=f'/v1/apps/{module.delivery.APP}/releases/fixture/{kind}',
                sha256=digest, size=payload.stat().st_size, ed25519_signature='A' * 86 + '==')
            value = dict(channel='qualification', build=15, qualification_id='fixture', source_revision=REVISION,
                         archive=descriptor('archive'), first_install=descriptor('package'))
            receipt = dict(schema='shadow-sync/qualification/v1', app_id=module.delivery.APP,
                qualification_id='fixture', source_revision=REVISION, build=15, archive_sha256=digest,
                archive_size=payload.stat().st_size, first_install_sha256=digest, first_install_size=payload.stat().st_size,
                checks={key: True for key in module.delivery.CHECKS})
            database = sqlite3.connect(':memory:'); database.row_factory = sqlite3.Row
            self.addCleanup(database.close)
            database.executescript((ROOT / 'delivery/schema.sql').read_text())
            events = []
            def query(sql, params=()):
                if 'INTO channels' in sql: events.append('channel-write')
                return [dict(row) for row in database.execute(sql, params).fetchall()]
            api = SimpleNamespace(config={'assets_directory': str(assets)}, query=query,
                require_free=lambda: None, deploy=lambda: events.append('deploy'), privacy=lambda: events.append('privacy'),
                readback=lambda *args: events.append('readback'))
            def admission():
                self.assertEqual(events[-2:], ['readback', 'readback'])
                raise module.Refusal('source changed')
            with mock.patch.object(module.delivery, 'outside_git', side_effect=Path), \
                    mock.patch.object(module.delivery, 'require_free'), \
                    mock.patch.object(module.delivery, 'validate_manifest', side_effect=lambda v: v):
                with self.assertRaises(module.Refusal):
                    module.delivery.publish(api, value, receipt, payload, payload, before_promote=admission)
                self.assertNotIn('channel-write', events)
                module.delivery.publish(api, value, receipt, payload, payload, before_promote=lambda: events.append('admitted'))
            self.assertEqual(events[-4:], ['readback', 'readback', 'admitted', 'channel-write'])
            self.assertEqual(query('SELECT release_id FROM channels'), [{'release_id': 'fixture'}])

    def test_single_run_prepares_then_secrets_only_in_sign_then_private_publish(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-release-cli-') as folder:
            root = Path(folder).resolve(); root.chmod(0o700); work = root / 'attempt'
            seen = []
            def stage(name):
                def call(api, env):
                    seen.append((name, {key for key in module.execution.CONFIG if key in env}))
                    if name == 'prepare': work.mkdir(mode=0o700)
                return call
            argv = ['release-candidate.py', 'run', '--source-revision', REVISION, '--attempt-id', '17',
                '--work-directory', str(work), '--delivery-config', str(root / 'config.json'),
                '--credentials', str(root / 'credentials.json')]
            with mock.patch.object(module.sys, 'argv', argv), \
                    mock.patch.dict(os.environ, {}, clear=True), \
                    mock.patch.object(module, 'work_directory', return_value=work), \
                    mock.patch.object(module, 'private_configuration'), \
                    mock.patch.object(module.delivery, 'private_json', side_effect=lambda p: dict.fromkeys(module.execution.CONFIG, 'fixture')), \
                    mock.patch.object(module, 'GitHub'), \
                    mock.patch.object(module, 'prepare', side_effect=stage('prepare')), \
                    mock.patch.object(module, 'sign', side_effect=stage('sign')), \
                    mock.patch.object(module, 'publish', side_effect=stage('publish')), \
                    mock.patch.object(module.execution, 'cleanup') as cleanup:
                self.assertEqual(module.main(), 0)
                cleanup.assert_called_once_with(work)
            self.assertEqual(seen, [('prepare', set()), ('sign', set(module.execution.CONFIG)), ('publish', set())])


class CommandEnvironmentTests(unittest.TestCase):
    """Real CLI/helper flow, with external commands replaced at Popen only.

    Each intercepted Git/Node/Apple/signer command launches a joined Python child
    in the *actual* inherited or explicit environment. No real tool is executed.
    Assembly/notary and provider effects produce only clearly synthetic fixtures.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-command-env-', dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); self.root.chmod(0o700)
        self.work = self.root / 'attempt'
        self.home = self.root / 'home'; self.home.mkdir(mode=0o700)
        self.node = self.root / 'node'; self.node.write_text('fixture; never executed'); self.node.chmod(0o700)
        self.wrangler = self.root / 'wrangler.js'; self.wrangler.write_text('fixture; never executed')
        assets = self.root / 'assets'; assets.mkdir(mode=0o700)
        self.config_path, self.credentials_path = self.root / 'config.json', self.root / 'credentials.json'
        self.record(self.config_path, dict(origin='https://fixture.example.invalid', account_id='a' * 32,
            database_id='11111111-1111-4111-8111-111111111111', database_name='fixture', worker_name='fixture',
            wrangler=str(self.wrangler), assets_directory=str(assets), free_plan_proof=str(self.root / 'free.json'),
            deployment_state=str(self.root / 'deployment.json')))
        now = int(time.time())
        self.record(self.root / 'free.json', dict(schema='shadow-sync/free-plan-observation/v1',
            account_id='a' * 32, observed_plan='Workers Free', source='owner-dashboard-observation',
            source_reference='synthetic fixture', observed_at=now - 10, expires_at=now + 100))
        team = module.assembly.json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier']
        self.identity = 'Developer ID Application: Fixture (' + team + ')'
        self.public = base64.b64encode(b'p' * 32).decode()
        self.record(self.credentials_path, dict(APPLE_CERTIFICATE=base64.b64encode(b'fixture certificate').decode(),
            APPLE_CERTIFICATE_PASSWORD='synthetic-password', APPLE_SIGNING_IDENTITY=self.identity,
            APPLE_ID='fixture@example.invalid', APPLE_PASSWORD='synthetic-password', APPLE_TEAM_ID=team,
            SPARKLE_PRIVATE_ED_KEY=base64.b64encode(b's' * 32).decode(), SPARKLE_PUBLIC_ED_KEY=self.public))
        self.env = dict(ENV, HOME=str(self.home), PATH='/usr/bin:/bin', TMPDIR=str(self.root),
            DEVELOPER_DIR='/fixture/toolchain', LANG='C', LC_ALL='C', SHADOW_SYNC_DELIVERY_NODE=str(self.node),
            GH_TOKEN='synthetic-allocation', OWNER_GITHUB_READ_TOKEN='synthetic-owner-read',
            CLOUDFLARE_API_TOKEN='synthetic-provider', UNRELATED_SECRET='synthetic-unrelated',
            NODE_OPTIONS='--require=/fixture/must-not-load', PYTHONPATH='/fixture/must-not-load',
            GIT_CONFIG_GLOBAL='/fixture/must-not-read', WRANGLER_OUTPUT_FILE_PATH='/fixture/must-not-write',
            RELEASE_WORK_DIRECTORY=str(self.work), RELEASE_DELIVERY_CONFIG=str(self.config_path))
        self.api, self.children, self.events, self.search_list = FakeGitHub(), [], [], []
        self.environment_violations = []
        self.failure, self.reached_failure = None, None
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        self.addCleanup(self.joined)
        self.stack.enter_context(mock.patch.object(module, 'source', return_value=DIGEST))
        self.stack.enter_context(mock.patch.object(module, 'immutable_enabled', return_value=ADMITTED['owner_controls']))
        self.stack.enter_context(mock.patch.object(module, 'GitHub', return_value=self.api))
        self.stack.enter_context(mock.patch.object(module.execution, 'PUBLIC_KEY_SHA256', hashlib.sha256(b'p' * 32).hexdigest()))
        signer = b'fixture detached signer; never executed'
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w') as bundle:
            member = tarfile.TarInfo('./bin/sign_update'); member.size = len(signer)
            bundle.addfile(member, io.BytesIO(signer))
        signer_archive = archive.getvalue()
        self.stack.enter_context(mock.patch.object(module.execution, 'ARCHIVE_SHA256', hashlib.sha256(signer_archive).hexdigest()))
        self.stack.enter_context(mock.patch.object(module.execution, 'SIGNER_SHA256', hashlib.sha256(signer).hexdigest()))
        package = b'fixture runtime package'
        self.stack.enter_context(mock.patch.object(module.assembly.runtime, 'load_pin', return_value=dict(
            package_url='https://www.python.org/ftp/python/fixture', package_bytes=len(package),
            package_sha256=hashlib.sha256(package).hexdigest())))
        def fetch(url, **kwargs):
            if url == module.execution.ARCHIVE_URL: return io.BytesIO(signer_archive)
            self.assertEqual(url, 'https://www.python.org/ftp/python/fixture')
            return io.BytesIO(package)
        self.stack.enter_context(mock.patch.object(module.urllib.request, 'urlopen', side_effect=fetch))
        self.stack.enter_context(mock.patch.object(module.assembly.build, 'prepare', side_effect=lambda work, *a:
            self.record(work / 'build.json', {'synthetic': True})))
        self.stack.enter_context(mock.patch.object(module.assembly.runtime, 'build'))
        self.stack.enter_context(mock.patch.object(module.assembly, 'assemble', side_effect=lambda args:
            self.record(Path(args.output) / 'release-assembly.json', {'synthetic': True})))
        self.stack.enter_context(mock.patch.object(module.notary, 'package', side_effect=self.package))
        self.stack.enter_context(mock.patch.object(module.notary, 'app_tree', return_value={'synthetic': True}))
        self.stack.enter_context(mock.patch.object(module.assembly, 'verify_code', side_effect=lambda path, *a:
            module.execution.command('fixture-code-verify', '/usr/bin/codesign', '--verify', path)))
        self.stack.enter_context(mock.patch.object(module.delivery, 'publish', side_effect=self.publication))
        self.popen = subprocess.Popen
        self.stack.enter_context(mock.patch.object(subprocess, 'Popen', side_effect=self.child))
        self.stack.enter_context(mock.patch.dict(os.environ, self.env, clear=True))

    def record(self, path, value):
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(json.dumps(value)); path.chmod(0o600)

    def package(self, args):
        if self.failure == 'notary':
            self.reached_failure = 'notary'
            raise module.Refusal('synthetic notary failure')
        artifact = self.work / 'notary/ShadowSync-0.10.0-build15-macos-arm64.dmg'
        artifact.parent.mkdir(mode=0o700); artifact.write_bytes(b'synthetic distribution, not a DMG')
        self.record(self.work / 'notary/app-stapled.json', {'entries': {'synthetic': True}})
        self.record(self.work / 'notary/release-package.json', dict(schema='shadow-sync-release-package/v1',
            revision=REVISION, source_sha256=DIGEST, assembly_sha256=module.sha(self.work / 'assembly/release-assembly.json'),
            packager_sha256=module.sha(ROOT / 'scripts/notarize-release-bundle.py'),
            publisher_team=module.assembly.json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier'],
            version='0.10.0', build='15', architecture='arm64', notarized=True, stapled=True, gatekeeper=True,
            published=False, installed=False, product_accepted=False,
            artifact=dict(name=artifact.name, bytes=artifact.stat().st_size, sha256=module.sha(artifact))))

    def publication(self, provider, *args, before_promote):
        self.assertEqual(provider._authorization, 'Bearer ' + self.env.get('CLOUDFLARE_API_TOKEN', 'synthetic-oauth'))
        # The real callback re-enters config/Git checks after provider auth exists.
        before_promote()
        if self.failure == 'provider':
            self.reached_failure = 'provider'
            raise module.delivery.DeliveryError('synthetic ambiguous publication')

    def child(self, args, **kwargs):
        args = [str(value) for value in args]
        environment = dict(os.environ if kwargs.get('env') is None else kwargs['env'])
        wrangler = len(args) > 1 and args[:2] == [str(self.node), str(self.wrangler)]
        forbidden = {'GH_TOKEN', 'OWNER_GITHUB_READ_TOKEN', 'UNRELATED_SECRET', 'NODE_OPTIONS',
                     'PYTHONPATH', 'GIT_CONFIG_GLOBAL', 'WRANGLER_OUTPUT_FILE_PATH', *module.execution.CONFIG}
        if not wrangler: forbidden.add('CLOUDFLARE_API_TOKEN')
        if forbidden & environment.keys():
            self.environment_violations.append((args[0], sorted(forbidden & environment.keys())))
        self.assertFalse(forbidden & environment.keys(), (args[0], forbidden & environment.keys()))
        self.assertEqual(environment['HOME'], str(self.home))
        safe = {'HOME', 'PATH', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL', 'SHADOW_SYNC_DELIVERY_NODE'}
        if wrangler:
            safe |= {'WRANGLER_SEND_METRICS', 'WRANGLER_SEND_ERROR_REPORTS', 'WRANGLER_WRITE_LOGS',
                'WRANGLER_LOG', 'WRANGLER_LOG_SANITIZE', 'CLOUDFLARE_API_BASE_URL', 'CF_API_BASE_URL',
                'CI', 'NO_COLOR', 'CLOUDFLARE_ACCOUNT_ID', 'CLOUDFLARE_API_TOKEN'}
            self.assertEqual(environment.get('CLOUDFLARE_API_TOKEN'), self.env.get('CLOUDFLARE_API_TOKEN'))
        self.assertFalse(environment.keys() - safe)
        output, status, effect = '', 0, ''
        if args[0] == 'git':
            kind, status = 'git', 128
            self.assertEqual(args[1:2] + args[-2:], ['-C', 'rev-parse', '--show-toplevel'])
        elif args[0] == str(self.node):
            if wrangler:
                kind = 'wrangler'
                if args[2:] == ['--version']: output = module.delivery.WRANGLER
                else:
                    self.assertEqual(args[2:], ['auth', 'token', '--json'])
                    output = json.dumps(dict(type='api_token' if 'CLOUDFLARE_API_TOKEN' in self.env else 'oauth',
                        token=self.env.get('CLOUDFLARE_API_TOKEN', 'synthetic-oauth')))
            elif args[1:] == ['--version']: kind, output = 'node-version', 'v26.4.0\n'
            elif args[1] == '--input-type=module': kind = 'node-manifest'
            elif args[1] == '-e': kind = 'node-signature'
            else: raise AssertionError(args)
        elif args[0] == str(self.work / 'sign_update'):
            kind, output = 'detached-signer', base64.b64encode(bytes(64)).decode()
        elif args[0] == '/usr/bin/ditto':
            kind = 'archive'
            target = Path(args[-1]); self.assertEqual(target, self.work / 'ShadowSync.zip')
            effect = 'Path(' + repr(str(target)) + ").write_bytes(b'synthetic archive')\n"
        elif args[0] == '/usr/bin/security':
            kind = 'security'
            if args[1] == 'create-keychain':
                self.assertEqual(Path(args[-1]), self.work / 'readiness.keychain-db')
                effect = 'Path(' + repr(args[-1]) + ").write_bytes(b'synthetic keychain')\n"
            elif args[1] == 'delete-keychain':
                self.assertEqual(Path(args[-1]), self.work / 'readiness.keychain-db')
                effect = 'Path(' + repr(args[-1]) + ').unlink()\n'
            elif args[1] == 'list-keychains':
                if '-s' in args: self.search_list = args[args.index('-s') + 1:]
                else: output = '\n'.join(json.dumps(path) for path in self.search_list)
            elif args[1] == 'find-identity': output = '  1) ' + 'A' * 40 + ' "' + self.identity + '"\n'
            else: self.assertIn(args[1], ('set-keychain-settings', 'unlock-keychain', 'import', 'set-key-partition-list'))
        elif args[0] in ('/usr/bin/codesign', '/usr/bin/xcrun'): kind = 'apple-fixture'
        else: raise AssertionError('Unexpected external command: ' + args[0])
        self.events.append((kind, set(environment)))
        code = ('import os,sys\nfrom pathlib import Path\n'
            + 'assert not set(' + repr(sorted(forbidden)) + ') & os.environ.keys()\n'
            + 'assert os.environ["HOME"] == ' + repr(str(self.home)) + '\n'
            + effect + 'sys.stdout.write(' + repr(output) + ')\nsys.exit(' + str(status) + ')\n')
        # Keep the original pipes, session and communicate/wait owners. Only the
        # executable is substituted, before any Git/Node/Apple/provider launch.
        child = self.popen([sys.executable, '-I', '-B', '-c', code], **kwargs)
        self.children.append(child)
        return child

    def joined(self):
        pending = [child for child in self.children if child.poll() is None]
        for child in pending:
            child.kill(); child.communicate(timeout=10)
        self.assertFalse(pending, 'Every fixture child must be joined by its original caller')

    def invoke(self, stage):
        argv = ['release-candidate.py', stage, '--source-revision', REVISION, '--attempt-id', '17',
            '--work-directory', str(self.work), '--delivery-config', str(self.config_path)]
        if stage in ('run', 'sign'): argv += ['--credentials', str(self.credentials_path)]
        with mock.patch.object(module.sys, 'argv', argv), \
                mock.patch.object(sys, 'stdout', io.StringIO()), mock.patch.object(sys, 'stderr', io.StringIO()):
            result = module.main()
        self.assertEqual(dict(os.environ), self.env)
        self.joined()
        self.assertFalse(self.environment_violations)
        return result

    def seed(self, signing=False):
        module.prepare(self.api, self.env)
        if signing:
            module.sign(self.api, dict(self.env, **json.loads(self.credentials_path.read_text())))
        self.events.clear()

    def test_prepare_closes_environment_before_real_path_and_config_helpers(self):
        self.assertEqual(self.invoke('prepare'), 0)
        self.assertIn('git', [kind for kind, _ in self.events])
        self.assertTrue((self.work / 'prepared.json').is_file())

    def test_sign_closes_environment_before_real_credential_read_and_signer(self):
        self.seed()
        self.assertEqual(self.invoke('sign'), 0)
        kinds = {kind for kind, _ in self.events}
        self.assertTrue({'git', 'security', 'node-manifest', 'node-signature', 'detached-signer'} <= kinds)
        self.assertNotIn('wrangler', kinds)
        self.assertFalse((self.work / 'readiness.keychain-db').exists())
        self.assertTrue((self.work / 'credentials-removed.json').is_file())

    def test_publish_keeps_provider_token_only_in_real_wrangler_child_boundary(self):
        self.seed(signing=True)
        self.assertEqual(self.invoke('publish'), 0)
        kinds = {kind for kind, _ in self.events}
        self.assertTrue({'git', 'node-manifest', 'node-signature', 'wrangler'} <= kinds)
        self.assertTrue((self.work / 'published.json').is_file())

    def test_run_uses_all_real_helper_boundaries_with_closed_environments(self):
        self.assertEqual(self.invoke('run'), 0)
        kinds = {kind for kind, _ in self.events}
        self.assertTrue({'git', 'security', 'detached-signer', 'node-manifest', 'node-signature', 'wrangler'} <= kinds)
        self.assertTrue((self.work / 'published.json').is_file())

    def test_original_home_oauth_remains_available_without_provider_environment_token(self):
        self.env.pop('CLOUDFLARE_API_TOKEN'); os.environ.pop('CLOUDFLARE_API_TOKEN')
        self.seed(signing=True)
        self.assertEqual(self.invoke('publish'), 0)
        self.assertTrue(any(kind == 'wrangler' for kind, _ in self.events))

    def test_failed_signing_runs_real_cleanup_in_closed_environment_and_restores_parent(self):
        self.failure = 'notary'
        self.assertEqual(self.invoke('run'), 1)
        self.assertEqual(self.reached_failure, 'notary')
        self.assertFalse((self.work / 'readiness.keychain-db').exists())
        self.assertFalse((self.work / 'certificate.p12').exists())
        self.assertFalse((self.work / 'credentials-removed.json').exists())
        self.assertFalse((self.work / 'published.json').exists())
        self.assertEqual(self.search_list, [])
        self.assertNotIn('wrangler', {kind for kind, _ in self.events})

    def test_failed_publication_restores_parent_and_retains_no_replay_intent(self):
        self.seed(signing=True)
        self.failure = 'provider'
        self.assertEqual(self.invoke('publish'), 1)
        self.assertEqual(self.reached_failure, 'provider')
        self.assertTrue((self.work / 'publication-intent.json').is_file())
        self.events.clear()
        self.assertEqual(self.invoke('publish'), 1)
        self.assertNotIn('wrangler', {kind for kind, _ in self.events})
        self.assertFalse((self.work / 'published.json').exists())


class OwnerControlsTests(unittest.TestCase):
    def test_github_client_refuses_redirect_handler_and_changed_response_url(self):
        with self.assertRaises(module.Refusal):
            module.NoRedirect().redirect_request(None, None, 302, 'fixture', {}, 'https://other.example.invalid')
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b'{}'
        response.geturl.return_value = 'https://other.example.invalid'
        opener = mock.Mock(); opener.open.return_value = response
        with mock.patch.object(module.urllib.request, 'build_opener', return_value=opener), self.assertRaises(module.Refusal):
            module.GitHub('synthetic-fixture').request('')

    def test_provider_explicit_auth_rejects_unrelated_capabilities_before_children(self):
        for authentication in ({'GH_TOKEN': 'synthetic'}, {'NODE_OPTIONS': 'synthetic'},
                {'CLOUDFLARE_API_TOKEN': ''}, {'CLOUDFLARE_API_TOKEN': 'synthetic\n'},
                {'CLOUDFLARE_API_TOKEN': 1}):
            with self.subTest(keys=sorted(authentication)), mock.patch.object(module.delivery, 'pinned_node') as node, \
                    self.assertRaises(module.delivery.DeliveryError):
                module.delivery.Cloudflare({}, wrangler_auth=authentication)
            node.assert_not_called()

    def test_live_owner_controls_and_no_app_capability(self):
        client = mock.Mock()
        values = {'/owner-principal': dict(login='KleinPerkins', id=49759187, type='User'),
            '': dict(id=module.REPO_ID, full_name=module.REPO, permissions={'admin': True}),
            '/immutable-releases': {'enabled': True},
            '/rulesets/1': dict(id=1, target='tag', enforcement='active', bypass_actors=[],
                conditions={'ref_name': {'include': ['refs/tags/candidate-v*'], 'exclude': []}},
                rules=[{'type': 'update'}, {'type': 'deletion'}])}
        client.pages.return_value = [{'id': 1}]
        client.request.side_effect = lambda path: values[path]
        with mock.patch.object(module, 'GitHub', return_value=client) as factory, \
                mock.patch.object(module.controls, 'verify_controls') as controls:
            module.immutable_enabled(dict(OWNER_GITHUB_READ_TOKEN='fixture'))
            factory.assert_called_once_with('fixture', read_only=True)
            controls.assert_called_once_with(values[''], client.pages.return_value)
            for path, field, bad in [('/owner-principal', 'type', 'Bot'),
                    ('/immutable-releases', 'enabled', False), ('/rulesets/1', 'bypass_actors', [{'actor_id': 1}]),
                    ('/rulesets/1', 'enforcement', 'disabled')]:
                original = values[path][field]; values[path][field] = bad
                with self.subTest(path=path, field=field), self.assertRaises(module.Refusal):
                    module.immutable_enabled(dict(OWNER_GITHUB_READ_TOKEN='fixture'))
                values[path][field] = original

    def test_read_client_cannot_write_and_no_client_can_upload(self):
        for api, path in [(module.GitHub('fixture', read_only=True), '/releases'),
                          (module.GitHub('fixture'), '/releases/1/assets?name=private.dmg')]:
            with self.assertRaises(module.Refusal): api.request(path, method='POST', data={})


if __name__ == '__main__':
    unittest.main()
