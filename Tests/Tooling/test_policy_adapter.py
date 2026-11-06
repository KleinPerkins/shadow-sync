"""Fixture-only protocol, trust, pre-access, and cleanup tests; no installed AWA."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from test_host_projection import fixture_projection

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("policy_adapter", ROOT / "Resources/PolicyAdapter.py")
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)

MODULE = b'''from dataclasses import dataclass
HARD_NO_TOUCH_SCHEMA = "awa-hard-no-touch/v1"
@dataclass
class Decision:
    matched: bool
    kind: str
    policy_valid: bool
class HardNoTouchMatcher:
    def classify(self, candidate):
        return Decision(False, "none", True)
def load_hard_no_touch_matcher(path, *, home):
    from pathlib import Path
    assert Path(path).read_bytes() == b"version: 1\\nhard_no_touch_paths: {}\\n"
    assert home.startswith("/")
    return HardNoTouchMatcher()
'''


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


class PolicyAdapterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="shadow-sync-adapter-")
        # Resolve the fixture's system tmp alias, never a candidate repository path.
        self.home = Path(self.directory.name).resolve()
        self.uid = os.geteuid()
        self.temporary = self.home / "temporary"
        self.temporary.mkdir(mode=0o700)
        self.policy = self.home / "policy.yml"
        self.policy.write_bytes(b"version: 1\nhard_no_touch_paths: {}\n")
        self.projection = self.home / "projection.json"
        self.projection.write_bytes(encoded(fixture_projection(
            {'path': 'policy.yml', 'sha256': adapter.digest(self.policy.read_bytes())}
        )))
        self.module = self.home / "awa_policy.py"
        self.module.write_bytes(MODULE)
        self.binding = {"schema": adapter.BINDING_SCHEMA,
                        "policy": {"path": "policy.yml", "sha256": adapter.digest(self.policy.read_bytes())},
                        "projection": {"path": "projection.json", "sha256": adapter.digest(self.projection.read_bytes())},
                        "awa": {"module_path": "awa_policy.py", "module_sha256": adapter.digest(MODULE),
                                "release_revision": "a" * 40}}
        self.binding_path = self.home / adapter.BINDING_PATH
        self.binding_path.parent.mkdir(parents=True)
        self.contract = {"schema": adapter.CONTRACT_SCHEMA, "status": "qualified",
                         "release_revision": "a" * 40, "module_sha256": adapter.digest(MODULE)}
        self.request = {"schema": adapter.REQUEST_SCHEMA, "nonce": "b" * 32,
                        "candidate": str(self.home / "protected" / "unopened"),
                        "binding_sha256": ""}
        self.sync_binding()

    def tearDown(self):
        self.directory.cleanup()

    def sync_binding(self):
        self.binding_path.write_bytes(encoded(self.binding))
        self.request["binding_sha256"] = adapter.digest(self.binding_path.read_bytes())

    def replace_module(self, source):
        self.module.write_bytes(source)
        self.contract["module_sha256"] = adapter.digest(source)
        self.binding["awa"]["module_sha256"] = adapter.digest(source)
        self.sync_binding()

    def run_adapter(self, *, raw=None):
        return adapter.classify(raw if raw is not None else encoded(self.request), encoded(self.contract),
                                home=str(self.home), uid=self.uid, temporary_parent=str(self.temporary))

    def test_allow_is_exact_digest_bound_and_never_opens_the_candidate(self):
        actual_open = os.open
        candidate = self.request["candidate"]
        def checked_open(path, *args, **kwargs):
            self.assertNotEqual(str(path), candidate)
            return actual_open(path, *args, **kwargs)
        with patch.object(adapter.os, "open", side_effect=checked_open):
            result = self.run_adapter()
        self.assertEqual((result["matched"], result["kind"], result["policy_valid"]), (False, "none", True))
        self.assertEqual(result["nonce"], self.request["nonce"])
        self.assertEqual(result["binding_sha256"], self.request["binding_sha256"])
        self.assertEqual(result["module_sha256"], self.contract["module_sha256"])
        self.assertEqual(list(self.temporary.iterdir()), [])

    def test_pending_release_refuses_before_loading_host_configuration(self):
        self.contract["status"] = "pending_release"
        with patch.object(adapter, "read_owned_absolute") as read, self.assertRaises(adapter.Refusal):
            self.run_adapter()
        read.assert_not_called()

    def test_absent_or_noncanonical_required_section_refuses_even_with_valid_binding(self):
        # AWA deliberately allows an omitted optional field. ShadowSync's host
        # deployment contract requires it; a valid no-match alone is insufficient.
        permissive = b'\n'.join(line for line in MODULE.split(b'\n')
                               if b'assert Path(path).read_bytes()' not in line)
        self.replace_module(permissive)
        for policy in (b'version: 1\n', b'version: 1\n# hard_no_touch_paths: {}\n',
                       b'version: 1\nother:\n  hard_no_touch_paths: {}\n',
                       b'version: 1\n"hard_no_touch_paths": {}\n',
                       b'version: 1\nhard_no_touch_paths: {}\nhard_no_touch_paths: {}\n'):
            self.policy.write_bytes(policy)
            self.binding['policy']['sha256'] = adapter.digest(policy)
            self.sync_binding()
            with self.subTest(policy=policy), patch.object(adapter, 'policy_snapshot') as snapshot:
                with self.assertRaises(adapter.Refusal):
                    self.run_adapter()
                snapshot.assert_not_called()

    def test_missing_and_changed_binding_refuse(self):
        self.binding_path.unlink()
        with self.assertRaises(OSError): self.run_adapter()
        self.sync_binding(); self.binding_path.write_bytes(self.binding_path.read_bytes() + b"\n")
        with self.assertRaises(adapter.Refusal): self.run_adapter()

    def test_invalid_projection_refuses_even_when_its_hash_is_bound(self):
        for raw in (b'{"schema":"fixture/v1"}', b'{}', b'null'):
            self.projection.write_bytes(raw)
            self.binding['projection']['sha256'] = adapter.digest(raw)
            self.sync_binding()
            with self.subTest(raw=raw), patch.object(adapter, 'policy_snapshot') as snapshot:
                with self.assertRaises(adapter.Refusal): self.run_adapter()
                snapshot.assert_not_called()

    def test_duplicate_unknown_and_malformed_request_fields_refuse(self):
        cases = [b'{}', b'null', b'{"schema":1,"schema":2}', b'{', b'NaN']
        for key, value in (("extra", True), ("nonce", 1), ("candidate", []),
                           ("binding_sha256", "f" * 63), ("schema", "future/v9")):
            request = dict(self.request); request[key] = value; cases.append(encoded(request))
        for raw in cases:
            with self.subTest(raw=raw[:80]), self.assertRaises(adapter.Refusal): self.run_adapter(raw=raw)

    def test_oversized_request_refuses(self):
        with self.assertRaises(adapter.Refusal): self.run_adapter(raw=b" " * (adapter.MAX_REQUEST + 1))
        self.request["candidate"] = "x" * 4097
        with self.assertRaises(adapter.Refusal): self.run_adapter()

    def test_noncanonical_candidate_refuses_before_configuration_access(self):
        for candidate in ("relative", "~/protected", "", "/", "/protected/../allowed",
                          "/protected/./child", "//protected", "/protected//child", "/protected/child/"):
            self.request["candidate"] = candidate
            with self.subTest(candidate=candidate), patch.object(adapter, "read_owned_absolute") as read:
                with self.assertRaises(adapter.Refusal): self.run_adapter()
                read.assert_not_called()

    def test_unknown_binding_fields_and_schemas_refuse(self):
        for key, value in (("extra", True), ("schema", "future/v2")):
            saved = copy.deepcopy(self.binding); self.binding[key] = value; self.sync_binding()
            with self.assertRaises(adapter.Refusal): self.run_adapter()
            self.binding = saved; self.sync_binding()

    def test_untrusted_paths_refuse_without_resolving_them(self):
        for path in ("../policy.yml", "/policy.yml", "a//b", "a/./b", "a/../b", "a\\b", "a\x00b"):
            self.binding["policy"]["path"] = path; self.sync_binding()
            with self.subTest(path=path), self.assertRaises(adapter.Refusal): self.run_adapter()

    def test_symlink_hardlink_unsafe_mode_and_wrong_owner_refuse(self):
        original = self.policy.read_bytes()
        target = self.home / "target"; target.write_bytes(original)
        self.policy.unlink(); self.policy.symlink_to(target)
        with self.assertRaises(OSError): self.run_adapter()
        self.policy.unlink(); os.link(target, self.policy)
        with self.assertRaises(adapter.Refusal): self.run_adapter()
        self.policy.unlink(); self.policy.write_bytes(original); self.policy.chmod(0o666)
        with self.assertRaises(adapter.Refusal): self.run_adapter()
        self.policy.chmod(0o600)
        with self.assertRaises(adapter.Refusal):
            adapter.read_owned_absolute(str(self.policy), self.uid + 1)

    def test_changed_policy_projection_module_or_release_refuses(self):
        for path in (self.policy, self.projection, self.module):
            before = path.read_bytes(); path.write_bytes(before + b"\n")
            with self.subTest(path=path.name), self.assertRaises(adapter.Refusal): self.run_adapter()
            path.write_bytes(before)
        self.binding["awa"]["release_revision"] = "c" * 40; self.sync_binding()
        with self.assertRaises(adapter.Refusal): self.run_adapter()

    def test_wrong_contract_and_zero_revision_refuse(self):
        for key, value in (("schema", "future/v2"), ("extra", 1), ("release_revision", "0" * 40)):
            saved = dict(self.contract); self.contract[key] = value
            with self.assertRaises(adapter.Refusal): self.run_adapter()
            self.contract = saved

    def test_module_output_and_wrong_awa_schema_refuse(self):
        for source in (MODULE + b'\nprint("unexpected")\n',
                       MODULE.replace(b'awa-hard-no-touch/v1', b'awa-hard-no-touch/v2')):
            self.replace_module(source)
            with self.assertRaises(adapter.Refusal): self.run_adapter()
            self.assertNotIn('_shadow_sync_verified_awa_policy', sys.modules)

    def test_all_refusal_decisions_remain_denied_and_inconsistent_decisions_refuse(self):
        for kind, valid in (("exact_root", True), ("managed_namespace", True),
                            ("invalid_candidate", True), ("invalid_policy", False)):
            source = MODULE.replace(b'Decision(False, "none", True)',
                                    f'Decision(True, "{kind}", {valid})'.encode())
            self.replace_module(source); result = self.run_adapter()
            self.assertTrue(result["matched"]); self.assertEqual(result["kind"], kind)
        for decision in ('Decision(0, "none", True)', 'Decision(False, "unknown", True)',
                         'Decision(False, "invalid_policy", False)', 'Decision(False, "none", 1)'):
            self.replace_module(MODULE.replace(b'Decision(False, "none", True)', decision.encode()))
            with self.assertRaises(adapter.Refusal): self.run_adapter()

    def test_policy_change_during_classification_refuses_and_cleans_snapshot(self):
        replacement = ('def load_hard_no_touch_matcher(path, *, home):\n'
                       '    from pathlib import Path\n'
                       '    Path(home, "policy.yml").write_bytes(b"changed")\n'
                       '    return HardNoTouchMatcher()\n').encode()
        self.replace_module(MODULE[:MODULE.index(b'def load_hard_no_touch_matcher')] + replacement)
        with self.assertRaises(adapter.Refusal): self.run_adapter()
        self.assertEqual(list(self.temporary.iterdir()), [])

    def test_module_exception_cleans_snapshot_and_module_registration(self):
        self.replace_module(MODULE.replace(b'return HardNoTouchMatcher()', b'raise ValueError("fixture failure")'))
        with self.assertRaises(ValueError): self.run_adapter()
        self.assertEqual(list(self.temporary.iterdir()), [])
        self.assertNotIn('_shadow_sync_verified_awa_policy', sys.modules)

    def test_policy_snapshot_is_unlinked_read_only_and_descriptor_bound(self):
        assertion = b"""    import fcntl, os, stat
    assert path.startswith('/dev/fd/')
    descriptor = int(path.rsplit('/', 1)[1])
    info = os.fstat(descriptor)
    assert stat.S_ISREG(info.st_mode) and info.st_nlink == 0
    assert fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY
