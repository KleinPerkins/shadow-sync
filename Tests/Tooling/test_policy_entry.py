"""The sealed entry receives trusted bytes and derives identity from the account API."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_policy_adapter import adapter


class PolicyEntryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="shadow-sync-entry-")
        self.scratch = str(Path(self.temporary.name).resolve())
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(self.stack.close)
        self.output, self.errors = io.StringIO(), io.StringIO()
        self.input = SimpleNamespace(buffer=io.BytesIO(b'{"schema":"fixture"}'))
        self.system = SimpleNamespace(platform="darwin", flags=SimpleNamespace(isolated=1, no_site=1, dont_write_bytecode=1),
                                      stdin=self.input, stdout=self.output, stderr=self.errors,
                                      argv=["-c"])
        self.stack.enter_context(patch.object(adapter, "sys", self.system))
        self.stack.enter_context(contextlib.redirect_stdout(self.output))
        self.stack.enter_context(patch.object(adapter.os, "geteuid", return_value=503))
        self.stack.enter_context(patch.object(adapter.os, "getuid", return_value=503))
        self.account = self.stack.enter_context(patch.object(
            adapter.pwd, "getpwuid", return_value=SimpleNamespace(pw_dir="/account-derived-home")))
        self.scratch_api = self.stack.enter_context(patch.object(
            adapter.os, "confstr", return_value=self.scratch))

    def test_sealed_contract_is_used_without_reopening_bundle_resources(self):
        contract = b'{"schema":"signed-contract-fixture"}'
        with patch.dict(os.environ, {"HOME": "/untrusted-home"}), \
                patch.object(adapter, "read_owned_absolute") as read, \
                patch.object(adapter, "dispatch", return_value={"ok": True}) as dispatch:
            self.assertEqual(adapter.run_sealed(contract), 0)
        read.assert_not_called()
        dispatch.assert_called_once_with(b'{"schema":"fixture"}', contract,
                                         home="/account-derived-home", uid=503,
                                         temporary_parent=self.scratch)
        self.account.assert_called_once_with(503)
        self.scratch_api.assert_called_once_with("CS_DARWIN_USER_TEMP_DIR")
        self.assertEqual(json.loads(self.output.getvalue()), {"ok": True})
        self.assertEqual(self.errors.getvalue(), "")

    def test_bad_contract_or_isolation_refuses_before_identity_or_dispatch(self):
        cases = [("darwin", 1, 1, 1, value) for value in (b"", b"x" * 16385, "text", bytearray(b"x"))]
        cases += [("linux", 1, 1, 1, b"x"), ("darwin", 0, 1, 1, b"x"),
                  ("darwin", 1, 0, 1, b"x"), ("darwin", 1, 1, 0, b"x")]
        with patch.object(adapter, "dispatch") as dispatch:
            for platform, isolated, no_site, no_bytecode, contract in cases:
                self.system.platform = platform
                self.system.flags = SimpleNamespace(isolated=isolated, no_site=no_site,
                                                    dont_write_bytecode=no_bytecode)
                self.assertEqual(adapter.run_sealed(contract), 2)
        self.account.assert_not_called()
        self.scratch_api.assert_not_called()
        dispatch.assert_not_called()
        self.assertEqual(self.output.getvalue(), "")

    def test_root_and_mismatched_account_refuse_before_scratch_or_request(self):
        for effective, real in [(0, 0), (503, 504)]:
            with patch.object(adapter.os, "geteuid", return_value=effective), \
                    patch.object(adapter.os, "getuid", return_value=real), \
                    patch.object(adapter, "dispatch") as dispatch:
                self.assertEqual(adapter.run_sealed(b"contract"), 2)
            dispatch.assert_not_called()
        self.account.assert_not_called()
        self.scratch_api.assert_not_called()
        self.assertEqual(self.input.buffer.tell(), 0)

    def test_missing_scratch_and_malformed_input_are_closed_without_private_diagnostics(self):
        with patch.object(adapter.os, "confstr", return_value=None), \
                patch.object(adapter, "dispatch") as dispatch:
            self.assertEqual(adapter.run_sealed(b"contract"), 2)
        dispatch.assert_not_called()
        self.assertEqual(self.input.buffer.tell(), 0)
        self.input.buffer = io.BytesIO(b'{"private-candidate":"/must-not-be-logged"}')
        self.assertEqual(adapter.run_sealed(b"contract"), 2)
        self.assertEqual(self.output.getvalue(), "")
        self.assertEqual(self.errors.getvalue(), "Policy classification unavailable.\n" * 2)

    def test_input_read_is_bounded_and_does_not_accept_an_oversize_request(self):
        self.input.buffer = io.BytesIO(b"x" * (adapter.MAX_BATCH_REQUEST + 100))
        self.assertEqual(adapter.run_sealed(b"contract"), 2)
        self.assertEqual(self.input.buffer.tell(), adapter.MAX_BATCH_REQUEST + 1)
        self.assertEqual(self.output.getvalue(), "")
        self.assertEqual(self.errors.getvalue(), "Policy classification unavailable.\n")

    def test_child_errors_and_system_exit_have_one_closed_diagnostic(self):
        for error in [ValueError("private input"), SystemExit("private input")]:
            with patch.object(adapter, "dispatch", side_effect=error):
                self.assertEqual(adapter.run_sealed(b"contract"), 2)
        self.assertEqual(self.output.getvalue(), "")
        self.assertEqual(self.errors.getvalue(), "Policy classification unavailable.\n" * 2)


if __name__ == "__main__":
    unittest.main()
