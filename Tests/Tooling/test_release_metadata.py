"""Standalone metadata and retired installer boundary checks; no live setup."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseMetadataTests(unittest.TestCase):
    def test_initial_identity_and_platform(self):
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.kleinperkins.shadow-sync")
        self.assertEqual(info["CFBundleShortVersionString"], "0.10.0")
        self.assertEqual(info["CFBundleVersion"], "15")
        self.assertEqual(info["ShadowSyncReleaseSchema"], "shadow-sync-release/v2")
        self.assertEqual(info["ShadowSyncArchitecture"], "arm64")
        self.assertEqual(info["LSMinimumSystemVersion"], "26.0")

        # Exercise the actual build platform probe with more output than a pipe
        # buffer; a correct minos value must not hide or induce producer failure.
        build = (ROOT / "scripts/build-app.sh").read_text()
        probe = build[build.index('MIN_OS="$(otool'):build.index('\ndone', build.index('MIN_OS="$(otool'))]
        with tempfile.TemporaryDirectory(prefix="shadow-sync-platform-probe-") as temporary:
            root = Path(temporary)
            tool = root / "otool"
            for version, producer_exit, expected in [("26.0", 0, 0), ("25.0", 0, 1),
                                                      ("26.0", 7, 7)]:
                with self.subTest(version=version, producer_exit=producer_exit):
                    tool.write_text("#!" + sys.executable + "\nimport sys\n"
                        + "sys.stdout.write(" + repr("cmd LC_BUILD_VERSION\nminos " + version + "\n"
                            + "fixture load command\n" * 100000) + ")\n"
                        + "sys.stdout.flush()\nsys.exit(" + str(producer_exit) + ")\n")
                    tool.chmod(0o700)
                    result = subprocess.run(["/bin/bash", "-c", "set -euo pipefail\n" + probe],
                        env={"PATH": str(root) + ":/usr/bin:/bin", "SOURCE_BINARY": "fixture"},
                        capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, expected, result.stderr[-2000:])

    def test_contract_has_standalone_authority(self):
        contract = json.loads((ROOT / "Resources/release-contract.json").read_bytes())
        self.assertEqual(contract["repository"], "KleinPerkins/shadow-sync")
        self.assertEqual(contract["bundle_identifier"], "com.kleinperkins.shadow-sync")
        self.assertEqual(contract["metadata_schema"], "shadow-sync-release/v2")
        self.assertEqual(contract["normal_update_authority"], "Sparkle")
        self.assertEqual(contract["lifecycle_authority"], "ShadowSyncLifecycleCoordinator")
        compiled = re.findall(r'public static let publisherTeamIdentifier = "([A-Z0-9]{10})"',
                              (ROOT / "Sources/ShadowSyncCore/ReleaseIdentity.swift").read_text())
        self.assertEqual(compiled, [contract["publisher_team_identifier"]])

    def test_build_refuses_unrelated_contract_before_output_creation(self):
        with tempfile.TemporaryDirectory(prefix="shadow-sync-contract-", dir="/private/tmp") as root:
            scratch, output = Path(root) / "scratch", Path(root) / "output"
            result = subprocess.run(["/bin/bash", str(ROOT / "scripts/build-app.sh"),
                "--scratch-path", str(scratch), "--output-dir", str(output),
                "--release-contract-sha256", "f" * 64], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"digest does not match standalone source", result.stderr)
            self.assertFalse(scratch.exists())
            self.assertFalse(output.exists())

    def test_old_source_installation_routes_refuse_before_home_access(self):
        with tempfile.TemporaryDirectory(prefix="shadow-sync-retired-installer-", dir="/private/tmp") as root:
            sentinel = Path(root) / "preserved"
            sentinel.write_bytes(b"fixture-preserved")
            before = hashlib.sha256(sentinel.read_bytes()).hexdigest()
            for arguments in [[], ["--apply"], ["--repair"], ["--uninstall"], ["--doctor"],
                              ["--source-identity"], ["--build-release-check"], ["--doctor", "--test-root"]]:
                result = subprocess.run(["/bin/bash", str(ROOT / "install.sh"), *arguments],
                    env={"PATH": "/usr/bin:/bin", "HOME": root}, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 64, arguments)
                self.assertIn(b"retired", result.stderr)
                self.assertEqual(sorted(os.listdir(root)), ["preserved"])
                self.assertEqual(hashlib.sha256(sentinel.read_bytes()).hexdigest(), before)


if __name__ == "__main__":
    unittest.main()
