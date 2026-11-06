import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/verify-technical-identity.py"
SPEC = importlib.util.spec_from_file_location("technical_identity", SCRIPT)
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)
OLD = "-".join(("dev", "main", "sync"))
SHORT = "".join(("D", "M", "S"))
POLICY = "config/identity-exceptions.json"


class IdentityGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="shadow-sync-identity-test-"
        )
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.git("init", "--quiet", "--initial-branch=main")
        self.write(POLICY, json.dumps({"schema": GATE.SCHEMA, "exceptions": []}))
        self.write("source.txt", "com.kleinperkins.shadow-sync\n")

    def git_at(self, root, *args):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        return subprocess.check_output(
            ["git", "-c", "core.hooksPath=/dev/null", "-C", str(root), *args],
            env=environment,
            stderr=subprocess.STDOUT,
        )

    def git(self, *args):
        return self.git_at(self.root, *args)

    def write_at(self, root, name, data, stage=True):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode() if isinstance(data, str) else data)
        if stage:
            self.git_at(root, "add", "--", name)
        return path

    def write(self, name, data, stage=True):
        return self.write_at(self.root, name, data, stage)

    def run_gate_root(self, root, *args, isolated=True, script=SCRIPT):
        command = [sys.executable]
        if isolated:
            command.extend(["-I", "-B"])
        command.extend([str(script), "--root", str(root), *args])
        run = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if isolated:
            self.assertEqual(run.stderr, "", run.stderr)
        receipt = json.loads(run.stdout) if run.stdout else None
        return run, receipt

    def run_gate(self, *args):
        run, receipt = self.run_gate_root(self.root, *args)
        return run.returncode, receipt

    def exception(self, path="history.txt", scope="content", token=OLD, count=1):
        return {
            "path": path,
            "scope": scope,
            "token": token,
            "count": count,
            "sha256": hashlib.sha256((self.root / path).read_bytes()).hexdigest(),
            "class": "historical-record",
            "owner": "product-owner",
            "reason": "Immutable historical evidence",
            "retirement": "Preserve original history",
        }

    def policy(self, entries):
        self.write(POLICY, json.dumps({"schema": GATE.SCHEMA, "exceptions": entries}))

    def make_artifact(self):
        artifact = self.root / "bundle"
        (artifact / "config").mkdir(parents=True)
        (artifact / POLICY).write_bytes((self.root / POLICY).read_bytes())
        return artifact

    def test_clean_tracked_tree_and_structured_machine_receipt(self):
        code, receipt = self.run_gate()
        self.assertEqual(code, 0)
        self.assertTrue(receipt["passed"])
        self.assertEqual(receipt["entries_scanned"], 2)
        self.assertEqual(receipt["files_scanned"], 2)
        self.assertEqual(receipt["directories_scanned"], 0)
        self.assertEqual(receipt["inventory_schema"], GATE.INVENTORY_SCHEMA)
        self.assertRegex(receipt["inventory_sha256"], "^[a-f0-9]{64}$")

    def test_all_discovered_spelling_families_are_rejected_case_insensitively(self):
        tokens = [
            OLD,
            OLD.replace("-", "_"),
            "dev" + "MainSync",
            "Dev" + "MainSync",
            OLD.upper().replace("-", "_") + "_ROOT",
            SHORT + "_ROOT",
            SHORT.lower() + "_lock",
            "--_" + SHORT.lower() + "-worker",
            "--" + SHORT.lower() + "-test-probe",
            "dM" + "sCoNtRoL",
            "Dev" + " Main Sync",
            "CoM.KlEiNpErKiNs." + "ShAdOwSyNc",
        ]
        for value in tokens:
            with self.subTest(value=value):
                self.write("source.txt", value)
                code, receipt = self.run_gate()
                self.assertEqual(code, 1)
                self.assertFalse(receipt["passed"])

    def test_encoded_legacy_shortcut_namespace_is_rejected(self):
        value = bytes((68, 77, 83, 89))
        number = int.from_bytes(value, "big")
        tokens = []
        for prefix, style in (("0x", "x"), ("0o", "o"), ("0b", "b"), ("", "d")):
            digits = format(number, style)
            tokens.extend((prefix + digits, prefix.upper() + digits.upper(),
                           prefix + "0" + digits, prefix + "000" + digits,
                           prefix + "__".join(digits),
                           prefix + "0__" + "_".join(digits) + "__"))
        for token in tokens:
            with self.subTest(token=token):
                self.write("source.swift", "let signature = " + token)
                code, receipt = self.run_gate()
                self.assertEqual(code, 1)
                self.assertTrue(any(item.get("token") == token
                                    for item in receipt["findings"]))

    def test_new_shortcut_namespace_and_unrelated_numbers_are_allowed(self):
        new = bytes((83, 72, 83, 89))
        old = bytes((68, 77, 83, 89)).hex()
        for token in ("0x" + new.hex(), str(int.from_bytes(new, "big")),
                      "0x1" + old, "0x" + old + "0"):
            with self.subTest(token=token):
                self.write("source.swift", "let signature = " + token)
                self.assertEqual(self.run_gate()[0], 0)

    def test_filename_is_scanned_even_with_clean_contents(self):
        self.write(OLD + ".txt", "clean")
        code, receipt = self.run_gate()
        self.assertEqual(code, 1)
        self.assertTrue(any(item.get("scope") == "path" for item in receipt["findings"]))

    def test_exact_immutable_exception_passes(self):
        self.write("history.txt", OLD)
        self.policy([self.exception()])
        code, receipt = self.run_gate()
        self.assertEqual(code, 0)
        self.assertEqual(receipt["exceptions_used"], 1)

    def test_exception_cannot_cover_another_file(self):
        self.write("history.txt", OLD)
        self.policy([self.exception()])
        self.write("source.txt", OLD)
        self.assertEqual(self.run_gate()[0], 1)

    def test_count_change_and_unrelated_content_change_both_fail(self):
        self.write("history.txt", OLD)
        original = self.exception()
        self.policy([original])
        for contents in (OLD + OLD, OLD + "extra"):
            with self.subTest(contents=contents):
                self.write("history.txt", contents)
                self.assertEqual(self.run_gate()[0], 1)

    def test_stale_exception_is_rejected(self):
        self.write("history.txt", OLD)
        self.policy([self.exception()])
        self.write("history.txt", "retired")
        code, receipt = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("stale", receipt["findings"][0]["reason"])

    def test_policy_is_closed_not_an_arbitrary_exclusion(self):
        self.write("history.txt", OLD)
        entry = self.exception()
        cases = [
            dict(entry, glob="*"),
            dict(entry, count=True),
            dict(entry, token="*"),
            dict(entry, owner=""),
            dict(entry, retirement=""),
            dict(entry, path="../outside"),
            dict(entry, scope="directory"),
            dict(entry, reason=OLD),
            dict(entry, **{"class": "active-code"}),
            dict(entry, **{"class": []}),
        ]
        for value in cases:
            with self.subTest(value=value):
                self.policy([value])
                self.assertEqual(self.run_gate()[0], 2)

    def test_duplicate_keys_entries_and_deep_json_fail_structured(self):
        self.write(POLICY, '{"schema":"' + GATE.SCHEMA + '","exceptions":[],"exceptions":[]}')
        code, receipt = self.run_gate()
        self.assertEqual(code, 2)
        self.assertEqual(receipt["schema"], GATE.RECEIPT_SCHEMA)
        self.write("history.txt", OLD)
        self.policy([self.exception(), self.exception()])
        self.assertEqual(self.run_gate()[0], 2)
        deep = '{"schema":"' + GATE.SCHEMA + '","exceptions":' + "[" * 2000 + "]" * 2000 + "}"
        self.write(POLICY, deep)
        code, receipt = self.run_gate()
        self.assertEqual(code, 2)
        self.assertEqual(receipt["schema"], GATE.RECEIPT_SCHEMA)
        self.assertIn("error", receipt)

    def test_policy_parser_resource_and_shape_failures_are_structured(self):
        self.write("history.txt", OLD)
        oversized_metadata = self.exception()
        oversized_metadata["reason"] = "x" * (GATE.METADATA_LIMIT + 1)
        cases = [
            b"\xff",
            json.dumps({"schema": GATE.SCHEMA, "exceptions": [None]}),
            json.dumps(
                {
                    "schema": GATE.SCHEMA,
                    "exceptions": [None] * (GATE.EXCEPTION_LIMIT + 1),
                }
            ),
            json.dumps(
                {"schema": GATE.SCHEMA, "exceptions": [oversized_metadata]}
            ),
            b" " * (GATE.POLICY_LIMIT + 1),
        ]
        for value in cases:
            with self.subTest(length=len(value)):
                self.write(POLICY, value)
                code, receipt = self.run_gate()
                self.assertEqual(code, 2)
                self.assertEqual(receipt["schema"], GATE.RECEIPT_SCHEMA)
                self.assertIn("error", receipt)

    def test_binary_ascii_and_both_wide_string_alignments(self):
        for encoding in ("ascii", "utf-16-le", "utf-16-be"):
            for prefix in (b"\0\xff", b"\xff"):
                with self.subTest(encoding=encoding, prefix=prefix):
                    self.write("product.bin", prefix + OLD.encode(encoding) + b"\0")
                    self.assertEqual(self.run_gate()[0], 1)

    def test_deleted_tracked_file_cannot_disappear_from_coverage(self):
        (self.root / "source.txt").unlink()
        self.assertEqual(self.run_gate()[0], 2)

    def test_tracked_symlink_scans_link_text_without_following_target(self):
        target = self.root / "target"
        target.write_text(OLD)
        link = self.root / "link"
        link.symlink_to("target")
        self.git("add", "link")
        self.assertEqual(self.run_gate()[0], 0)
        self.assertEqual(target.read_text(), OLD)
        link.unlink()
        link.symlink_to(OLD)
        self.git("add", "link")
        self.assertEqual(self.run_gate()[0], 1)

    def test_symlinked_parent_of_a_tracked_file_is_refused(self):
        self.write("folder/item", "safe")
        (self.root / "folder").rename(self.root / "moved")
        (self.root / "folder").symlink_to("moved")
        self.assertEqual(self.run_gate()[0], 2)

    def test_source_binds_regular_type_mode_and_index_blob(self):
        self.write("bound", "clean")
        (self.root / "bound").write_text(OLD)
        self.assertEqual(self.run_gate()[0], 2)
        self.write("bound", "clean")
        (self.root / "bound").chmod(0o755)
        self.assertEqual(self.run_gate()[0], 2)
        (self.root / "bound").chmod(0o644)
        (self.root / "bound").unlink()
        (self.root / "bound").symlink_to("source.txt")
        self.assertEqual(self.run_gate()[0], 2)

    def test_sha1_and_sha256_git_blob_bindings(self):
        self.assertEqual(self.run_gate()[0], 0)
        other_temp = tempfile.TemporaryDirectory(prefix="shadow-sync-sha256-test-")
        self.addCleanup(other_temp.cleanup)
        other = Path(other_temp.name).resolve()
        self.git_at(other.parent, "init", "--quiet", "--initial-branch=main", "--object-format=sha256", str(other))
        self.write_at(other, POLICY, json.dumps({"schema": GATE.SCHEMA, "exceptions": []}))
        self.write_at(other, "source.txt", "clean")
        run, receipt = self.run_gate_root(other)
        self.assertEqual(run.returncode, 0, receipt)

    def test_end_revalidation_rejects_index_drift(self):
        inventory = GATE.git_inventory(self.root)
        calls = 0

        def loader():
            nonlocal calls
            calls += 1
            if calls == 1:
                self.write("late.txt", "clean")
            return GATE.git_inventory(self.root)

        with self.assertRaisesRegex(GATE.Refusal, "inventory changed"):
            GATE.scan(self.root, inventory, loader, POLICY)

    def test_end_revalidation_rejects_post_inventory_byte_drift(self):
        inventory = GATE.git_inventory(self.root)
        calls = 0

        def loader():
            nonlocal calls
            calls += 1
            snapshot = GATE.git_inventory(self.root)
            if calls == 1:
                (self.root / "source.txt").write_text("changed after inventory")
            return snapshot

        with self.assertRaisesRegex(GATE.Refusal, "Git index blob"):
            GATE.scan(self.root, inventory, loader, POLICY)

    def test_end_revalidation_rejects_root_drift(self):
        inventory = GATE.git_inventory(self.root)
        original_mode = self.root.stat().st_mode & 0o777
        calls = 0

        def loader():
            nonlocal calls
            calls += 1
            snapshot = GATE.git_inventory(self.root)
            if calls == 1:
                self.root.chmod(0o700 if original_mode != 0o700 else 0o755)
            return snapshot

        self.addCleanup(self.root.chmod, original_mode)
        with self.assertRaisesRegex(GATE.Refusal, "root changed"):
            GATE.scan(self.root, inventory, loader, POLICY)

    def test_control_characters_in_inventory_paths_fail_closed(self):
        self.write("bad\nname.txt", "clean")
        code, receipt = self.run_gate()
        self.assertEqual(code, 2)
        self.assertIn("control character", receipt["error"])

    def test_artifact_scan_counts_empty_directories_and_rejects_old_directory_name(self):
        artifact = self.make_artifact()
        (artifact / "empty").mkdir()
        run, receipt = self.run_gate_root(artifact, "--artifact-root")
        self.assertEqual(run.returncode, 0, receipt)
        self.assertEqual(receipt["files_scanned"], 1)
        self.assertEqual(receipt["directories_scanned"], 2)
        self.assertEqual(receipt["entries_scanned"], 3)
        (artifact / ("dEv-MaIn-" + "SyNc-empty")).mkdir()
        run, receipt = self.run_gate_root(artifact, "--artifact-root")
        self.assertEqual(run.returncode, 1, receipt)
        self.assertTrue(any(item.get("scope") == "path" for item in receipt["findings"]))

    def test_artifact_scan_includes_untracked_files(self):
        self.write("untracked.bin", OLD, stage=False)
        self.assertEqual(self.run_gate()[0], 0)
        artifact = self.make_artifact()
        (artifact / "binary").write_bytes(OLD.encode())
        run, receipt = self.run_gate_root(artifact, "--artifact-root")
        self.assertEqual(run.returncode, 1, receipt)
        self.assertEqual(receipt["files_scanned"], 2)
        self.assertEqual(receipt["directories_scanned"], 1)

    def test_artifact_unreadable_directory_refuses_instead_of_skipping(self):
        artifact = self.make_artifact()
        sealed = artifact / "sealed"
        sealed.mkdir()
        sealed.chmod(0)
        self.addCleanup(sealed.chmod, 0o755)
        run, receipt = self.run_gate_root(artifact, "--artifact-root")
        self.assertEqual(run.returncode, 2, receipt)
        self.assertIn("unreadable", receipt["error"])

    def test_artifact_directory_symlink_is_not_followed(self):
        artifact = self.make_artifact()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "hidden").write_text(OLD)
        (artifact / "external").symlink_to(outside)
        run, receipt = self.run_gate_root(artifact, "--artifact-root")
        self.assertEqual(run.returncode, 0, receipt)
        self.assertEqual(receipt["files_scanned"], 2)

    def test_artifact_end_inventory_rejects_late_entry(self):
        artifact = self.make_artifact()
        inventory = GATE.artifact_inventory(artifact)
        calls = 0

        def loader():
            nonlocal calls
            calls += 1
            snapshot = GATE.artifact_inventory(artifact)
            if calls == 1:
                (artifact / "late").write_text("clean")
            return snapshot

        with self.assertRaisesRegex(GATE.Refusal, "inventory changed"):
            GATE.scan(artifact, inventory, loader, POLICY)

    def test_policy_must_be_tracked_regular_and_cannot_allowlist_itself(self):
        self.git("rm", "--cached", "--quiet", POLICY)
        self.assertEqual(self.run_gate()[0], 2)

    def test_policy_path_cannot_hide_an_old_filename(self):
        name = OLD + ".json"
        self.write(name, (self.root / POLICY).read_bytes())
        self.assertEqual(self.run_gate("--policy", name)[0], 2)

    def test_exact_path_exception_and_content_exception_are_independent(self):
        path = OLD + ".txt"
        self.write(path, OLD)
        self.policy([self.exception(path=path, scope="path")])
        self.assertEqual(self.run_gate()[0], 1)
        self.policy([self.exception(path=path, scope="path"), self.exception(path=path)])
        self.assertEqual(self.run_gate()[0], 0)

    def test_direct_nonisolated_launch_refuses_before_tool_imports(self):
        run, receipt = self.run_gate_root(self.root, isolated=False)
        self.assertEqual(run.returncode, 2)
        self.assertIsNone(receipt)
        self.assertIn("refusing non-isolated Python startup", run.stderr)

    def test_isolated_launch_ignores_script_directory_import_shadow(self):
        copied = self.root / "tools/gate.py"
        copied.parent.mkdir()
        shutil.copyfile(SCRIPT, copied)
        self.write("tools/gate.py", copied.read_bytes())
        self.write("tools/json.py", "raise RuntimeError('must not import')\n")
        run, receipt = self.run_gate_root(self.root, script=copied)
        self.assertEqual(run.returncode, 0, receipt)

    def test_supported_shebang_launch_is_isolated(self):
        run = subprocess.run(
            [str(SCRIPT), "--root", str(self.root)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(run.stderr, "", run.stderr)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertTrue(json.loads(run.stdout)["passed"])


if __name__ == "__main__":
    unittest.main()
