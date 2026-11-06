"""Source/discovery consistency; these checks do not claim runtime execution."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('inventory', ROOT/'scripts/runtime-suite-inventory.py')
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)


class RuntimeInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-suite-inventory-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        files = ['Tests/ShadowSyncSelfTests/CISuites.swift', 'Sources/ShadowSyncApp/M5Harness.swift',
                 'scripts/verify-m5.sh']
        files += [str(p.relative_to(ROOT)) for p in (ROOT/'Sources/ShadowSyncCore').glob('*SelfTests.swift')]
        for name in files:
            path = self.root/name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT/name).read_bytes())

    def test_current_source_has_complete_entrypoint_and_case_registration(self):
        result = inventory.inspect(self.root)
        self.assertEqual((len(result['suites']), result['case_count'], len(result['other_entrypoints'])), (41, 853, 12))
        self.assertFalse(result['runtime_executed'])

    def test_m6_unregistered_missing_duplicate_or_dynamic_body_refuses(self):
        path = self.root/'Sources/ShadowSyncCore/M6SelfTests.swift'
        original = path.read_text()
        line = next(line for line in original.splitlines(True) if 'try run("m6-command-graph-valid")' in line)
        variants = (original.replace(line, line + line.replace('m6-command-graph-valid', 'm6-unregistered')),
                    original.replace(line, ''), original.replace(line, line + line),
                    original.replace('try run("m6-command-graph-valid")', 'try run(dynamicName)'))
        for text in variants:
            path.write_text(text)
            with self.assertRaises(ValueError): inventory.inspect(self.root)

    def test_m6_catalog_cannot_claim_an_unimplemented_case(self):
        path = self.root/'Tests/ShadowSyncSelfTests/CISuites.swift'
        path.write_text(path.read_text().replace('"m6": [', '"m6": ["m6-unimplemented", ', 1))
        with self.assertRaises(ValueError): inventory.inspect(self.root)

    def test_new_unregistered_suite_or_public_entrypoint_refuses(self):
        path = self.root/'Sources/ShadowSyncCore/Unregistered.swift'
        path.write_text('#if SHADOW_SYNC_TESTING\npublic enum NewSelfTestRunner {\n'
                        'public static func runAll() {}\n}\n#endif\n')
        with self.assertRaises(ValueError): inventory.inspect(self.root)
        path.unlink()
        path = self.root/'Sources/ShadowSyncCore/M1SelfTests.swift'
        path.write_text(path.read_text().replace('public enum M1SelfTestRunner {',
            'public enum M1SelfTestRunner {\npublic static func runExtra() {}'))
        with self.assertRaises(ValueError): inventory.inspect(self.root)

    def test_extensions_and_other_runner_types_cannot_escape_discovery(self):
        path = self.root / 'Sources/ShadowSyncCore/AdditionalChecks.swift'
        for declaration in ('extension M1SelfTestRunner', 'public struct NewSelfTestRunner',
                            'public final class NewSelfTestRunner', 'public\nenum NewSelfTestRunner'):
            path.write_text('#if SHADOW_SYNC_TESTING\n' + declaration
                            + ' {\npublic static func runExtra() {}\n}\n#endif\n')
            with self.subTest(declaration=declaration), self.assertRaises(ValueError):
                inventory.inspect(self.root)

    def test_implicit_extension_access_and_unsupported_modifiers_refuse(self):
        path = self.root / 'Sources/ShadowSyncCore/AdditionalChecks.swift'
        for declaration, method in (
                ('public extension M1SelfTestRunner', 'static func runExtra() {}'),
                ('extension Module.M1SelfTestRunner', 'public static func runExtra() {}'),
                ('public actor NewSelfTestRunner', 'public static func runExtra() {}'),
                ('extension M1SelfTestRunner', 'public nonisolated static func runExtra() {}'),
                ('public class NewSelfTestRunner', 'public class func runExtra() {}')):
            path.write_text('#if SHADOW_SYNC_TESTING\n' + declaration + ' {\n'
                            + method + '\n}\n#endif\n')
            with self.subTest(declaration=declaration), self.assertRaises(ValueError):
                inventory.inspect(self.root)
        path.unlink()
        path = self.root / 'Sources/ShadowSyncCore/M1SelfTests.swift'
        path.write_text(path.read_text().replace('public enum M1SelfTestRunner {',
            'public enum M1SelfTestRunner {\npublic nonisolated static func runExtra() {}'))
        with self.assertRaises(ValueError): inventory.inspect(self.root)

    def test_removed_renamed_or_duplicate_catalog_entry_refuses(self):
        path = self.root/'Tests/ShadowSyncSelfTests/CISuites.swift'
        original = path.read_text()
        line = next(line for line in original.splitlines(True) if 'Entry(id: "m1"' in line)
        for text in (original.replace(line, ''), original.replace(line, line+line),
                     original.replace('Entry(id: "m1"', 'Entry(id: "renamed"')):
            path.write_text(text)
            with self.assertRaises(ValueError): inventory.inspect(self.root)

    def test_missing_native_probe_or_production_test_seam_refuses(self):
        path = self.root/'scripts/verify-m5.sh'
        path.write_text(path.read_text().replace('result["coreTests"] == [', 'unverified = ['))
        with self.assertRaises(ValueError): inventory.inspect(self.root)
        path.write_bytes((ROOT/'scripts/verify-m5.sh').read_bytes())
        path = self.root/'Sources/ShadowSyncCore/M1SelfTests.swift'
        path.write_text(path.read_text().replace('#if SHADOW_SYNC_TESTING', '#if true', 1))
        with self.assertRaises(ValueError): inventory.inspect(self.root)

    def test_exact_compiled_discovery_matches(self):
        result = inventory.inspect(self.root)
        payload = {'schema': 'shadow-sync-runtime-suite-discovery/v1',
                   'suites': [{'id': s['id'], 'cases': s['cases']} for s in result['suites']]}
        inventory.validate_discovery(result, json.dumps(payload).encode())
        for changed in ([], payload['suites'][:-1], payload['suites']+payload['suites'][:1],
                        list(reversed(payload['suites']))):
            with self.assertRaises(ValueError):
                inventory.validate_discovery(result, json.dumps({**payload, 'suites': changed}).encode())
        changed = copy.deepcopy(payload); changed['suites'][0]['cases'].append('unregistered')
        with self.assertRaises(ValueError): inventory.validate_discovery(result, json.dumps(changed).encode())

    def test_malformed_or_duplicate_discovery_refuses(self):
        result = inventory.inspect(self.root)
        for data in (b'', b'{}', b'null', b'{"schema":0,"schema":1}', b'NaN', b' ' * 262145):
            with self.assertRaises(ValueError): inventory.validate_discovery(result, data)


if __name__ == '__main__':
    unittest.main()
