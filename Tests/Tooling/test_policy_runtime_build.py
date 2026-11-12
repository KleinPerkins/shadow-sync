"""Closed packaging inputs and failures, using only disposable file fixtures."""
import importlib.util
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile
from unittest import mock
from types import SimpleNamespace


SOURCE = Path(__file__).resolve().parents[2] / "scripts/build-policy-runtime.py"
spec = importlib.util.spec_from_file_location("policy_runtime_build", SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RuntimeBuildTests(unittest.TestCase):
    def test_signature_layout_modes_survive_private_parent_mask(self):
        # Match the full private-mask caller condition, including payload copy,
        # notice creation and signing. Never execute the generated fixture dylib.
        with tempfile.TemporaryDirectory(prefix="shadow-sync-policy-build-umask-") as temporary:
            root = Path(temporary).resolve()
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            previous = os.umask(0o077)
            try:
                upstream = root / "upstream"
                upstream_resources = upstream / "Versions/3.14/Resources"
                upstream_resources.mkdir(parents=True)
                (upstream / "Versions/Current").symlink_to("3.14")
                (upstream / "Python").symlink_to("Versions/Current/Python")
                (upstream / "Resources").symlink_to("Versions/Current/Resources")
                code = root / "fixture.c"
                code.write_text("int shadow_sync_fixture(void) { return 0; }\n")
                executable = upstream / "Versions/3.14/Python"
                module.run(["/usr/bin/xcrun", "clang", "-dynamiclib", "-arch", "arm64", str(code), "-o", str(executable)])
                executable.chmod(0o755)
                (upstream_resources / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "com.example.policy-runtime-fixture", "CFBundleExecutable": "Python",
                    "CFBundleName": "Python", "CFBundlePackageType": "FMWK", "CFBundleVersion": "1"}))
                framework = root / "Python.framework"
                module.copy_selected(upstream, framework)
                version = framework / "Versions/3.14"
                resources = version / "Resources"
                module.install_notice_snapshot(module.load_notice_bundle(module.load_pin()), resources)
                for directory in [framework, framework / "Versions", version, resources, resources / "ThirdPartyNotices"]:
                    self.assertEqual(directory.stat().st_mode & 0o777, 0o755)
                module.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(framework)])
                module.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(framework)])
                self.assertEqual((version / "_CodeSignature").stat().st_mode & 0o777, 0o755)
                self.assertEqual((version / "_CodeSignature/CodeResources").stat().st_mode & 0o777, 0o644)
                self.assertEqual(os.umask(0o077), 0o077)
                self.assertEqual(int(module.run(["/bin/sh", "-c", "umask"]).strip(), 8), 0o077)
            finally:
                os.umask(previous)
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)

    def archive_inputs(self, root):
        source, bytecode = root / 'source', root / 'bytecode'
        source.mkdir(); bytecode.mkdir()
        sources, compiled = {}, {}
        for name, data in {'a.py': b'answer = 42\n', 'pkg/__init__.py': b''}.items():
            path = source / name; path.parent.mkdir(exist_ok=True); path.write_bytes(data)
            code = bytes.fromhex('2b0e0d0a03000000') + b'12345678' + b'unit-test-bytecode-body'
            target = bytecode / (name + 'c'); target.parent.mkdir(exist_ok=True); target.write_bytes(code)
            digest = hashlib.sha256(data).hexdigest(); sources[name] = digest
            compiled[name] = {'source_sha256': digest, 'bytecode_sha256': hashlib.sha256(code).hexdigest(),
                              'source_hash': code[8:16].hex(), 'bytecode_bytes': len(code)}
        return source, bytecode, sources, compiled

    def test_archive_is_deterministic_preserves_source_and_ignores_host_times(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, bytecode, sources, compiled = self.archive_inputs(root)
            first, second = root / 'first.zip', root / 'second.zip'
            members = module.write_stdlib_archive(source, bytecode, first, sources, compiled)
            os.utime(source / 'a.py', (1234567, 1234567))
            module.write_stdlib_archive(source, bytecode, second, dict(reversed(list(sources.items()))), compiled)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first.stat().st_mode & 0o777, 0o644)
            with zipfile.ZipFile(first) as z:
                self.assertEqual(z.namelist(), ['a.py', 'a.pyc', 'pkg/__init__.py', 'pkg/__init__.pyc'])
                self.assertEqual(z.read('a.py'), b'answer = 42\n')
                self.assertEqual(z.read('pkg/__init__.py'), b'')
            module.verify_stdlib_archive(first, members)
            self.assertTrue((source / 'a.py').exists())
            with self.assertRaises(FileExistsError):
                module.write_stdlib_archive(source, bytecode, first, sources, compiled)

    def test_archive_rejects_missing_wrong_source_bytecode_and_header_before_creation(self):
        for mutation in ['missing', 'source', 'bytecode', 'magic', 'unchecked', 'timestamp', 'binding']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                source, bytecode, sources, compiled = self.archive_inputs(root)
                if mutation == 'missing': del compiled['a.py']
                elif mutation == 'source': (source / 'a.py').write_bytes(b'changed')
                elif mutation == 'bytecode': (bytecode / 'a.pyc').write_bytes(b'changed')
                elif mutation == 'binding': compiled['a.py']['source_sha256'] = 'f' * 64
                else:
                    path = bytecode / 'a.pyc'; data = bytearray(path.read_bytes())
                    if mutation == 'magic': data[0] ^= 1
                    else: data[4] = 1 if mutation == 'unchecked' else 0
                    path.write_bytes(data); compiled['a.py']['bytecode_sha256'] = hashlib.sha256(data).hexdigest()
                target = root / 'output.zip'
                with self.assertRaises(module.BuildRefused):
                    module.write_stdlib_archive(source, bytecode, target, sources, compiled)
                self.assertFalse(target.exists())

    def test_archive_member_refusals_do_not_follow_links_or_read_special_files(self):
        for mutation in ['symlink', 'hardlink', 'fifo', 'parent-link']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                source, bytecode, sources, compiled = self.archive_inputs(root)
                if mutation == 'parent-link':
                    (source / 'pkg').rename(root / 'outside'); (source / 'pkg').symlink_to(root / 'outside')
                else:
                    target = source / 'a.py'; target.rename(root / 'outside')
                    if mutation == 'symlink': target.symlink_to(root / 'outside')
                    elif mutation == 'hardlink': os.link(root / 'outside', target)
                    else: os.mkfifo(target)
                with self.assertRaises((module.BuildRefused, OSError)):
                    module.write_stdlib_archive(source, bytecode, root / 'output.zip', sources, compiled)
                self.assertFalse((root / 'output.zip').exists())

    def test_archive_refuses_unsafe_names_and_preserves_an_existing_archive(self):
        for name in ['../x.py', '/x.py', 'a//b.py', './x.py', 'a/../x.py', 'a\\x.py', 'x.py\n', 'x.so']:
            self.assertFalse(module.valid_source_member(name), name)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, bytecode, sources, compiled = self.archive_inputs(root)
            target = root / 'output.zip'; target.write_bytes(b'owned predecessor')
            with self.assertRaises(FileExistsError):
                module.write_stdlib_archive(source, bytecode, target, sources, compiled)
            self.assertEqual(target.read_bytes(), b'owned predecessor')

    def test_archive_verification_rejects_rewritten_bytes_duplicate_extra_or_compressed_members(self):
        for mutation in ['bytes', 'extra', 'compressed', 'duplicate']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                source, bytecode, sources, compiled = self.archive_inputs(root)
                target = root / 'original.zip'
                members = module.write_stdlib_archive(source, bytecode, target, sources, compiled)
                damaged = root / 'damaged.zip'
                with zipfile.ZipFile(target) as incoming, zipfile.ZipFile(damaged, 'x') as out:
                    for info in incoming.infolist():
                        data = incoming.read(info)
                        if mutation == 'bytes' and info.filename == 'a.py': data = b'changed'
                        if mutation == 'compressed': info.compress_type = zipfile.ZIP_DEFLATED
                        out.writestr(info, data)
                    if mutation == 'extra': out.writestr('extra.py', b'extra')
                    if mutation == 'duplicate':
                        with self.assertWarns(UserWarning): out.writestr('a.py', b'extra')
                with self.assertRaises(module.BuildRefused): module.verify_stdlib_archive(damaged, members)

    def test_intended_publisher_configuration_rejects_another_team(self):
        expected = module.intended_publisher_team()
        module.validate_publisher_configuration(expected, False)
        for value in [None, "AAAAAAAAAA", "", "lowercase1"]:
            with self.subTest(value=value), self.assertRaises(module.BuildRefused):
                module.validate_publisher_configuration(value, False)

    def test_wrong_publisher_refuses_before_package_access_or_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            args = SimpleNamespace(publisher_team="AAAAAAAAAA", allow_ad_hoc_fixture=False,
                                   signing_identity="a" * 40, package="/missing-input.pkg", output=str(output))
            with mock.patch.object(module.sys, "platform", "darwin"), mock.patch.object(module, "load_pin", side_effect=AssertionError("package preflight reached")):
                with self.assertRaises(module.BuildRefused):
                    module.build(args)
            self.assertFalse(output.exists())

    def test_publisher_contract_cannot_disagree_with_compiled_source(self):
        contract = json.loads((module.ROOT / "Resources/release-contract.json").read_bytes())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Resources").mkdir()
            (root / "Sources/ShadowSyncCore").mkdir(parents=True)
            (root / "Resources/release-contract.json").write_text(json.dumps(contract))
            source = root / "Sources/ShadowSyncCore/ReleaseIdentity.swift"
            for body in ['public static let publisherTeamIdentifier = "AAAAAAAAAA"', '',
                         'public static let publisherTeamIdentifier = "AAAAAAAAAA"\npublic static let publisherTeamIdentifier = "BBBBBBBBBB"']:
                source.write_text(body)
                with self.subTest(body=body), mock.patch.object(module, "ROOT", root), self.assertRaises(module.BuildRefused):
                    module.intended_publisher_team()

    def test_ad_hoc_fixture_cannot_claim_a_publisher(self):
        module.validate_publisher_configuration(None, True)
        with self.assertRaises(module.BuildRefused):
            module.validate_publisher_configuration(module.intended_publisher_team(), True)

    def test_sqlite_notice_contains_actual_copyright_disclaimer(self):
        notice = module.load_notice_bundle(module.load_pin())["SQLite-3.50.4-PUBLIC-DOMAIN.txt"]
        self.assertIn(b"version 3.50.4.", notice)
        self.assertIn(b"The author disclaims copyright to this source code.", notice)
        self.assertIn(b"May you share freely, never taking more than you give.", notice)

    def test_notice_snapshot_is_complete_and_survives_source_removal(self):
        pin = module.load_pin()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            shutil.copytree(module.NOTICES_PATH, source)
            snapshot = module.load_notice_bundle(pin, source)
            self.assertEqual(len(snapshot), 16)
            manifest = json.loads(snapshot["manifest.json"])
            self.assertEqual(len(manifest["components"]), 10)
            shutil.rmtree(source)
            resources = root / "Resources"
            resources.mkdir()
            module.install_notice_snapshot(snapshot, resources)
            for name, data in snapshot.items():
                self.assertEqual((resources / "ThirdPartyNotices" / name).read_bytes(), data)
                self.assertEqual((resources / "ThirdPartyNotices" / name).stat().st_mode & 0o777, 0o644)
            with self.assertRaises(FileExistsError):
                module.install_notice_snapshot(snapshot, resources)

    def test_notice_input_refuses_missing_tampered_extra_and_special_files(self):
        pin = module.load_pin()
        for mutation in ["missing", "tampered", "extra", "symlink", "hardlink", "fifo", "manifest"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                source = root / "source"
                shutil.copytree(module.NOTICES_PATH, source)
                target = source / "NOTICE.txt"
                if mutation == "missing": target.unlink()
                elif mutation == "tampered": target.write_bytes(target.read_bytes() + b"changed")
                elif mutation == "extra": (source / "extra.txt").write_bytes(b"unreviewed")
                elif mutation == "manifest": (source / "manifest.json").write_bytes(b"{}")
                else:
                    data = target.read_bytes()
                    target.unlink()
                    if mutation == "fifo": os.mkfifo(target)
                    else:
                        outside = root / "outside"
                        outside.write_bytes(data)
                        if mutation == "symlink": target.symlink_to(outside)
                        else: os.link(outside, target)
                with self.assertRaises((OSError, module.BuildRefused)):
                    module.load_notice_bundle(pin, source)

    def test_notice_binding_refuses_another_package_recipe_or_source_revision(self):
        for key in ["package_sha256", "selection_recipe", "cpython_revision"]:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                source = root / "source"
                shutil.copytree(module.NOTICES_PATH, source)
                path = source / "manifest.json"
                value = json.loads(path.read_text())
                value[key] = "different-input"
                raw = json.dumps(value).encode()
                path.write_bytes(raw)
                pin = module.load_pin()
                pin["notices_manifest_sha256"] = hashlib.sha256(raw).hexdigest()
                with self.assertRaises(module.BuildRefused):
                    module.load_notice_bundle(pin, source)

    def test_notice_directory_cannot_be_redirected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "redirect").symlink_to(module.NOTICES_PATH)
            with self.assertRaises(OSError):
                module.load_notice_bundle(module.load_pin(), root / "redirect")

    def test_package_snapshot_is_bound_and_survives_original_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            original = root / "input.pkg"
            original.write_bytes(b"pinned fixture")
            out = root / "private"
            out.mkdir(mode=0o700)
            expected = hashlib.sha256(b"pinned fixture").hexdigest()
            snapshot = module.snapshot_package(original, out, 14, expected)
            original.unlink()
            original.write_bytes(b"replacement")
            self.assertEqual(snapshot.read_bytes(), b"pinned fixture")
            self.assertEqual(snapshot.stat().st_mode & 0o777, 0o400)
            self.assertEqual(module.sha(snapshot), expected)

    def test_package_snapshot_rejects_wrong_bytes_and_symlinks(self):
        for symlink in [False, True]:
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                (root / "bytes").write_bytes(b"wrong fixture!")
                original = root / "input.pkg"
                if symlink:
                    original.symlink_to("bytes")
                else:
                    original.write_bytes(b"wrong fixture!")
                out = root / "private"
                out.mkdir(mode=0o700)
                with self.assertRaises((OSError, module.BuildRefused)):
                    module.snapshot_package(original, out, 14, hashlib.sha256(b"pinned fixture").hexdigest())

    def test_requirement_restricts_developer_id_application_class(self):
        result = module.developer_id_requirement("ABCDEFGHIJ")
        self.assertTrue(result.startswith("=anchor apple generic and "))
        self.assertIn("certificate 1[field.1.2.840.113635.100.6.2.6]", result)
        self.assertIn("certificate leaf[field.1.2.840.113635.100.6.1.13]", result)
        self.assertTrue(result.endswith('certificate leaf[subject.OU] = "ABCDEFGHIJ"'))
        for team in ["", "bad", 'ABC\" or true']:
            with self.subTest(team=team), self.assertRaises(module.BuildRefused):
                module.developer_id_requirement(team)

    def test_upstream_identity_requires_trusted_psf_leaf_and_timestamp(self):
        output = ("   Status: signed by a developer certificate issued by Apple for distribution\n"
                  "   Signed with a trusted timestamp on: 2026-10-25 21:35:03 +0000\n"
                  "    1. Developer ID Installer: Python Software Foundation (BMM5U3QVKW)\n")
        module.validate_upstream_signature(output)
        for changed in [output.replace("1. Developer", "2. Developer"),
                        output.replace("BMM5U3QVKW", "ABCDEFGHIJ"),
                        output.replace("trusted timestamp", "untrusted timestamp"),
                        output.replace("Status: signed", "Status: unsigned")]:
            with self.subTest(changed=changed), self.assertRaises(module.BuildRefused):
                module.validate_upstream_signature(changed)

    def test_pin_is_closed_and_current(self):
        pin = module.load_pin()
        self.assertEqual(pin["architecture"], "arm64")
        self.assertEqual(pin["package_sha256"], "286c7018aa2730f6747ca433dccdc2b31be45f078a9ea0ffa44d5f06368fd2d7")

    def test_selection_preserves_runtime_and_notices(self):
        for path in ["Python", "Resources", "Versions/Current", "Versions/3.14/Python",
                     "Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
                     "Versions/3.14/lib/python3.14/LICENSE.txt",
                     "Versions/3.14/lib/python3.14/encodings/utf_8.py"]:
            with self.subTest(path=path):
                self.assertTrue(module.selected(path))

    def test_selection_excludes_gui_development_and_installers(self):
        for path in ["Headers", "Versions/3.14/Frameworks/Tk.framework",
                     "Versions/3.14/_CodeSignature/CodeResources", "Versions/3.14/bin/python3",
                     "Versions/3.14/include/python3.14/Python.h",
                     "Versions/3.14/lib/python3.14/test/test_os.py",
                     "Versions/3.14/lib/python3.14/config-3.14-darwin/python.o",
                     "Versions/3.14/lib/python3.14/ensurepip/__init__.py",
                     "Versions/3.14/lib/python3.14/venv/__init__.py",
                     "Versions/3.14/lib/python3.14/tkinter/__init__.py",
                     "Versions/3.14/lib/python3.14/lib-dynload/_tkinter.cpython-314-darwin.so",
                     "Versions/3.14/lib/python3.14/__pycache__/turtle.cpython-314.pyc",
                     "Versions/3.15/Python"]:
            with self.subTest(path=path):
                self.assertFalse(module.selected(path))

    def test_invalid_payload_path(self):
        for path in ["", "/Versions/3.14/Python", "Versions/../Python"]:
            with self.subTest(path=path), self.assertRaises(module.BuildRefused):
                module.selected(path)

    def test_ad_hoc_requires_explicit_fixture_mode(self):
        fixture = module.signing_arguments("-", None, True)
        self.assertIn("--timestamp=none", fixture)
        self.assertNotIn("runtime", fixture)
        for args in [("-", None, False), ("-", "ABCDEFGHIJ", True), ("", None, True)]:
            with self.subTest(args=args), self.assertRaises(module.BuildRefused):
                module.signing_arguments(*args)

    def test_release_identity_is_closed_and_timestamped(self):
        value = module.signing_arguments("a" * 40, "ABCDEFGHIJ", False)
        self.assertIn("--timestamp", value)
        self.assertIn("runtime", value)
        for args in [("Developer ID Application: Name", "ABCDEFGHIJ", False),
                     ("a" * 40, None, False), ("a" * 40, "x\" or true", False),
                     ("a" * 40, "ABCDEFGHIJ", True)]:
            with self.subTest(args=args), self.assertRaises(module.BuildRefused):
                module.signing_arguments(*args)

    def test_inventory_and_selected_copy_are_byte_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            (source / "Versions/3.14/Resources").mkdir(parents=True)
            (source / "Versions/3.14/Python").write_bytes(b"fixture-code")
            (source / "Versions/3.14/Resources/notice.txt").write_bytes(b"fixture notice")
            (source / "Versions/Current").symlink_to("3.14")
            (source / "Python").symlink_to("Versions/Current/Python")
            (source / "Headers").mkdir()
            (source / "Headers/unused.h").write_bytes(b"unselected")
            (source / "Headers/dangling").symlink_to("missing")
            expected = module.copy_selected(source, root / "output")
            actual = module.inventory(root / "output")
            self.assertEqual(set(actual), set(expected))
            self.assertNotIn("Headers", actual)
            self.assertEqual(actual["Versions/3.14/Python"]["sha256"],
                             expected["Versions/3.14/Python"]["sha256"])
            self.assertEqual((root / "output/Python").read_bytes(), b"fixture-code")

    def test_inventory_rejects_escaping_and_dangling_links(self):
        for target in ["../outside", "/private/tmp", "missing"]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                (root / "source").mkdir()
                (root / "outside").write_bytes(b"fixture")
                (root / "source/escape").symlink_to(target)
                with self.assertRaises((module.BuildRefused, FileNotFoundError)):
                    module.inventory(root / "source")

    def test_inventory_rejects_hardlinks_and_special_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "file").write_bytes(b"fixture")
            os.link(root / "file", root / "alias")
            with self.assertRaises(module.BuildRefused):
                module.inventory(root)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            os.mkfifo(root / "pipe")
            with self.assertRaises(module.BuildRefused):
                module.inventory(root)

    def test_dependencies_are_internal_or_canonical_system_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            framework = Path(temporary).resolve()
            (framework / "Versions/3.14/Resources").mkdir(parents=True)
            (framework / "Versions/3.14/Python").write_bytes(b"fixture")
            binary = framework / "Versions/3.14/Resources/helper"
            dependency = module.LEGACY + "Versions/3.14/Python"
            self.assertEqual(module.dependency_replacement(dependency, binary, framework),
                             "@loader_path/../Python")
            self.assertEqual(module.dependency_replacement("/usr/lib/libSystem.B.dylib", binary, framework),
                             "/usr/lib/libSystem.B.dylib")
            for dependency in ["/opt/homebrew/lib/libpython.dylib", "@rpath/unknown.dylib",
                               "/usr/lib/../../private/evil", module.LEGACY + "../escape"]:
                with self.subTest(dependency=dependency), self.assertRaises(module.BuildRefused):
                    module.dependency_replacement(dependency, binary, framework)


if __name__ == "__main__":
    unittest.main()
