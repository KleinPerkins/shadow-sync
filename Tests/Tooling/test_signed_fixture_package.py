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
        self.assertEqual(len(value['cases']), 98)
        self.assertGreater(len(value['unavailable_requirements']), 40)
        self.assertEqual(value['qualification'], 'signed-adapter-only')
        self.assertEqual(value['build_profile'], 'signed-installation/v1')

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


if __name__ == '__main__':
    unittest.main()
