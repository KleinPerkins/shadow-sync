"""Provenance validation uses current bytes and disposable corruption fixtures."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('source_export', ROOT / 'scripts/verify-source-contract.py')
source = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source)


class SourceExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-export-check-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'Resources').mkdir()
        self.file = self.root / 'fixture'
        self.file.write_bytes(b'payload')
        self.file.chmod(0o600)
        self.manifest = {'schema': 'shadow-sync-source-export/v1',
                         'repository': 'KleinPerkins/shadow-sync', 'files': [
            {'path': 'fixture', 'mode': '100644',
             'sha256': hashlib.sha256(b'payload').hexdigest()}]}
        self.write(self.manifest)

    def write(self, value):
        (self.root / 'Resources/source-export.json').write_text(json.dumps(value))

    def test_current_repository_export_matches(self):
        self.assertGreater(source.verify_export(ROOT), 0)

    def test_matching_payload_and_executable_modes(self):
        self.assertEqual(source.verify_export(self.root), 1)
        self.file.chmod(0o700)
        self.manifest['files'][0]['mode'] = '100755'
        self.write(self.manifest)
        self.assertEqual(source.verify_export(self.root), 1)

    def test_stale_payload_digest_refuses(self):
        self.file.write_bytes(b'changed')
        with self.assertRaises(ValueError): source.verify_export(self.root)

    def test_stale_executable_mode_refuses(self):
        self.file.chmod(0o700)
        with self.assertRaises(ValueError): source.verify_export(self.root)

    def test_duplicate_or_empty_inventory_refuses(self):
        for rows in [[], self.manifest['files'] * 2]:
            with self.subTest(rows=rows):
                self.write({**self.manifest, 'files': rows})
                with self.assertRaises(ValueError): source.verify_export(self.root)

    def test_unsafe_or_self_referential_paths_refuse(self):
        for name in ['../outside', '/fixture', './fixture', 'a//fixture',
                     'a/../fixture', 'a\\fixture', 'fixture\n', 'Resources/source-export.json']:
            with self.subTest(name=name):
                entry = {**self.manifest['files'][0], 'path': name}
                self.write({**self.manifest, 'files': [entry]})
                with self.assertRaises(ValueError): source.verify_export(self.root)

    def test_linked_or_missing_payload_refuses(self):
        other = self.root / 'original'
        self.file.rename(other)
        with self.assertRaises(OSError): source.verify_export(self.root)
        self.file.symlink_to(other)
        with self.assertRaises((ValueError, OSError)): source.verify_export(self.root)

    def test_malformed_entries_and_unknown_mode_refuse(self):
        for change in [{'mode': '120000'}, {'sha256': 'not-a-digest'}, {'extra': 1}]:
            with self.subTest(change=change):
                value = copy.deepcopy(self.manifest)
                value['files'][0].update(change)
                self.write(value)
                with self.assertRaises(ValueError): source.verify_export(self.root)