"""
        source = MODULE.replace(b'    from pathlib import Path\n', assertion + b'    from pathlib import Path\n')
        self.replace_module(source)
        result = self.run_adapter()
        self.assertFalse(result['matched'])
        self.assertEqual(list(self.temporary.iterdir()), [])

    def test_snapshot_parent_symlink_and_unsafe_mode_refuse(self):
        target = self.home / 'snapshot-parent'; target.mkdir(mode=0o700)
        self.temporary.rmdir(); self.temporary.symlink_to(target, target_is_directory=True)
        with self.assertRaises((adapter.Refusal, OSError)):
            self.run_adapter()
        self.assertEqual(list(target.iterdir()), [])
        self.temporary.unlink(); self.temporary.mkdir(mode=0o777)
        self.temporary.chmod(0o777)
        with self.assertRaises(adapter.Refusal):
            self.run_adapter()
        self.assertEqual(list(self.temporary.iterdir()), [])

    def test_snapshot_parent_ancestor_symlink_refuses_before_creation(self):
        target = self.home / 'target'; target.mkdir(mode=0o700)
        nested = target / 'nested'; nested.mkdir(mode=0o700)
        link = self.home / 'alias'; link.symlink_to(target, target_is_directory=True)
        self.temporary = link / 'nested'
        with self.assertRaises((adapter.Refusal, OSError)):
            self.run_adapter()
        self.assertEqual(list(nested.iterdir()), [])

    def test_snapshot_name_collisions_preserve_existing_file(self):
        existing = self.temporary / ('shadow-sync-policy-' + 'a' * 32)
        existing.write_bytes(b'keep fixture bytes')
        with patch.object(adapter.secrets, 'token_hex', return_value='a' * 32), self.assertRaises(adapter.Refusal):
            self.run_adapter()
        self.assertEqual(existing.read_bytes(), b'keep fixture bytes')
        self.assertEqual(list(self.temporary.iterdir()), [existing])

    def test_partial_snapshot_write_failure_removes_only_owned_file(self):
        sentinel = self.temporary / 'unrelated'; sentinel.write_bytes(b'keep fixture bytes')
        real_write = os.write
        calls = []
        def fail_after_partial(descriptor, data):
            calls.append(descriptor)
            if len(calls) == 1:
                return real_write(descriptor, data[:2])
            raise OSError('fixture write failure')
        with patch.object(adapter.os, 'write', side_effect=fail_after_partial), self.assertRaises(OSError):
            self.run_adapter()
        self.assertEqual(sentinel.read_bytes(), b'keep fixture bytes')
        self.assertEqual(list(self.temporary.iterdir()), [sentinel])
        self.assertEqual(len(calls), 2)
        with self.assertRaises(OSError): os.fstat(calls[0])

    def test_snapshot_parent_replacement_cannot_redirect_writes_or_cleanup(self):
        original = self.home / 'original-temporary'
        real_token = adapter.secrets.token_hex
        invoked = []
        def move_parent(size):
            self.assertFalse(invoked); invoked.append(True)
            self.temporary.rename(original)
            self.temporary.mkdir(mode=0o700)
            (self.temporary / 'unrelated').write_bytes(b'keep fixture bytes')
            return real_token(size)
        with patch.object(adapter.secrets, 'token_hex', side_effect=move_parent):
            result = self.run_adapter()
        self.assertFalse(result['matched'])
        self.assertEqual(list(original.iterdir()), [])
        self.assertEqual((self.temporary / 'unrelated').read_bytes(), b'keep fixture bytes')
        self.assertEqual([p.name for p in self.temporary.iterdir()], ['unrelated'])

    def test_cli_rejects_nonisolated_startup_and_never_echoes_input(self):
        secret_candidate = 'fixture-private-candidate'
        # Some fixture interpreters disable bytecode by default. The sealed-entry
        # tests separately prove refusal when that flag is false.
        for flags in ([], ['-I'], ['-S']):
            result = subprocess.run([sys.executable, *flags, str(ROOT / 'Resources/PolicyAdapter.py')],
                                    input=secret_candidate, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn(secret_candidate, result.stdout + result.stderr)
            self.assertIn('isolated', result.stderr)


if __name__ == '__main__':
    unittest.main()
