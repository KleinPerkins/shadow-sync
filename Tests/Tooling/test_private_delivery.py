"""Credential-free Worker/API and owner administration contract checks."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('owner_delivery', ROOT / 'scripts/delivery.py')
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
toolchain_spec = importlib.util.spec_from_file_location('delivery_toolchain', ROOT / 'scripts/delivery-toolchain.py')
toolchain = importlib.util.module_from_spec(toolchain_spec)
toolchain_spec.loader.exec_module(toolchain)


def node():
    return str(ChannelTests.node_binary)


class MemoryAPI:
    def __init__(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.db.executescript((ROOT / 'delivery/schema.sql').read_text())
        self.calls = []
        self.uploads = []
        self.checked_privacy = False
        self.readbacks = []
        self.events = []
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name).resolve()
        self.assets = self.root / 'assets'
        self.assets.mkdir(mode=0o700)
        self.config = config_fixture(self.root)
        self.uploads = []

    def query(self, sql, params=()):
        self.calls.append((sql, params))
        self.events.append(sql.split()[0] + ':' + ('channels' if 'INTO channels' in sql else 'releases' if 'INTO releases' in sql else 'query'))
        cursor = self.db.execute(sql, params)
        return [dict(row) for row in cursor.fetchall()]

    def privacy(self):
        self.checked_privacy = True

    def require_free(self):
        return delivery.require_free(self.config)

    def deploy(self):
        self.require_free()
        self.events.append('deploy')
        self.uploads = list(delivery.asset_inventory(self.config))

    def readback(self, release_id, descriptor, kind):
        self.events.append('readback')
        self.readbacks.append((release_id, descriptor, kind))


def config_fixture(root):
    assets = root / 'assets'
    assets.mkdir(mode=0o700, exist_ok=True)
    now = int(time.time())
    proof = dict(schema='shadow-sync/free-plan-observation/v1', account_id='a' * 32,
                 observed_plan='Workers Free', source='owner-dashboard-observation',
                 source_reference='owner-chat:synthetic-fixture-not-live-evidence', observed_at=now - 1, expires_at=now + 300)
    filename = root / 'free.json'
    if not filename.exists(): delivery.private_write(filename, proof)
    return dict(origin='https://monitor.owned-fixture.workers.dev', worker_name='monitor',
                account_id='a' * 32, database_name='fixture', database_id='b' * 36,
                assets_directory=str(assets), free_plan_proof=str(filename),
                deployment_state=str(root / 'deployment.json'), wrangler='/fixture/wrangler')


def release(channel='qualification'):
    sig = __import__('base64').b64encode(bytes(64)).decode()
    artifact = {'size': 4, 'sha256': hashlib.sha256(b'test').hexdigest(), 'ed25519_signature': sig}
    return dict(schema='shadow-sync/release/v1', app_id=delivery.APP, bundle_id=delivery.APP,
        team_id='J2V7GRV5CM', channel=channel, version='1.2', build=2, minimum_macos='26.0', architecture='arm64',
        data_schema_version=1, source_revision='a' * 40, qualification_id='fixture-q', qualified=channel == 'stable',
        archive=dict(artifact, path=f'/v1/apps/{delivery.APP}/releases/release-2/archive'),
        first_install=dict(artifact, path=f'/v1/apps/{delivery.APP}/releases/release-2/package'))


def receipt(value):
    return dict(schema='shadow-sync/qualification/v1', app_id=delivery.APP,
        qualification_id=value['qualification_id'], source_revision=value['source_revision'], build=value['build'],
        archive_sha256=value['archive']['sha256'], archive_size=value['archive']['size'],
        first_install_sha256=value['first_install']['sha256'], first_install_size=value['first_install']['size'],
        checks=dict.fromkeys(delivery.CHECKS, True))


class ChannelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime_folder = tempfile.TemporaryDirectory(prefix='shadow-sync-delivery-node-')
        cls.addClassCleanup(cls.runtime_folder.cleanup)
        cls.node_binary = toolchain.node(cache=Path(cls.runtime_folder.name).resolve())

    def setUp(self):
        isolated_git = patch.dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_NO_REPLACE_OBJECTS='1', SHADOW_SYNC_DELIVERY_NODE=str(self.node_binary))
        isolated_git.start()
        self.addCleanup(isolated_git.stop)
        self.api = MemoryAPI()
        self.addCleanup(self.api.db.close)
        self.addCleanup(self.api.folder.cleanup)

    def test_actual_worker_primary_reads_auth_cache_isolation_and_errors(self):
        result = subprocess.run([node(), str(ROOT / 'Tests/Fixtures/private_delivery_worker.mjs')], cwd=ROOT,
            capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)
        self.assertTrue(evidence['passed'])
        self.assertGreaterEqual(evidence['assertions'], 45)
        self.assertGreater(evidence['primary_reads'], 20)

    def test_closed_wire_contract_rejects_cross_release_and_unknown_fields(self):
        value = release()
        delivery.validate_manifest(value)
        for version in ('1', '0.1', '2.10.1', '1.2.3.4'):
            delivery.validate_manifest(dict(value, version=version))
        for bad in (dict(value, version='01.2'), dict(value, version='1.2.3.4.5'),
                    dict(value, unexpected='no'), dict(value, qualification_id='dots.are.invalid')):
            with self.assertRaises(delivery.DeliveryError):
                delivery.validate_manifest(bad)
        bad = release()
        bad['first_install']['path'] = bad['first_install']['path'].replace('release-2', 'release-3')
        with self.assertRaises(delivery.DeliveryError):
            delivery.validate_manifest(bad)
        bad = release()
        bad['archive']['url'] = 'https://elsewhere.invalid/'
        with self.assertRaises(delivery.DeliveryError):
            delivery.validate_manifest(bad)

    def test_grant_credential_256_bits_hashed_at_rest_and_private_output(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder).resolve() / 'friend.shadow-sync-access'
            capture = io.StringIO()
            with contextlib.redirect_stdout(capture):
                grant = delivery.create_grant(self.api, self.api.config, 'friend-opaque', path, int(time.time()) + 3600)
            data = json.loads(path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(__import__('base64').urlsafe_b64decode(data['token'] + '=')), 32)
            self.assertNotIn(data['token'], repr(self.api.calls))
            self.assertNotIn(data['token'], capture.getvalue())
            row = self.api.query('SELECT * FROM grants WHERE grant_id=?', (grant,))[0]
            self.assertEqual(row['token_hash'], hashlib.sha256(data['token'].encode()).hexdigest())
            self.assertEqual(row['is_owner'], 0)
            with self.assertRaises(delivery.DeliveryError):
                delivery.create_grant(self.api, self.api.config, 'friend-opaque', path, int(time.time()) + 3600)

    def test_access_file_and_config_cannot_be_written_under_git_or_symlinks(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-delivery-git-') as folder:
            repository = Path(folder).resolve()
            subprocess.run(['git', 'init', '--quiet', str(repository)], check=True, capture_output=True)
            with self.assertRaises(delivery.DeliveryError):
                delivery.private_write(repository / 'forbidden.shadow-sync-access', {})
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            actual = root / 'actual'
            actual.write_text('preserve')
            link = root / 'link'
            link.symlink_to(actual)
            with self.assertRaises(delivery.DeliveryError):
                delivery.private_write(link, {})
            self.assertEqual(actual.read_text(), 'preserve')
            config = root / 'config.json'
            config.write_text('{}')
            config.chmod(0o644)
            with self.assertRaises(delivery.DeliveryError):
                delivery.load_config(config)

    def test_qualification_grants_are_owner_only_and_finite(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder).resolve() / 'fixture.shadow-sync-access'
            for owner, expiry in ((False, int(time.time()) + 3600), (True, 1)):
                with self.assertRaises(delivery.DeliveryError):
                    delivery.create_grant(self.api, self.api.config, 'fixture', path, expiry, owner, 'qualification')
            self.assertEqual(self.api.query('SELECT * FROM grants'), [])

    def test_exact_qualification_then_stable_promotion_and_downgrade_refusal(self):
        value = release()
        proof = receipt(value)
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder) / 'artifact'
            artifact.write_bytes(b'test')
            delivery.publish(self.api, value, proof, artifact, artifact)
        self.assertTrue(self.api.checked_privacy)
        self.assertEqual(len(self.api.uploads), 2)
        stable = dict(value, channel='stable', qualified=True)
        with self.assertRaises(delivery.DeliveryError):
            delivery.publish(self.api, stable, proof)
        proof['checks'].update(dict.fromkeys(delivery.FRIEND_CHECKS, True))
        tampered = dict(stable, source_revision='b' * 40)
        with self.assertRaises(delivery.DeliveryError):
            delivery.publish(self.api, tampered, receipt(tampered))
        delivery.publish(self.api, stable, proof)
        self.assertEqual(len(self.api.uploads), 2, 'stable cannot upload different bytes')
        self.assertEqual(len(self.api.readbacks), 4, 'qualification and stable both reverify retained bytes')
        self.assertLess(self.api.events.index('deploy'), self.api.events.index('INSERT:releases'))
        self.assertLess(self.api.events.index('readback'), self.api.events.index('INSERT:channels'))
        delivery.publish(self.api, stable, proof)  # exact retry is idempotent
        self.assertEqual(self.api.query("SELECT release_id FROM channels WHERE channel='stable'")[0]['release_id'], 'release-2')
        older = release()
        older['build'] = 1
        older['archive']['path'] = older['archive']['path'].replace('release-2', 'release-1')
        older['first_install']['path'] = older['first_install']['path'].replace('release-2', 'release-1')
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder) / 'artifact'
            artifact.write_bytes(b'test')
            with self.assertRaises(delivery.DeliveryError):
                delivery.publish(self.api, older, receipt(older), artifact, artifact)
        self.assertEqual(self.api.query("SELECT release_id FROM channels WHERE channel='qualification'")[0]['release_id'], 'release-2')

    def test_unqualified_or_mismatched_artifact_never_published(self):
        value = release()
        for key in delivery.CHECKS:
            bad = receipt(value)
            bad['checks'][key] = False
            with self.assertRaises(delivery.DeliveryError):
                delivery.publish(self.api, value, bad)
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder) / 'wrong'
            artifact.write_bytes(b'wrong')
            with self.assertRaises(delivery.DeliveryError):
                delivery.publish(self.api, value, receipt(value), artifact, artifact)
        self.assertEqual(self.api.query('SELECT * FROM releases'), [])
        self.assertEqual(self.api.uploads, [])

    def test_friend_channel_requires_every_standalone_acceptance_gate(self):
        value = release('stable')
        for gate in delivery.FRIEND_CHECKS:
            for invalid in (False, None, 1, 'true', 'missing'):
                proof = receipt(value)
                proof['checks'].update(dict.fromkeys(delivery.FRIEND_CHECKS, True))
                if invalid == 'missing':
                    del proof['checks'][gate]
                else:
                    proof['checks'][gate] = invalid
                before = list(self.api.calls)
                with self.subTest(gate=gate, invalid=invalid), self.assertRaisesRegex(
                        delivery.DeliveryError, 'installation, recovery, migration and operator acceptance'):
                    delivery.publish(self.api, value, proof)
                self.assertEqual(self.api.calls, before)
                self.assertEqual(self.api.uploads, [])

    def test_free_proof_blocks_every_mutation_and_no_boolean_bypass(self):
        config = self.api.config
        original = delivery.private_json(config['free_plan_proof'])
        invalid = [{}, dict(original, observed_plan='Workers Paid'), dict(original, account_id='c' * 32),
                   dict(original, observed_at=1, expires_at=100), dict(original, observed_at=int(time.time()) + 30),
                   dict(original, expires_at=original['observed_at'] + 3601), dict(original, source='assume-free'),
                   dict(original, assume_free=True)]
        api = delivery.Cloudflare.__new__(delivery.Cloudflare)
        api.config = config
        api._opener = MagicMock()
        for proof in invalid:
            Path(config['free_plan_proof']).write_text(json.dumps(proof))
            for operation in (lambda: api.api('/d1/database', {'name': 'new'}),
                              lambda: api.query('CREATE TABLE forbidden(x)'), lambda: api.create_database('new'),
                              lambda: api.create_subdomain('new'), lambda: api.deploy(),
                              lambda: api.wrangler('deploy', '--config', '/unused'),
                              lambda: delivery.publish(api, release(), receipt(release())),
                              lambda: delivery.create_grant(api, config, 'fixture', self.api.root / 'unused', int(time.time()) + 30)):
                with self.assertRaises(delivery.DeliveryError): operation()
            api._opener.open.assert_not_called()
        Path(config['free_plan_proof']).write_text(json.dumps(original))
        self.assertEqual(delivery.require_free(config)['source'], 'owner-dashboard-observation')
        with self.assertRaises(delivery.DeliveryError):
            api.wrangler('r2', 'object', 'put', 'forbidden')
        with self.assertRaises(delivery.DeliveryError):
            api.api('/subscriptions', {'plan': 'paid'})
        with self.assertRaises(delivery.DeliveryError):
            delivery.NoRedirect().redirect_request(None, None, None, None, None, None)

    def test_bootstrap_only_creates_new_free_resources_with_capacity(self):
        api = delivery.Cloudflare.__new__(delivery.Cloudflare);api.config=self.api.config
        with patch.object(api,'api',side_effect=[[],{'uuid':'synthetic-only'}]) as calls:
            self.assertEqual(api.create_database('new-fixture'),{'uuid':'synthetic-only'})
            self.assertEqual(calls.call_args.args,('/d1/database',{'name':'new-fixture'},'POST'))
        for databases in ([{'name':'new-fixture'}], [{'name':'x'}] * 10, None):
            with patch.object(api,'api',return_value=databases) as calls, self.assertRaises(delivery.DeliveryError):api.create_database('new-fixture')
            self.assertEqual(calls.call_count,1)
        with patch.object(api,'api',side_effect=[None,{'subdomain':'new-fixture'}]) as calls:
            self.assertEqual(api.create_subdomain('new-fixture')['subdomain'],'new-fixture')
            self.assertEqual(calls.call_args.args,('/workers/subdomain',{'subdomain':'new-fixture'},'PUT'))
        with patch.object(api,'api',return_value={'subdomain':'existing'}) as calls, self.assertRaises(delivery.DeliveryError):api.create_subdomain('new-fixture')
        self.assertEqual(calls.call_count,1)
        for unknown in ({},{'subdomain':''},[],False):
            with patch.object(api,'api',return_value=unknown) as calls,self.assertRaises(delivery.DeliveryError):api.create_subdomain('new-fixture')
            self.assertEqual(calls.call_count,1)

    def test_initial_missing_resource_requires_exact_provider_error(self):
        api=delivery.Cloudflare.__new__(delivery.Cloudflare);api.config=self.api.config
        api._authorization='Bearer synthetic-only';api._opener=MagicMock()
        def refused(status=404,codes=(10007,),success=False,body=None):
            value={'success':success,'errors':[{'code':code} for code in codes],'result':None}
            return urllib.error.HTTPError('https://api.cloudflare.com/client/v4',status,'synthetic',{},io.BytesIO(body or json.dumps(value).encode()))
        for path in ('/workers/subdomain','/workers/scripts/monitor/deployments'):
            with patch.object(api._opener,'open',side_effect=refused()):self.assertIsNone(api.api(path,allow_not_found=True))
            response=MagicMock();response.__enter__.return_value.read.return_value=b'{"success":true,"result":null}'
            with patch.object(api._opener,'open',return_value=response),self.assertRaises(delivery.DeliveryError):api.api(path,allow_not_found=True)
            for error in (refused(403),refused(codes=(10000,)),refused(codes=(10007,10000)),refused(success=True),refused(body=b'not-json')):
                with patch.object(api._opener,'open',side_effect=error),self.assertRaises(delivery.DeliveryError):api.api(path,allow_not_found=True)
            with patch.object(api._opener,'open',side_effect=refused()),self.assertRaises(delivery.DeliveryError):api.api(path)
        with patch.object(api._opener,'open',side_effect=refused()),self.assertRaises(delivery.DeliveryError):api.api('/d1/database',allow_not_found=True)
        response=MagicMock();response.__enter__.return_value.read.return_value=b'{"success":true,"result":null}'
        with patch.object(api._opener,'open',return_value=response) as calls,self.assertRaises(delivery.DeliveryError):api.create_subdomain('new-fixture')
        self.assertEqual(calls.call_count,1)

    def test_private_readback_identifies_application_and_revokes_temporary_grant(self):
        api=delivery.Cloudflare.__new__(delivery.Cloudflare);api.config=self.api.config;api._opener=MagicMock()
        digest=hashlib.sha256(b'test').hexdigest()
        table=dict(schema='shadow-sync/artifact-parts/v2',app_id=delivery.APP,release_id='fixture',kind='archive',
                   artifact_sha256=digest,artifact_size=4,part_size=delivery.PIECE_SIZE,parts=[dict(index=0,size=4,sha256=digest)])
        metadata=MagicMock();metadata.status=200;metadata.read.return_value=json.dumps(table).encode()
        response=MagicMock();response.status=200;response.headers={'Content-Length':'4'};response.read.side_effect=[b'test',b'']
        first,second=MagicMock(),MagicMock();first.__enter__.return_value=metadata;second.__enter__.return_value=response
        api._opener.open.side_effect=[first,second]
        with patch.object(api,'query',return_value=[]) as queries:
            api.readback('fixture',{'size':4,'sha256':hashlib.sha256(b'test').hexdigest()},'archive')
        request=api._opener.open.call_args.args[0]
        self.assertEqual(request.get_header('User-agent'),'MachineMonitor-Delivery/1.0')
        self.assertEqual(request.full_url,self.api.config['origin']+'/v1/apps/'+delivery.APP+'/releases/fixture/archive/parts/0')
        self.assertTrue(request.get_header('Authorization').startswith('Bearer '))
        self.assertNotIn(request.get_header('Authorization')[7:],repr(queries.call_args_list))
        self.assertIn('revoked_at',queries.call_args.args[0])
        self.assertEqual(len(delivery.validate_piece_descriptor(json.dumps(table).encode(),'fixture','archive',{'size':4,'sha256':digest})),1)
        for change in ({'part_size':True},{'artifact_size':True},{'parts':[]},{'extra':1},{'kind':'package'},
                       {'parts':[dict(index=False,size=4,sha256=digest)]},{'parts':[dict(index=0,size=5,sha256=digest)]}):
            with self.assertRaises(delivery.DeliveryError):
                delivery.validate_piece_descriptor(json.dumps(dict(table,**change)).encode(),'fixture','archive',{'size':4,'sha256':digest})
        with self.assertRaises(delivery.DeliveryError):
            delivery.validate_piece_descriptor(json.dumps(table).replace('"part_size":','"part_size":1,"part_size":').encode(),'fixture','archive',{'size':4,'sha256':digest})

    def test_maximum_v2_metadata_and_canonical_asset_indexes(self):
        release_id = 'x' * 128
        digest = 'a' * 64
        descriptor = {'size': delivery.MAX_ARCHIVE, 'sha256': digest}
        rows = [dict(index=i, size=delivery.PIECE_SIZE, sha256=digest) for i in range(2048)]
        table = dict(schema='shadow-sync/artifact-parts/v2', app_id=delivery.APP,
                     release_id=release_id, kind='archive', artifact_sha256=digest,
                     artifact_size=delivery.MAX_ARCHIVE, part_size=delivery.PIECE_SIZE, parts=rows)
        raw = json.dumps(table, separators=(',', ':')).encode()
        self.assertLess(len(raw), delivery.WIRE_LIMIT)
        self.assertEqual(len(delivery.validate_piece_descriptor(raw, release_id, 'archive', descriptor)), 2048)
        self.assertEqual(len(delivery.validate_piece_descriptor(raw + b' ' * (delivery.WIRE_LIMIT - len(raw)), release_id, 'archive', descriptor)), 2048)
        for changed in (dict(table, schema='shadow-sync/artifact-parts/v1'),
                        dict(table, part_size=1048576), dict(table, parts=rows+[rows[0]]),
                        dict(table, parts=rows[:-1]+[dict(rows[-1], index=2048)])):
            with self.assertRaises(delivery.DeliveryError):
                delivery.validate_piece_descriptor(json.dumps(changed).encode(), release_id, 'archive', descriptor)
        with self.assertRaises(delivery.DeliveryError):
            delivery.validate_piece_descriptor(raw + b' ' * (delivery.WIRE_LIMIT-len(raw)+1), release_id, 'archive', descriptor)
        root = Path(self.api.config['assets_directory']) / '_private' / delivery.APP / release_id / 'archive' / digest
        root.mkdir(parents=True, mode=0o700)
        for directory in (Path(self.api.config['assets_directory']), *Path(self.api.config['assets_directory']).rglob('*')):
            if directory.is_dir():directory.chmod(0o700)
        content_hash = hashlib.sha256(b'x').hexdigest()
        for index in ('2047', '2048', '02047', '9999'):
            path = root / (index + '-' + content_hash + '.part')
            path.write_bytes(b'x');path.chmod(0o600)
            if index == '2047':
                self.assertEqual(len(delivery.asset_inventory(self.api.config)), 1)
            else:
                with self.assertRaises(delivery.DeliveryError):delivery.asset_inventory(self.api.config)
            path.unlink()

    def test_interrupted_protocol_publication_retries_without_relabeling_legacy(self):
        for failure in ('INSERT OR IGNORE INTO artifact_protocols', 'SELECT descriptor_schema,part_size', 'INSERT OR IGNORE INTO artifact_parts'):
            with self.subTest(failure=failure):
                api = MemoryAPI()
                try:
                    value = release()
                    source = api.root / 'artifact.zip';source.write_bytes(b'test')
                    original = api.query
                    def interrupted(sql, params=()):
                        if sql.startswith(failure):raise delivery.DeliveryError('Synthetic interruption')
                        return original(sql, params)
                    with patch.object(api, 'query', side_effect=interrupted), self.assertRaises(delivery.DeliveryError):
                        delivery.publish(api, value, receipt(value), source, source)
                    self.assertEqual(original('SELECT * FROM channels'), [])
                    self.assertEqual(original('SELECT * FROM releases'), [])
                    self.assertEqual(original('SELECT * FROM artifact_parts'), [])
                    markers = original('SELECT * FROM artifact_protocols')
                    self.assertEqual(len(markers), 0 if failure.startswith('INSERT OR IGNORE INTO artifact_protocols') else 1)
                    delivery.publish(api, value, receipt(value), source, source)
                    self.assertEqual(len(original('SELECT * FROM artifact_parts')), 2)
                    self.assertEqual(len(original('SELECT * FROM artifact_protocols')), 2)
                    self.assertEqual(len(original('SELECT * FROM channels')), 1)
                finally:
                    api.db.close();api.folder.cleanup()

    def test_legacy_identity_cannot_be_relabeled_even_for_tiny_artifacts(self):
        value = release()
        source = self.api.root / 'legacy.zip';source.write_bytes(b'test')
        release_id = value['archive']['path'].split('/')[-2]
        descriptor = value['archive']
        parts = [dict(index=0, size=4, sha256=descriptor['sha256'],
            path=f"/_private/{delivery.APP}/{release_id}/archive/{descriptor['sha256']}/0-{descriptor['sha256']}.part")]
        self.api.query('INSERT INTO artifact_parts VALUES(?,?,?,?,?)',
                       (delivery.APP, release_id, 'archive', descriptor['sha256'], json.dumps(parts)))
        with self.assertRaises(delivery.DeliveryError):
            delivery.publish(self.api, value, receipt(value), source, source)
        self.assertNotIn('deploy', self.api.events)
        self.assertEqual(self.api.query('SELECT * FROM artifact_protocols'), [])
        self.assertEqual(source.read_bytes(), b'test')

    def test_deployment_requires_unconditional_private_worker_first_and_owned_origin(self):
        config = self.api.config
        api = delivery.Cloudflare.__new__(delivery.Cloudflare);api.config = config
        with patch.object(api, 'api', return_value={'subdomain': 'owned-fixture'}):
            result = delivery.deployment_config(config, api)
        self.assertTrue(result['workers_dev']);self.assertFalse(result['preview_urls'])
        self.assertEqual(result['routes'], [])
        self.assertEqual(result['d1_databases'][0]['binding'], 'DB')
        self.assertEqual(result['assets']['binding'], 'ASSETS')
        self.assertIs(result['assets']['run_worker_first'], True)
        self.assertNotIn('r2_buckets', result)
        for mutation in ({'run_worker_first': False}, {'run_worker_first': ['/v1/*', '!/_private/*']},
                         {'not_found_handling': 'single-page-application'}, {'html_handling': 'auto-trailing-slash'},
                         {'redirects': '/public'}):
            bad = dict(result, assets=dict(result['assets'], **mutation))
            with self.assertRaises(delivery.DeliveryError):delivery.validate_deployment_config(bad)
        for field, value in (('routes', [{'pattern': '*', 'fail_open': True}]), ('preview_urls', True), ('workers_dev', False)):
            with self.assertRaises(delivery.DeliveryError):delivery.validate_deployment_config(dict(result, **{field: value}))
        for ownership in ({}, None, {'subdomain': 'foreign'}, {'subdomain': 'owned-fixture/unsafe'}):
            with patch.object(api, 'api', return_value=ownership), self.assertRaises(delivery.DeliveryError):
                delivery.deployment_config(config, api)
        with self.assertRaises(delivery.DeliveryError):delivery.deployment_config(config)
        for host in ('other.owned-fixture.workers.dev', 'alias.monitor.owned-fixture.workers.dev', 'download.example.invalid'):
            with patch.object(api, 'api', return_value={'subdomain': 'owned-fixture'}), self.assertRaises(delivery.DeliveryError):
                delivery.deployment_config(dict(config, origin='https://' + host), api)

    def test_active_version_including_zero_percent_and_provider_source_readback(self):
        config = self.api.config
        api = delivery.Cloudflare.__new__(delivery.Cloudflare);api.config = config
        version = '12345678-1234-1234-1234-123456789abc'
        with patch.object(api, 'api', return_value={'subdomain': 'owned-fixture'}):
            configured = delivery.deployment_config(config, api)
        state = dict(schema='shadow-sync/private-deployment/v1',account_id=config['account_id'],worker_name=config['worker_name'],
                     version_id=version,etag='reviewed-etag',source_sha256=delivery.source_digest(),config=configured,assets={})
        delivery.private_write(config['deployment_state'],state)
        responses = {'/workers/subdomain': {'subdomain': 'owned-fixture'},
                     '/workers/scripts/monitor/deployments': {'deployments': [{'versions': [{'version_id': version, 'percentage': 100}]}]},
                     '/workers/scripts/monitor/versions/' + version: {'resources': {'script': {'etag': 'reviewed-etag'}}},
                     '/workers/scripts/monitor/subdomain': {'enabled': True, 'previews_enabled': False}, '/workers/domains': []}
        with patch.object(api, 'zone_routes', return_value=[]), patch.object(api,'api',side_effect=lambda path: responses[path]):delivery.audit_deployment(api)
        negatives = [('/workers/scripts/monitor/deployments', {'deployments': [{'versions': [{'version_id': version,'percentage':100},{'version_id':'unsafe','percentage':0}]}]}),
                     ('/workers/scripts/monitor/deployments', {'deployments': []}),
                     ('/workers/scripts/monitor/versions/' + version, {'resources': {'script': {'etag': 'changed'}}}),
                     ('/workers/scripts/monitor/subdomain', {'enabled': True,'previews_enabled': True}),
                     ('/workers/domains', [{'service':'monitor','hostname':'unsafe.invalid'}])]
        for path, bad in negatives:
            changed = dict(responses, **{path: bad})
            with patch.object(api, 'zone_routes', return_value=[]), patch.object(api,'api',side_effect=lambda key: changed[key]), self.assertRaises(delivery.DeliveryError):
                delivery.audit_deployment(api)
        for domains, routes in (([{'unknown_shape':'monitor'}],[]),([], [{'unknown_shape':'monitor','fail_open':True}]),
                                 ([None],[]),([{'service':False}],[]),([], [{'script':[]}]),([], [{'script':''}])):
            changed = dict(responses, **{'/workers/domains':domains})
            with patch.object(api, 'zone_routes', return_value=routes), patch.object(api,'api',side_effect=lambda key: changed[key]), self.assertRaises(delivery.DeliveryError):
                delivery.audit_deployment(api)
        changed = dict(responses, **{'/workers/domains':[{'service':'other-worker'}]})
        with patch.object(api, 'zone_routes', return_value=[{'script':None},{'script':'other-worker'}]), patch.object(api,'api',side_effect=lambda key: changed[key]):
            delivery.audit_deployment(api)

    def test_existing_worker_with_lost_receipt_cannot_be_replaced(self):
        api = delivery.Cloudflare.__new__(delivery.Cloudflare);api.config=self.api.config
        def response(path, **kwargs):
            return {'subdomain':'owned-fixture'} if path == '/workers/subdomain' else {'deployments':[]}
        with patch.object(api,'api',side_effect=response), patch.object(api,'query') as query, patch.object(api,'wrangler') as wrangler:
            with self.assertRaises(delivery.DeliveryError):api.deploy()
            query.assert_not_called();wrangler.assert_not_called()

    def test_zone_routes_are_exhaustive_read_only_and_fail_closed(self):
        api = delivery.Cloudflare.__new__(delivery.Cloudflare);api.config=self.api.config
        zone = 'f' * 32
        with patch.object(api,'_zone_read',side_effect=[[{'id':zone}],[{'script':'monitor','fail_open':True}]]) as reads:
            self.assertEqual(api.zone_routes()[0]['script'],'monitor')
            self.assertEqual(reads.call_count,2)
        with patch.object(api,'_zone_read',return_value=None), self.assertRaises(delivery.DeliveryError):api.zone_routes()
        for path in ('/zones/foreign/workers/routes', '/zones?account.id=foreign', '/subscriptions'):
            with self.assertRaises(delivery.DeliveryError):api._zone_read(path)

    def test_private_assets_bounded_immutable_retained_and_no_routing_files(self):
        root = Path(self.api.config['assets_directory'])
        source = self.api.root / 'large.zip'
        data = b'x' * delivery.PART_SIZE + b'y' * 17
        source.write_bytes(data)
        desc = {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
        parts = delivery.stage_artifact(self.api.config, source, 'fixture-1', 'archive', desc)
        self.assertEqual([p['size'] for p in parts], [delivery.PIECE_SIZE]*(delivery.PART_SIZE//delivery.PIECE_SIZE)+[17])
        self.assertEqual(len(delivery.asset_inventory(self.api.config)),delivery.PART_SIZE//delivery.PIECE_SIZE+1)
        api = delivery.Cloudflare.__new__(delivery.Cloudflare);api.config = self.api.config
        rows = [{'parts_json':json.dumps(parts)}]
        with patch.object(api,'query',return_value=rows):
            api.preflight_retention(delivery.asset_inventory(self.api.config))
            (root / parts[0]['path'].lstrip('/')).unlink()
            with self.assertRaises(delivery.DeliveryError):api.preflight_retention(delivery.asset_inventory(self.api.config))
        for name in ('_headers','_redirects','index.html','secret.json'):
            path = root / name;path.write_text('forbidden');path.chmod(0o600)
            with self.assertRaises(delivery.DeliveryError):delivery.asset_inventory(self.api.config)
            path.unlink()
        link = root / 'link';link.symlink_to(source)
        with self.assertRaises(delivery.DeliveryError):delivery.asset_inventory(self.api.config)
        link.unlink()

    def test_readback_failure_never_advances_channel_and_stable_cannot_replace_bytes(self):
        value = release()
        artifact = self.api.root / 'artifact.zip';artifact.write_bytes(b'test')
        with patch.object(self.api,'readback',side_effect=delivery.DeliveryError('Synthetic readback failure')):
            with self.assertRaises(delivery.DeliveryError):delivery.publish(self.api,value,receipt(value),artifact,artifact)
        self.assertEqual(self.api.query('SELECT * FROM channels'), [])
        self.assertEqual(len(self.api.query('SELECT * FROM releases')),1)
        delivery.publish(self.api,value,receipt(value),artifact,artifact)
        stable = dict(value, channel='stable',qualified=True);proof=receipt(stable);proof['checks']['private_upgrade']=True
        with self.assertRaises(delivery.DeliveryError):delivery.publish(self.api,stable,proof,artifact,artifact)

    def test_pinned_wrangler_auth_is_captured_without_argv_secrets(self):
        secret = 'fixture-owner-token'
        seen = []
        def fake(args, **kwargs):
            seen.append((args, kwargs))
            if args[-1] == '--version':
                return subprocess.CompletedProcess(args, 0, b'4.158.0\n', b'')
            return subprocess.CompletedProcess(args, 0, json.dumps({'type': 'oauth', 'token': secret}).encode(), b'')
        with patch.object(delivery, 'pinned_node', return_value='/fixture/node'), patch.object(delivery.subprocess, 'run', side_effect=fake):
            api = delivery.Cloudflare({'wrangler': '/fixture/wrangler.js'})
        self.assertEqual(api._authorization, 'Bearer ' + secret)
        for args, kwargs in seen:
            self.assertEqual(args[:2], ['/fixture/node', '/fixture/wrangler.js'])
            self.assertNotIn(secret, repr(args))
            self.assertEqual(kwargs['env']['WRANGLER_SEND_METRICS'], 'false')
            self.assertEqual(kwargs['env']['WRANGLER_WRITE_LOGS'], 'false')
            self.assertEqual(kwargs['env']['WRANGLER_LOG'], 'log')
            self.assertEqual(kwargs['env']['WRANGLER_LOG_SANITIZE'], 'true')
            self.assertEqual(kwargs['env']['WRANGLER_SEND_ERROR_REPORTS'], 'false')
            self.assertEqual(kwargs['env']['CLOUDFLARE_API_BASE_URL'], 'https://api.cloudflare.com/client/v4')
            self.assertNotIn('WRANGLER_OUTPUT_FILE_PATH', kwargs['env'])
            self.assertNotIn('WRANGLER_OUTPUT_FILE_DIRECTORY', kwargs['env'])
            self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
        with patch.object(delivery.Cloudflare, 'wrangler', return_value='4.0.0'), self.assertRaises(delivery.DeliveryError):
            delivery.Cloudflare({'wrangler': '/fixture/wrangler.js'})

    def test_wrangler_runs_the_verified_node_despite_conflicting_path(self):
        root = Path(self.temp.name).resolve() if hasattr(self,'temp') else self.api.root
        launcher = root/'wrangler.js'
        launcher.write_text("process.stdout.write(process.argv.includes('--version') ? '4.158.0' : JSON.stringify({type:'oauth',token:'synthetic-token'}))")
        fake = root/'node'; fake.write_text('#!/bin/sh\nexit 99\n'); fake.chmod(0o700)
        binary = str(Path(node()).resolve())
        with patch.dict(os.environ, {'PATH':str(root), 'SHADOW_SYNC_DELIVERY_NODE':binary}):
            api = delivery.Cloudflare({'wrangler':str(launcher)})
        self.assertEqual(api.node,binary)
        self.assertEqual(api._authorization,'Bearer synthetic-token')

    def test_default_node_locator_is_bound_to_verified_absolute_executable(self):
        binary = node()
        outputs = [subprocess.CompletedProcess([], 0, b'v26.4.0\n', b''),
                   subprocess.CompletedProcess([], 0, b'4.158.0\n', b''),
                   subprocess.CompletedProcess([], 0, b'{"type":"oauth","token":"synthetic-token"}', b'')]
        with patch.dict(os.environ, {'PATH': '/fixture/conflicting'}, clear=True), \
                patch.object(delivery.shutil, 'which', return_value=binary), \
                patch.object(delivery.subprocess, 'run', side_effect=outputs) as command:
            api = delivery.Cloudflare({'wrangler': '/fixture/wrangler.js'})
        self.assertEqual(api.node, binary)
        self.assertEqual(command.call_count, 3)
        self.assertTrue(all(call.args[0][0] == binary for call in command.call_args_list))

    def test_verification_runtime_rejects_corrupt_download_before_extraction(self):
        cache = self.api.root / 'verification-cache'
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(toolchain.shutil, 'which', return_value=None), \
                patch.object(toolchain.platform, 'system', return_value='Darwin'), \
                patch.object(toolchain.platform, 'machine', return_value='arm64'), \
                patch.object(toolchain, 'download_bytes', return_value=b'corrupt synthetic archive'), \
                patch.object(toolchain.tarfile, 'open') as unpack:
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                toolchain.node(cache=cache)
        unpack.assert_not_called()
        self.assertFalse((cache / ('node-v' + toolchain.NODE_VERSION)).exists())

    def test_verification_runtime_rejects_changed_cached_binary_before_execution(self):
        cache = self.api.root / 'verification-cache'
        target = cache / ('node-v' + toolchain.NODE_VERSION)
        (target / 'bin').mkdir(parents=True)
        (target / 'bin/node').write_bytes(b'changed synthetic executable')
        (target / 'verified.json').write_text(json.dumps({
            'archive_sha256': toolchain.NODE_SHA256, 'binary_sha256': '0' * 64}))
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(toolchain.shutil, 'which', return_value=None), \
                patch.object(toolchain.platform, 'system', return_value='Darwin'), \
                patch.object(toolchain.platform, 'machine', return_value='arm64'), \
                patch.object(toolchain, '_version') as execute:
            with self.assertRaisesRegex(ValueError, 'Cached verification runtime changed'):
                toolchain.node(cache=cache)
        execute.assert_not_called()



class AccessLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory(prefix='shadow-sync-access-fixture-')
        self.addCleanup(self.home.cleanup)
        isolated = patch.dict(os.environ, HOME=self.home.name, GIT_CONFIG_NOSYSTEM='1',
                              GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
        isolated.start()
        self.addCleanup(isolated.stop)
        self.api = MemoryAPI()
        self.addCleanup(self.api.folder.cleanup)
        self.addCleanup(self.api.db.close)
        self.expiry = int(time.time()) + 3600

    def create(self, name='original', owner=False, channel='stable', replaces=None):
        output = self.api.root / (name + '.shadow-sync-access')
        grant = delivery.create_grant(self.api, self.api.config, name, output, self.expiry, owner, channel, replaces)
        return grant, output, Path(str(output) + '.attempt.json')

    def test_lifecycle_status_expiry_revoke_and_redaction(self):
        grant, output, _ = self.create()
        self.assertEqual(delivery.access_rows(self.api, grant)[0]['status'], 'active')
        expired = delivery.change_grant(self.api, grant, expires_at=int(time.time()) - 1)
        self.assertEqual(expired['status'], 'expired')
        with self.assertRaises(delivery.DeliveryError):
            delivery.change_grant(self.api, grant, expires_at=self.expiry)
        revoked = delivery.change_grant(self.api, grant)
        self.assertEqual(revoked['status'], 'revoked')
        rows = json.dumps(delivery.access_rows(self.api))
        token = json.loads(output.read_text())['token']
        for private in (token, hashlib.sha256(token.encode()).hexdigest(), str(self.api.root), 'token_hash', 'label'):
            self.assertNotIn(private, rows)
        self.assertEqual(delivery.change_grant(self.api, grant), revoked)

    def test_wrong_app_channel_owner_and_multiple_entitlements_refuse(self):
        grant, _, _ = self.create(owner=True, channel='qualification')
        for channel, owner in (('stable', True), ('qualification', False), ('stable', False)):
            with self.assertRaises(delivery.DeliveryError):
                delivery.change_grant(self.api, grant, channel, owner)
        self.api.query('UPDATE entitlements SET app_id=? WHERE grant_id=?', ('fixture.other', grant))
        self.assertEqual(delivery.access_rows(self.api, grant), [])
        with self.assertRaises(delivery.DeliveryError):
            delivery.change_grant(self.api, grant, 'qualification', True)
        self.api.query('INSERT INTO entitlements VALUES(?,?,?)', (grant, delivery.APP, 'qualification'))
        self.assertEqual(delivery.access_rows(self.api, grant)[0]['status'], 'scope-conflict')
        with self.assertRaises(delivery.DeliveryError):
            delivery.change_grant(self.api, grant, 'qualification', True)
        self.assertIsNone(self.api.query('SELECT revoked_at FROM grants WHERE grant_id=?', (grant,))[0]['revoked_at'])

    def test_successful_replacement_keeps_files_scope_and_old_bytes_caveat(self):
        old, old_file, _ = self.create(owner=True, channel='qualification')
        old_bytes = old_file.read_bytes()
        new, output, attempt = self.create('replacement', True, 'qualification', old)
        self.assertEqual(old_file.read_bytes(), old_bytes)
        self.assertEqual(delivery.access_rows(self.api, old)[0]['status'], 'revoked')
        self.assertEqual(delivery.access_rows(self.api, new)[0]['channel'], 'qualification')
        self.assertEqual(delivery.recover_grant(self.api, self.api.config, attempt)['status'], 'complete')
        self.assertEqual(len(delivery.access_rows(self.api)), 2)
        self.assertTrue(output.exists())

    def test_replacement_cannot_extend_expiry_or_cross_authority(self):
        old, _, _ = self.create()
        self.expiry += 1
        with self.assertRaises(delivery.DeliveryError): self.create('extended', replaces=old)
        self.expiry -= 1
        with self.assertRaises(delivery.DeliveryError): self.create('owner', owner=True, replaces=old)
        self.assertEqual(len(delivery.access_rows(self.api)), 1)

    def test_each_ambiguous_write_cut_reconciles_without_replay(self):
        for step in ('grant', 'entitlement', 'revoke'):
            for committed in (False, True):
                with self.subTest(step=step, committed=committed):
                    old, _, _ = self.create('old-' + step + str(committed))
                    name = 'new-' + step + str(committed)
                    output = self.api.root / (name + '.shadow-sync-access')
                    attempt = Path(str(output) + '.attempt.json')
                    query = self.api.query
                    prefix = {'grant':'INSERT INTO grants', 'entitlement':'INSERT INTO entitlements', 'revoke':'UPDATE grants'}[step]
                    failures = []
                    def interrupted(sql, params=()):
                        if sql.startswith(prefix) and not failures:
                            failures.append((sql, params))
                            if committed: query(sql, params)
                            raise TimeoutError('synthetic ambiguous effect')
                        return query(sql, params)
                    with patch.object(self.api, 'query', side_effect=interrupted):
                        with self.assertRaises(delivery.DeliveryError): self.create(name, replaces=old)
                    self.assertTrue(output.exists())
                    self.assertTrue(attempt.exists())
                    writes_before = len([sql for sql,_ in self.api.calls if sql.startswith(prefix)])
                    result = delivery.recover_grant(self.api, self.api.config, attempt, complete=True)
                    writes_after = len([sql for sql,_ in self.api.calls if sql.startswith(prefix)])
                    self.assertEqual(writes_after, writes_before)
                    self.assertEqual(result['status'], 'complete' if committed else 'pending')
                    expected = 'revoked' if committed else 'active'
                    self.assertEqual(delivery.access_rows(self.api, old)[0]['status'], expected)

    def test_local_cut_before_any_remote_intent_is_recoverable(self):
        original = delivery.access_file
        for failed_step in ('grant', 'entitlement', 'revoke'):
            with self.subTest(step=failed_step):
                old, _, _ = self.create('prior-' + failed_step)
                def disk_full(path, value=None):
                    if str(path).endswith('.attempt.json.' + failed_step) and value is not None:
                        raise OSError('synthetic disk full before marker creation')
                    return original(path, value)
                with patch.object(delivery, 'access_file', side_effect=disk_full):
                    with self.assertRaises(OSError): self.create('cut-' + failed_step, replaces=old)
                attempt = self.api.root / ('cut-' + failed_step + '.shadow-sync-access.attempt.json')
                self.assertEqual(delivery.recover_grant(self.api, self.api.config, attempt)['status'], 'pending')
                self.assertEqual(delivery.recover_grant(self.api, self.api.config, attempt, complete=True)['status'], 'complete')
                self.assertEqual(delivery.access_rows(self.api, old)[0]['status'], 'revoked')

    def test_recovery_identity_file_modes_and_marker_tampering_refuse(self):
        grant, output, attempt = self.create()
        with self.assertRaises(delivery.DeliveryError):
            delivery.recover_grant(self.api, dict(self.api.config, database_id='c' * 36), attempt, True)
        output.chmod(0o644)
        with self.assertRaises(delivery.DeliveryError): delivery.recover_grant(self.api, self.api.config, attempt, True)
        output.chmod(0o600)
        held = output.with_suffix('.held')
        output.rename(held)
        output.write_bytes(held.read_bytes()); output.chmod(0o600)
        with self.assertRaises(delivery.DeliveryError): delivery.recover_grant(self.api, self.api.config, attempt, True)
        output.unlink(); held.rename(output)
        marker = Path(str(attempt) + '.grant')
        marker.write_text('{}')
        with self.assertRaises(delivery.DeliveryError): delivery.recover_grant(self.api, self.api.config, attempt, True)
        self.assertEqual(delivery.access_rows(self.api, grant)[0]['status'], 'active')

    def test_unsafe_custody_and_initial_file_failures_have_no_remote_effect(self):
        private = self.api.root / 'private'
        private.mkdir(mode=0o700)
        linked = self.api.root / 'linked'
        linked.symlink_to(private)
        for root in (linked, self.api.root / 'open'):
            if not root.exists():
                root.mkdir(mode=0o700)
                root.chmod(0o755)
                self.assertEqual(root.stat().st_mode & 0o777, 0o755)
            with self.assertRaises(delivery.DeliveryError):
                delivery.create_grant(self.api, self.api.config, 'fixture', root / 'access', self.expiry)
        real = delivery.access_file
        def fail_attempt(path, value=None):
            if str(path).endswith('.attempt.json') and value is not None: raise OSError('synthetic full disk')
            return real(path, value)
        with patch.object(delivery, 'access_file', side_effect=fail_attempt):
            with self.assertRaises(OSError): self.create()
        self.assertEqual(self.api.query('SELECT * FROM grants'), [])
        self.assertTrue((self.api.root / 'original.shadow-sync-access').exists())
        with self.assertRaises(delivery.DeliveryError): self.create()

    def test_expiry_and_stale_free_proof_stop_pending_recovery_writes(self):
        old, _, _ = self.create()
        query = self.api.query
        def interrupt(sql, params=()):
            if sql.startswith('INSERT INTO entitlements'):
                query(sql, params)
                raise TimeoutError()
            return query(sql, params)
        with patch.object(self.api, 'query', side_effect=interrupt):
            with self.assertRaises(delivery.DeliveryError): self.create('pending', replaces=old)
        attempt = self.api.root / 'pending.shadow-sync-access.attempt.json'
        with patch.object(delivery.time, 'time', return_value=self.expiry + 1):
            result = delivery.recover_grant(self.api, self.api.config, attempt, True)
            self.assertEqual(result['stage'], 'replacement-expired')
        with patch.object(self.api, 'require_free', side_effect=delivery.DeliveryError('stale proof')):
            with self.assertRaises(delivery.DeliveryError): delivery.recover_grant(self.api, self.api.config, attempt, True)
        self.assertEqual(delivery.access_rows(self.api, old)[0]['status'], 'active')

    def test_single_write_ambiguity_and_scope_race_never_claim_revocation(self):
        for committed in (False, True):
            grant, _, _ = self.create('single-' + str(committed))
            query = self.api.query
            writes = []
            def ambiguous(sql, params=()):
                if sql.startswith('UPDATE grants SET revoked_at'):
                    writes.append(sql)
                    if committed: query(sql, params)
                    raise delivery.DeliveryError('Synthetic unknown write')
                return query(sql, params)
            with patch.object(self.api, 'query', side_effect=ambiguous):
                with self.assertRaises(delivery.DeliveryError): delivery.change_grant(self.api, grant)
            self.assertEqual(len(writes), 1)
            self.assertEqual(delivery.access_rows(self.api, grant)[0]['status'], 'revoked' if committed else 'active')
        grant, _, _ = self.create('raced')
        query = self.api.query
        def changed_scope(sql, params=()):
            if sql.startswith('UPDATE grants SET revoked_at'):
                query('UPDATE entitlements SET app_id=? WHERE grant_id=?', ('fixture.other', grant))
            return query(sql, params)
        with patch.object(self.api, 'query', side_effect=changed_scope):
            with self.assertRaises(delivery.DeliveryError): delivery.change_grant(self.api, grant)
        self.assertIsNone(query('SELECT revoked_at FROM grants WHERE grant_id=?', (grant,))[0]['revoked_at'])
        with patch.object(self.api, 'query', side_effect=delivery.DeliveryError('Synthetic unavailable read')):
            with self.assertRaises(delivery.DeliveryError): delivery.access_rows(self.api, grant)

    def test_replacement_does_not_revoke_original_if_new_scope_changes_at_write(self):
        old, _, _ = self.create('race-old')
        query = self.api.query
        def change_new(sql, params=()):
            if sql.startswith('UPDATE grants SET revoked_at'):
                query('UPDATE entitlements SET app_id=? WHERE grant_id<>?', ('fixture.other', old))
            return query(sql, params)
        with patch.object(self.api, 'query', side_effect=change_new):
            with self.assertRaises(delivery.DeliveryError): self.create('race-new', replaces=old)
        self.assertEqual(delivery.access_rows(self.api, old)[0]['status'], 'active')
        self.assertTrue((self.api.root / 'race-new.shadow-sync-access.attempt.json.revoke').exists())

    def final_return_mutation(self, mutation):
        # Every case reaches the actual final SQL boundary, including reconciliation
        # after a revocation committed but its provider response was lost.
        for recovery in ('completed-read-only', 'completed-explicit', 'lost-revoke-response'):
            with self.subTest(mutation=mutation, recovery=recovery):
                old, _, _ = self.create('old-' + mutation + '-' + recovery)
                query = self.api.query
                name = 'new-' + mutation + '-' + recovery
                output = self.api.root / (name + '.shadow-sync-access')
                attempt = Path(str(output) + '.attempt.json')
                if recovery == 'lost-revoke-response':
                    def lost_response(sql, params=()):
                        result = query(sql, params)
                        if sql.startswith('UPDATE grants SET revoked_at'):
                            raise TimeoutError('synthetic lost committed response')
                        return result
                    with patch.object(self.api, 'query', side_effect=lost_response):
                        with self.assertRaises(delivery.DeliveryError): self.create(name, replaces=old)
                    new = json.loads(attempt.read_text())['grant']['grant_id']
                else:
                    new, output, attempt = self.create(name, replaces=old)
                calls = len(self.api.calls)
                fired = []
                def raced_final_read(sql, params=()):
                    if sql.startswith('SELECT g.*,e.app_id,e.channel'):
                        self.assertFalse(fired)
                        fired.append(True)
                        if mutation in ('owner', 'channel', 'expiry', 'token', 'original-unrevoked',
                                        'original-scope', 'missing-new', 'new-revoked', 'extra-scope',
                                        'original-token', 'original-owner', 'original-expiry', 'original-revoked-at'):
                            statement, values = {
                                'owner': ('UPDATE grants SET is_owner=1 WHERE grant_id=?', (new,)),
                                'channel': ('UPDATE entitlements SET channel=? WHERE grant_id=?', ('qualification', new)),
                                'expiry': ('UPDATE grants SET expires_at=expires_at+3600 WHERE grant_id=?', (new,)),
                                'token': ('UPDATE grants SET token_hash=? WHERE grant_id=?', (hashlib.sha256(('changed-' + new).encode()).hexdigest(), new)),
                                'original-unrevoked': ('UPDATE grants SET revoked_at=NULL WHERE grant_id=?', (old,)),
                                'original-scope': ('UPDATE entitlements SET app_id=? WHERE grant_id=?', ('fixture.other', old)),
                                'missing-new': ('DELETE FROM grants WHERE grant_id=?', (new,)),
                                'new-revoked': ('UPDATE grants SET revoked_at=? WHERE grant_id=?', (int(time.time()), new)),
                                'extra-scope': ('INSERT INTO entitlements VALUES(?,?,?)', (new, 'fixture.other', 'stable')),
                                'original-token': ('UPDATE grants SET token_hash=? WHERE grant_id=?', (hashlib.sha256(('changed-' + old).encode()).hexdigest(), old)),
                                'original-owner': ('UPDATE grants SET is_owner=1 WHERE grant_id=?', (old,)),
                                'original-expiry': ('UPDATE grants SET expires_at=expires_at+3600 WHERE grant_id=?', (old,)),
                                'original-revoked-at': ('UPDATE grants SET revoked_at=revoked_at+1 WHERE grant_id=?', (old,)),
                            }[mutation]
                            if mutation == 'missing-new':
                                self.api.db.execute('DELETE FROM entitlements WHERE grant_id=?', (new,))
                            self.api.db.execute(statement, values)
                        elif mutation in ('access-inode', 'attempt-inode'):
                            target = output if mutation == 'access-inode' else attempt
                            held = target.with_suffix('.held')
                            target.rename(held)
                            target.write_bytes(held.read_bytes()); target.chmod(0o600)
                            self.assertNotEqual(target.stat().st_ino, held.stat().st_ino)
                        elif mutation == 'access-bytes':
                            value = json.loads(output.read_text()); value['token'] = 'synthetic-different-token'
                            output.write_text(json.dumps(value))
                        elif mutation == 'access-mode':
                            output.chmod(0o644)
                            self.assertEqual(output.stat().st_mode & 0o777, 0o644)
                        elif mutation == 'access-whitespace':
                            output.write_bytes(output.read_bytes() + b' ')
                        elif mutation == 'attempt-whitespace':
                            attempt.write_bytes(attempt.read_bytes() + b' ')
                        elif mutation == 'attempt-mode':
                            attempt.chmod(0o644)
                        elif mutation == 'unknown':
                            raise delivery.DeliveryError('Synthetic unavailable final observation')
                        else:
                            self.fail('Unknown fixture mutation')
                    return query(sql, params)
                with patch.object(self.api, 'query', side_effect=raced_final_read):
                    with self.assertRaises(delivery.DeliveryError):
                        delivery.recover_grant(self.api, self.api.config, attempt,
                                               complete=recovery != 'completed-read-only')
                self.assertEqual(fired, [True])
                self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.api.calls[calls:]))
                self.assertTrue(output.exists())
                self.assertTrue(attempt.exists())

    def test_final_recovery_refuses_changed_token_identity(self):
        self.final_return_mutation('token')

    def test_final_recovery_refuses_widened_owner(self):
        self.final_return_mutation('owner')

    def test_final_recovery_refuses_changed_channel(self):
        self.final_return_mutation('channel')

    def test_final_recovery_refuses_extended_expiry(self):
        self.final_return_mutation('expiry')

    def test_final_recovery_refuses_replaced_access_inode(self):
        self.final_return_mutation('access-inode')

    def test_final_recovery_refuses_changed_access_bytes(self):
        self.final_return_mutation('access-bytes')

    def test_final_recovery_refuses_open_access_permissions(self):
        self.final_return_mutation('access-mode')

    def test_final_recovery_refuses_replaced_attempt_inode(self):
        self.final_return_mutation('attempt-inode')

    def test_final_recovery_refuses_original_unrevoked(self):
        self.final_return_mutation('original-unrevoked')

    def test_final_recovery_refuses_original_foreign_scope(self):
        self.final_return_mutation('original-scope')

    def test_final_recovery_refuses_changed_original_identity(self):
        for mutation in ('original-token', 'original-owner', 'original-expiry', 'original-revoked-at'):
            self.final_return_mutation(mutation)

    def test_final_recovery_refuses_missing_revoked_or_multiple_scope(self):
        for mutation in ('missing-new', 'new-revoked', 'extra-scope'):
            self.final_return_mutation(mutation)

    def test_final_recovery_refuses_raw_byte_or_attempt_permission_drift(self):
        for mutation in ('access-whitespace', 'attempt-whitespace', 'attempt-mode'):
            self.final_return_mutation(mutation)

    def test_final_recovery_unknown_observation_never_reports_completion(self):
        self.final_return_mutation('unknown')

    def test_final_recovery_preserves_positive_expired_and_redacted_outcomes(self):
        old, _, _ = self.create('status-old')
        new, output, attempt = self.create('status-new', replaces=old)
        for expired in (False, True):
            with self.subTest(expired=expired):
                now = self.expiry + 1 if expired else int(time.time())
                calls = len(self.api.calls)
                with patch.object(delivery.time, 'time', return_value=now):
                    result = delivery.recover_grant(self.api, self.api.config, attempt)
                self.assertEqual(result, dict(grant_id=new, status='complete',
                                              access_status='expired' if expired else 'active'))
                reads = self.api.calls[calls:]
                self.assertTrue(all(sql.startswith('SELECT') for sql, _ in reads))
                self.assertEqual(sum(sql.startswith('SELECT g.*,e.app_id,e.channel') for sql, _ in reads), 1)
                self.assertTrue(reads[-1][0].startswith('SELECT g.*,e.app_id,e.channel'))
                for private in (json.loads(output.read_text())['token'], 'token_hash', str(self.api.root)):
                    self.assertNotIn(private, json.dumps(result))

    def test_custody_brackets_last_file_read_and_held_attempt_lock(self):
        _, output, attempt = self.create()
        real = delivery.access_custody
        triggered = []
        final = []
        query = self.api.query
        def mark_final(sql, params=()):
            if sql.startswith('SELECT g.*,e.app_id,e.channel'): final.append(True)
            return query(sql, params)
        def change_earlier_file(path):
            result = real(path)
            if final and Path(path) == output and not triggered:
                triggered.append(True)
                attempt.write_bytes(attempt.read_bytes() + b' ')
            return result
        with patch.object(self.api, 'query', side_effect=mark_final), \
             patch.object(delivery, 'access_custody', side_effect=change_earlier_file):
            with self.assertRaises(delivery.DeliveryError):
                delivery.recover_grant(self.api, self.api.config, attempt)
        self.assertEqual(triggered, [True])

    def test_custody_refuses_noncanonical_original_bytes_before_recovery(self):
        _, output, attempt = self.create()
        before = len(self.api.calls)
        output.write_bytes(output.read_bytes() + b' ')
        with self.assertRaises(delivery.DeliveryError):
            delivery.recover_grant(self.api, self.api.config, attempt, complete=True)
        self.assertEqual(len(self.api.calls), before)

    def test_observed_attempt_marker_disappearance_never_replays(self):
        for step, prefix in (('grant', 'INSERT INTO grants'), ('entitlement', 'INSERT INTO entitlements'),
                             ('revoke', 'UPDATE grants SET revoked_at')):
            with self.subTest(step=step):
                old = self.create('prior-' + step)[0] if step == 'revoke' else None
                query = self.api.query
                writes = []
                def lost_response(sql, params=()):
                    if sql.startswith(prefix):
                        writes.append(sql)
                        raise TimeoutError('Synthetic ambiguous response before effect')
                    return query(sql, params)
                with patch.object(self.api, 'query', side_effect=lost_response):
                    with self.assertRaises(delivery.DeliveryError):
                        self.create('pending-' + step, replaces=old)
                attempt = self.api.root / ('pending-' + step + '.shadow-sync-access.attempt.json')
                marker = Path(str(attempt) + '.' + step)
                self.assertTrue(marker.exists())
                observed, removed = [], []
                read = delivery.access_custody
                def observed_custody(path):
                    result = read(path)
                    if Path(path) == marker: observed.append(True)
                    return result
                def remove_after_observation(sql, params=()):
                    if sql.startswith('SELECT * FROM grants') and not removed:
                        self.assertTrue(observed)
                        removed.append(True)
                        marker.unlink()
                    if sql.startswith(prefix): writes.append(sql)
                    return query(sql, params)
                with patch.object(delivery, 'access_custody', side_effect=observed_custody), \
                     patch.object(self.api, 'query', side_effect=remove_after_observation):
                    with self.assertRaises(delivery.DeliveryError):
                        delivery.recover_grant(self.api, self.api.config, attempt, complete=True)
                self.assertEqual(removed, [True])
                self.assertEqual(len(writes), 1, 'An ambiguous original write must never be replayed')

    def test_final_step_marker_bytes_mode_inode_and_presence_are_retained(self):
        for step in ('grant', 'entitlement', 'revoke'):
            for mutation in ('bytes', 'mode', 'inode', 'missing'):
                with self.subTest(step=step, mutation=mutation):
                    name = step + '-' + mutation
                    old = self.create('old-' + name)[0]
                    _, _, attempt = self.create('new-' + name, replaces=old)
                    marker = Path(str(attempt) + '.' + step)
                    query, fired = self.api.query, []
                    def changed_marker(sql, params=()):
                        if sql.startswith('SELECT g.*,e.app_id,e.channel') and not fired:
                            fired.append(True)
                            if mutation == 'bytes': marker.write_bytes(b'{}\n')
                            elif mutation == 'mode': marker.chmod(0o644)
                            elif mutation == 'missing': marker.unlink()
                            else:
                                held = Path(str(marker) + '.retained')
                                marker.rename(held)
                                marker.write_bytes(held.read_bytes()); marker.chmod(0o600)
                        return query(sql, params)
                    before = len(self.api.calls)
                    with patch.object(self.api, 'query', side_effect=changed_marker):
                        with self.assertRaises(delivery.DeliveryError):
                            delivery.recover_grant(self.api, self.api.config, attempt, complete=True)
                    self.assertEqual(fired, [True])
                    self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.api.calls[before:]))

    def test_final_recovery_refuses_a_new_previously_absent_marker(self):
        _, _, attempt = self.create()
        intent = json.loads(attempt.read_text())
        marker = Path(str(attempt) + '.revoke')
        value = dict(attempt_id=intent['attempt_id'], intent_sha256=hashlib.sha256(
            json.dumps(intent, sort_keys=True).encode()).hexdigest(), step='revoke')
        query, fired = self.api.query, []
        def create_during_final_read(sql, params=()):
            if sql.startswith('SELECT g.*,e.app_id,e.channel') and not fired:
                fired.append(True); delivery.access_file(marker, value)
            return query(sql, params)
        with patch.object(self.api, 'query', side_effect=create_during_final_read):
            with self.assertRaises(delivery.DeliveryError):
                delivery.recover_grant(self.api, self.api.config, attempt)
        self.assertEqual(fired, [True])

    def test_marker_custody_is_bracketed_after_later_marker_reads(self):
        _, _, attempt = self.create()
        grant, entitlement = Path(str(attempt) + '.grant'), Path(str(attempt) + '.entitlement')
        query, read, final, changed = self.api.query, delivery.access_custody, [], []
        def final_read(sql, params=()):
            if sql.startswith('SELECT g.*,e.app_id,e.channel'): final.append(True)
            return query(sql, params)
        def change_earlier_marker(path):
            result = read(path)
            if final and Path(path) == entitlement and not changed:
                changed.append(True); grant.write_bytes(grant.read_bytes() + b' ')
            return result
        with patch.object(self.api, 'query', side_effect=final_read), \
             patch.object(delivery, 'access_custody', side_effect=change_earlier_marker):
            with self.assertRaises(delivery.DeliveryError):
                delivery.recover_grant(self.api, self.api.config, attempt)
        self.assertEqual(changed, [True])

    def test_new_marker_keeps_its_created_inode_before_provider_effect(self):
        write, changed = delivery.access_file, []
        def replace_after_creation(path, value=None):
            result = write(path, value)
            if value is not None and str(path).endswith('.grant') and not changed:
                changed.append(True)
                path = Path(path); held = Path(str(path) + '.retained')
                path.rename(held); path.write_bytes(held.read_bytes()); path.chmod(0o600)
            return result
        with patch.object(delivery, 'access_file', side_effect=replace_after_creation):
            with self.assertRaises(delivery.DeliveryError): self.create()
        self.assertEqual(changed, [True])
        self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.api.calls))

    def test_cli_outputs_redacted_scoped_status(self):
        grant, output, _ = self.create()
        capture = io.StringIO()
        with patch.object(delivery, 'load_config', return_value=self.api.config), patch.object(delivery, 'Cloudflare', return_value=self.api), \
             patch.object(delivery.sys, 'argv', ['delivery.py', '--config', '/fixture/private.json', 'grant-status', '--grant-id', grant]), \
             contextlib.redirect_stdout(capture):
            self.assertEqual(delivery.main(), 0)
        self.assertEqual(json.loads(capture.getvalue())[0]['status'], 'active')
        self.assertNotIn(json.loads(output.read_text())['token'], capture.getvalue())


    def test_initial_opened_marker_disappearance_is_not_absence(self):
        import inspect
        for step, prefix in (('grant', 'INSERT INTO grants'), ('entitlement', 'INSERT INTO entitlements'), ('revoke', 'UPDATE grants SET revoked_at')):
            with self.subTest(step=step):
                old = self.create('prior-' + step)[0] if step == 'revoke' else None
                query = self.api.query
                writes = []
                def lost_response(sql, params=()):
                    if sql.startswith(prefix):
                        writes.append(sql)
                        raise TimeoutError('Synthetic ambiguous response before effect')
                    return query(sql, params)
                with patch.object(self.api, 'query', side_effect=lost_response):
                    with self.assertRaises(delivery.DeliveryError):
                        self.create('pending-' + step, replaces=old)
                attempt = self.api.root / ('pending-' + step + '.shadow-sync-access.attempt.json')
                marker = Path(str(attempt) + '.' + step)
                self.assertTrue(marker.exists())
                realstat, removed = Path.stat, []
                def remove_before_named_check(path, *args, **kwargs):
                    if path == marker and kwargs.get('follow_symlinks') is False and not removed:
                        self.assertEqual(inspect.currentframe().f_back.f_code.co_name, 'access_custody')
                        removed.append(True)
                        path.unlink()
                    return realstat(path, *args, **kwargs)
                def track_write(sql, params=()):
                    if sql.startswith(prefix): writes.append(sql)
                    return query(sql, params)
                with patch.object(Path, 'stat', new=remove_before_named_check), patch.object(self.api, 'query', side_effect=track_write):
                    with self.assertRaises(delivery.DeliveryError):
                        delivery.recover_grant(self.api, self.api.config, attempt, complete=True)
                self.assertEqual(removed, [True])
                self.assertEqual(len(writes), 1, 'An opened marker disappearing must never authorize replay')


if __name__ == '__main__':
    unittest.main()
