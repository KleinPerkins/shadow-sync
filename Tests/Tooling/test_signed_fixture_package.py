"""Offline package binding tests. No compiler, signing, or native case runs."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('signed_fixture_package', ROOT / 'scripts/signed-fixture-package.py')
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class SignedFixturePackageTests(unittest.TestCase):
    def test_discovery_is_closed_and_does_not_run_native_tools(self):
        with mock.patch.object(package, 'load', side_effect=AssertionError('native dependency')):
            value = package.registration()
        self.assertEqual([row['kind'] for row in value['cases'][:2]], ['source-preflight', 'installation-positive'])
        self.assertEqual(len(value['cases']), 170)
        self.assertGreater(len(value['unavailable_requirements']), 40)
        self.assertEqual(value['qualification'], 'signed-adapter-only')
        self.assertEqual(value['build_profile'], 'signed-installation/v1')

    def test_join_roster_preserves_lifecycle_positives_and_unavailable_pending_cut(self):
        value = package.registration()
        by_id = {row['id']: row for row in value['cases']}
        for case in ('startup-stop', 'cleanup-positive', 'terminal-positive', 'start-adapter-join/in-budget'):
            self.assertEqual(by_id['signed-installation/' + case]['kind'], 'installation-positive')
        for case in ('expired-complete', 'expired-pending'):
            self.assertEqual(by_id['signed-installation/start-adapter-join/' + case]['kind'], 'installation-cut')
        self.assertIn('signed-installation/negative/pending-command-retirement',
            {row['id'] for row in value['unavailable_requirements']})

    def test_join_missing_row_and_wrong_positive_classification_refuse(self):
        original = package.regular_bytes
        for mutation in ('missing', 'kind', 'marker'):
            roster = package.registration()
            index = next(i for i, row in enumerate(roster['cases']) if row['id'].endswith('start-adapter-join/expired-pending'))
            if mutation == 'missing': roster['cases'].pop(index)
            elif mutation == 'kind': roster['cases'][index]['kind'] = 'installation-positive'
            else: roster['required_binary_markers']['Contents/Helpers/ShadowSyncLifecycleCoordinator'].remove('SignedInstallationFixtureJoinController')
            def changed(path, maximum=128 * 1024 * 1024):
                return package.encode(roster) if path.name == 'signed-installation-fixtures.json' else original(path, maximum)
            with self.subTest(mutation=mutation), mock.patch.object(package, 'regular_bytes', side_effect=changed):
                with self.assertRaisesRegex(package.Refusal, 'join-required-binary-markers' if mutation == 'marker' else 'closed-case-roster'):
                    package.registration()

    def test_undiscovered_required_case_is_not_a_passing_skip(self):
        original = package.regular_bytes
        roster = package.registration()
        roster['unavailable_requirements'].pop()
        def changed(path, maximum=128 * 1024 * 1024):
            if path.name == 'signed-installation-fixtures.json':
                return package.encode(roster)
            return original(path, maximum)
        with mock.patch.object(package, 'regular_bytes', side_effect=changed):
            with self.assertRaisesRegex(package.Refusal, 'missing-required-coverage'):
                package.registration()

    def test_source_binding_rejects_changed_mode_content_and_alias(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-package-source-') as temporary:
            root = Path(temporary).resolve(); source = root / 'source'; source.mkdir()
            leaf = source / 'leaf'; leaf.write_bytes(b'source input'); leaf.chmod(0o644)
            record = root / 'map.json'; raw = package.encode(package.source_inventory(source)); record.write_bytes(raw)
            digest = hashlib.sha256(raw).hexdigest(); revision = '1' * 40
            package.source_binding(record, digest, revision, root=source)
            leaf.chmod(0o755)
            with self.assertRaisesRegex(package.Refusal, 'source-map-inventory'):
                package.source_binding(record, digest, revision, root=source)
            leaf.chmod(0o644); leaf.write_bytes(b'changed source')
            with self.assertRaisesRegex(package.Refusal, 'source-map-inventory'):
                package.source_binding(record, digest, revision, root=source)
            alias = source / 'alias'; alias.symlink_to(leaf)
            with self.assertRaisesRegex(package.Refusal, 'source-node'):
                package.source_inventory(source)
            alias.unlink(); os.link(leaf, alias)
            with self.assertRaisesRegex(package.Refusal, 'unsafe-input-file'):
                package.source_inventory(source)

    def test_canonical_inventory_matches_public_swift_record_encoding(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-package-canonical-') as temporary:
            app = Path(temporary); app.chmod(0o755)
            target = 'Versions/Current/Python'; digest = hashlib.sha256(b'actual bytes').hexdigest()
            rows = {'Contents': {'kind': 'directory', 'mode': 0o755},
                    'Contents/MacOS/ShadowSync': {'kind': 'file', 'mode': 0o755, 'bytes': 12, 'sha256': digest},
                    'Contents/Frameworks/Python.framework/Python': {'kind': 'symlink', 'mode': 0o755, 'target': target}}
            records = [['d', '.', '493', '0', '-'], ['d', 'Contents', '493', '0', '-'],
                       ['f', 'Contents/MacOS/ShadowSync', '493', '12', digest],
                       ['l', 'Contents/Frameworks/Python.framework/Python', '493', str(len(target)), hashlib.sha256(target.encode()).hexdigest()]]
            expected = hashlib.sha256(('\0'.join(sorted('\0'.join(row) for row in records)) + '\0').encode()).hexdigest()
            self.assertEqual(package.canonical_bundle(app, rows), expected)
            rows['Contents/evil-link'] = {'kind': 'symlink', 'mode': 0o755, 'target': '/foreign'}
            with self.assertRaisesRegex(package.Refusal, 'bundle-link'):
                package.canonical_bundle(app, rows)

    def test_isolated_policy_documents_are_coherent_and_fake_module_refuses(self):
        contract = package.decode((ROOT / 'Resources/awa-contract.json').read_bytes())
        documents = package.policy_documents(contract)
        binding = package.decode(documents['Library/Application Support/ShadowSync/host-policy-binding.json'])
        for role in ('policy', 'projection'):
            item = binding[role]
            self.assertEqual(hashlib.sha256(documents[item['path']]).hexdigest(), item['sha256'])
        projection = package.decode(documents[binding['projection']['path']])
        for item in projection['source_inputs'].values():
            self.assertEqual(hashlib.sha256(documents[item['path']]).hexdigest(), item['sha256'])
        adapter_spec = importlib.util.spec_from_file_location('fixture_policy_adapter', ROOT / 'Resources/PolicyAdapter.py')
        adapter = importlib.util.module_from_spec(adapter_spec); adapter_spec.loader.exec_module(adapter)
        adapter.validate_host_projection(documents[binding['projection']['path']], binding['policy'])
        adapter.require_deployed_no_touch_section(documents[binding['policy']['path']])
        self.assertEqual(binding['awa']['module_sha256'], contract['module_sha256'])
        self.assertNotIn('runtime/policy.py', documents)
        with self.assertRaisesRegex(package.Refusal, 'qualified-policy-module-unavailable'):
            package.policy_payload(b'fake fixture module', contract)

    def test_duplicate_fields_and_missing_binary_routes_refuse(self):
        with self.assertRaisesRegex(package.Refusal, 'duplicate-json-key'):
            package.decode(b'{"profile":1,"profile":2}')
        with tempfile.TemporaryDirectory(prefix='shadow-sync-package-markers-') as temporary:
            root = Path(temporary); binary = root / 'Contents/MacOS/ShadowSync'; binary.parent.mkdir(parents=True)
            binary.write_bytes(b'no route')
            with self.assertRaisesRegex(package.Refusal, 'missing-reachable-binary-route'):
                package.build_markers(root, {'required_binary_markers': {'Contents/MacOS/ShadowSync': ['actual signed entry']}})

    def test_fixture_mode_is_explicit_testing_and_ordinary_exclusion_agrees(self):
        script = (ROOT / 'scripts/build-app.sh').read_text()
        self.assertIn('--signed-installation-fixture)', script)
        self.assertIn('SHADOW_SYNC_SIGNED_FIXTURE', script)
        self.assertIn('ShadowSyncSignedFixtureProfile', script)
        markers = json.loads((ROOT / 'Tests/Fixtures/signed-installation-source-markers.json').read_bytes())
        verifier = (ROOT / 'scripts/ci-suite.py').read_text()
        self.assertIn("signed['qualification'] == '" + markers['qualification'] + "'", verifier)
        self.assertNotIn('build_handoff(', (ROOT / 'scripts/signed-fixture-package.py').read_text())


class SignedFixtureControlPackageTests(unittest.TestCase):
    def test_five_negative_rows_and_markers_are_required_without_changing_positives(self):
        value=package.registration()
        for suffix in ('fault-before-bind','fault-after-ack','fault-before-join','fault-after-refusal','h-expiry'):
            case='signed-installation/start-adapter-join/'+suffix
            rows=[r for r in value['cases'] if r['id']==case]
            self.assertEqual(len(rows),1);self.assertEqual(rows[0]['kind'],'installation-cut')
            self.assertIn(case,value['required_binary_markers']['Contents/Helpers/ShadowSyncLifecycleCoordinator'])
        self.assertEqual(sum(r['kind']=='installation-positive' for r in value['cases']),4 + 1)  # Existing positives plus fresh-driver positive.
        self.assertIn('signed-installation/negative/pending-command-retirement', {r['id'] for r in value['unavailable_requirements']})

    def test_missing_duplicate_misclassified_control_and_marker_refuse(self):
        original=package.regular_bytes
        for action in ('missing','duplicate','kind','marker'):
            roster=package.registration();i=next(i for i,r in enumerate(roster['cases']) if r['id'].endswith('/h-expiry'))
            if action=='missing':roster['cases'].pop(i)
            elif action=='duplicate':roster['cases'].insert(i,dict(roster['cases'][i]))
            elif action=='kind':roster['cases'][i]['kind']='installation-positive'
            else:roster['required_binary_markers']['Contents/Helpers/ShadowSyncLifecycleCoordinator'].remove('SIGNED_JOIN_CONTROL_V1')
            def changed(path,maximum=128*1024*1024):
                return package.encode(roster) if path.name=='signed-installation-fixtures.json' else original(path,maximum)
            with self.subTest(action=action),mock.patch.object(package,'regular_bytes',side_effect=changed),self.assertRaises(package.Refusal):
                package.registration()


class FreshDriverBuildMarkerTests(unittest.TestCase):
    @staticmethod
    def fresh_markers():
        return {'SignedFreshInstallationDriverFixture'} | {
            'signed-installation/fresh-driver/' + suffix for suffix in (
                'positive', 'cancel-normal', 'cancel-ready', 'cleanup-after-unlink',
                'close/temporaryStore', 'close/stagedSlots', 'close/stagedParents',
                'close/bootstrapParents', 'close/metadata', 'close/admission', 'close/state', 'close/operation')}

    def test_dual_flag_source_and_three_build_classification(self):
        spec = importlib.util.spec_from_file_location('fresh_marker_source', ROOT / 'scripts/verify-signed-fixture-source.py')
        source = importlib.util.module_from_spec(spec); spec.loader.exec_module(source)
        files = [(ROOT / 'Sources/ShadowSyncCore' / name).read_text() for name in (
            'FreshInstallationFixture.swift', 'SignedInstallationFixtureCase.swift')]
        ordinary = json.loads((ROOT / 'Tests/Fixtures/production-test-markers.json').read_bytes())['markers']
        excluded = json.loads((ROOT / 'Tests/Fixtures/signed-installation-source-markers.json').read_bytes())['markers']
        positive = package.registration()['required_binary_markers']['Contents/Helpers/ShadowSyncLifecycleCoordinator']
        for marker in self.fresh_markers():
            with self.subTest(marker=marker):
                self.assertNotIn(marker, ordinary)
                self.assertIn(marker, excluded)
                self.assertIn(marker, positive)
                self.assertTrue(any(marker in source.selected(text, True, True) for text in files))
                for testing, signed in ((False, False), (False, True), (True, False)):
                    self.assertTrue(all(marker not in source.selected(text, testing, signed) for text in files))

    def test_each_wrong_roster_or_omitted_signed_positive_refuses(self):
        original = package.regular_bytes
        for marker in self.fresh_markers():
            for mutation in ('ordinary-positive', 'missing-exclusion', 'missing-signed-positive'):
                documents = {name: json.loads((ROOT / name).read_bytes()) for name in (
                    'Tests/Fixtures/production-test-markers.json',
                    'Tests/Fixtures/signed-installation-source-markers.json',
                    'config/signed-installation-fixtures.json')}
                if mutation == 'ordinary-positive':
                    documents['Tests/Fixtures/production-test-markers.json']['markers'].append(marker)
                elif mutation == 'missing-exclusion':
                    documents['Tests/Fixtures/signed-installation-source-markers.json']['markers'].remove(marker)
                else:
                    documents['config/signed-installation-fixtures.json']['required_binary_markers'][
                        'Contents/Helpers/ShadowSyncLifecycleCoordinator'].remove(marker)
                def changed(path, maximum=128 * 1024 * 1024):
                    name = path.relative_to(ROOT).as_posix()
                    return package.encode(documents[name]) if name in documents else original(path, maximum)
                reason = 'fresh-driver-required-binary-markers' if mutation == 'missing-signed-positive' else 'fresh-driver-build-classification'
                with self.subTest(marker=marker, mutation=mutation), mock.patch.object(package, 'regular_bytes', side_effect=changed):
                    with self.assertRaisesRegex(package.Refusal, reason):
                        package.registration()

    def test_actual_signed_helper_bytes_require_each_moved_marker(self):
        contract = package.registration()
        relative = 'Contents/Helpers/ShadowSyncLifecycleCoordinator'
        with tempfile.TemporaryDirectory(prefix='shadow-sync-fresh-markers-') as temporary:
            root = Path(temporary)
            for name, markers in contract['required_binary_markers'].items():
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'\0'.join(value.encode() for value in markers))
            package.build_markers(root, contract)
            for marker in self.fresh_markers():
                (root / relative).write_bytes(b'\0'.join(value.encode() for value in contract['required_binary_markers'][relative] if value != marker))
                with self.subTest(marker=marker), self.assertRaisesRegex(package.Refusal, 'missing-reachable-binary-route'):
                    package.build_markers(root, contract)

if __name__ == '__main__':
    unittest.main()
