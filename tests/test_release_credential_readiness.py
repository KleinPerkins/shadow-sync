import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/release-credential-readiness.py'
SPEC = importlib.util.spec_from_file_location('release_readiness', SOURCE)
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)


def context():
    return {'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
            'GITHUB_REPOSITORY': app.REPO, 'GITHUB_REPOSITORY_ID': app.REPO_ID,
            'GITHUB_REF': 'refs/heads/main', 'RUNNER_OS': 'macOS',
            'TRUSTED_WORKFLOW_SHA': 'a' * 40, 'GITHUB_SHA': 'a' * 40,
            'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1'}


def configuration():
    # Synthetic encoded fixtures are created at runtime; never use real keys.
    return {'APPLE_CERTIFICATE': base64.b64encode(b'fixture-certificate').decode(),
            'APPLE_CERTIFICATE_PASSWORD': 'fixture-cert-password',
            'APPLE_SIGNING_IDENTITY': 'Developer ID Application: Fixture Publisher (A123456789)',
            'APPLE_ID': 'fixture@example.invalid', 'APPLE_PASSWORD': 'fixture-apple-password',
            'APPLE_TEAM_ID': 'A123456789',
            'SPARKLE_PRIVATE_ED_KEY': base64.b64encode(bytes(range(32))).decode(),
            'SPARKLE_PUBLIC_ED_KEY': base64.b64encode(bytes(reversed(range(32)))).decode()}


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='shadow-sync-credential-fixture-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.root.chmod(0o700)
        self.public_hash = patch.object(app, 'PUBLIC_KEY_SHA256', hashlib.sha256(bytes(reversed(range(32)))).hexdigest())
        self.public_hash.start(); self.addCleanup(self.public_hash.stop)

    def test_trusted_exact_workflow_context(self):
        self.assertEqual(app.context(context()), 'a' * 40)
        for key, value in [('GITHUB_EVENT_NAME', 'pull_request_target'), ('GITHUB_EVENT_NAME', 'pull_request'),
                           ('GITHUB_ACTIONS', 'false'), ('GITHUB_REPOSITORY', 'fixture-owner/fork'),
                           ('GITHUB_REPOSITORY_ID', '1'), ('GITHUB_REF', 'refs/heads/topic'),
                           ('RUNNER_OS', 'Windows'), ('GITHUB_SHA', 'b' * 40), ('GITHUB_RUN_ID', '../x'),
                           ('GITHUB_RUN_ATTEMPT', '0')]:
            env = context(); env[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(app.Refusal):
                app.context(env)

    def test_main_refuses_untrusted_context_before_keychain_or_network(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(app, 'command') as command, patch.object(app.urllib.request, 'urlopen') as download, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(app.main(), 1)
        command.assert_not_called(); download.assert_not_called()

    def test_prepare_refuses_credentials_before_tool_execution(self):
        env = context(); env.update(configuration())
        with patch.object(app, 'command') as command, self.assertRaisesRegex(app.Refusal, 'credentials-present'):
            app.prepare(env)
        command.assert_not_called()

    def test_configuration_requires_each_value(self):
        for name in app.CONFIG:
            env = configuration(); del env[name]
            with self.subTest(name=name), self.assertRaisesRegex(app.Refusal, 'missing-release'):
                app.configuration(env)

    def test_configuration_accepts_only_expected_shapes(self):
        self.assertEqual(app.configuration(configuration()), b'fixture-certificate')
        for name, value in [('APPLE_TEAM_ID', 'short'), ('APPLE_SIGNING_IDENTITY', 'Apple Development: Fixture'),
                            ('APPLE_SIGNING_IDENTITY', 'Developer ID Application: Fixture (B123456789)'),
                            ('APPLE_CERTIFICATE', 'not base64'), ('APPLE_CERTIFICATE', ''),
                            ('SPARKLE_PRIVATE_ED_KEY', base64.b64encode(b'short').decode()),
                            ('SPARKLE_PUBLIC_ED_KEY', base64.b64encode(bytes(32)).decode()),
                            ('APPLE_PASSWORD', 'x' * 4097)]:
            env = configuration(); env[name] = value
            with self.subTest(name=name), self.assertRaises(app.Refusal):
                app.configuration(env)

    def test_child_environment_excludes_credentials_and_debug_controls(self):
        env = {**configuration(), 'PATH': '/fixture/bin', 'HOME': '/fixture/home',
               'DEVELOPER_DIR': '/fixture/xcode', 'PYTHONPATH': 'poisoned', 'DYLD_INSERT_LIBRARIES': 'poisoned', 'GH_DEBUG': 'api'}
        child = app.child_environment(env)
        self.assertEqual(child, {'PATH': '/fixture/bin', 'HOME': '/fixture/home', 'DEVELOPER_DIR': '/fixture/xcode'})

    def test_command_redacts_failure_and_timeout_and_reaps_process(self):
        with self.assertRaises(app.Refusal) as error:
            app.command('fixture-stage', sys.executable, '-c', 'import sys;print("fixture-sensitive");sys.exit(9)')
        self.assertEqual(str(error.exception), 'fixture-stage')
        real_popen = subprocess.Popen
        processes = []
        def record(*args, **kwargs):
            process = real_popen(*args, **kwargs); processes.append(process); return process
        with patch.object(app.subprocess, 'Popen', side_effect=record), self.assertRaisesRegex(app.Refusal, '^timeout-stage$'):
            app.command('timeout-stage', sys.executable, '-c', 'import time;time.sleep(30)', timeout=0.05)
        self.assertIsNotNone(processes[0].returncode)
        with self.assertRaises(ProcessLookupError): os.kill(processes[0].pid, 0)

    def test_termination_exception_kills_and_reaps_child(self):
        with patch.object(app.subprocess, 'Popen') as popen, patch.object(app.os, 'killpg') as kill:
            process = popen.return_value; process.pid = 12345
            process.communicate.side_effect = [app.Refusal('interrupted'), ('', '')]
            with self.assertRaisesRegex(app.Refusal, '^fixture-stage$'):
                app.command('fixture-stage', 'fixture')
            kill.assert_called_once_with(12345, app.signal.SIGKILL)
            self.assertEqual(process.communicate.call_count, 2)

    def test_missing_cleanup_journal_refuses_existing_credentials(self):
        app.cleanup(self.root)
        (self.root / 'certificate.p12').write_bytes(b'fixture')
        with self.assertRaisesRegex(app.Refusal, 'missing-cleanup-journal'):
            app.cleanup(self.root)

    def cleanup_fixture(self, fail_restore=False, fail_delete=False):
        app.write_json(self.root / 'keychain-cleanup.json', {'search_list': ['/fixture/original.keychain-db']})
        (self.root / 'readiness.keychain-db').write_bytes(b'fixture')
        (self.root / 'certificate.p12').write_bytes(b'fixture')
        calls = []
        def command(stage, *args, **kwargs):
            calls.append(stage)
            if stage == 'restore-keychain-search-list' and fail_restore: raise app.Refusal('restore')
            if stage == 'delete-temporary-keychain':
                if fail_delete: raise app.Refusal('delete')
                (self.root / 'readiness.keychain-db').unlink()
            return subprocess.CompletedProcess(args, 0, '"/fixture/original.keychain-db"\n', '')
        return calls, command

    def test_cleanup_restores_deletes_verifies_and_is_idempotent(self):
        calls, command = self.cleanup_fixture()
        with patch.object(app, 'command', side_effect=command):
            app.cleanup(self.root); app.cleanup(self.root)
        self.assertEqual(calls.count('delete-temporary-keychain'), 1)
        self.assertFalse((self.root / 'certificate.p12').exists())

    def test_restore_failure_still_deletes_credentials_but_refuses_qualification(self):
        calls, command = self.cleanup_fixture(fail_restore=True)
        with patch.object(app, 'command', side_effect=command), self.assertRaisesRegex(app.Refusal, 'temporary-credential-cleanup'):
            app.cleanup(self.root)
        self.assertIn('delete-temporary-keychain', calls)
        self.assertFalse((self.root / 'readiness.keychain-db').exists())
        self.assertFalse((self.root / 'certificate.p12').exists())

    def test_keychain_delete_failure_removes_p12_and_refuses(self):
        calls, command = self.cleanup_fixture(fail_delete=True)
        with patch.object(app, 'command', side_effect=command), self.assertRaises(app.Refusal):
            app.cleanup(self.root)
        self.assertFalse((self.root / 'certificate.p12').exists())
        self.assertTrue((self.root / 'readiness.keychain-db').exists())

    def test_mismatched_restored_search_list_refuses(self):
        _, command = self.cleanup_fixture()
        with patch.object(app, 'command', side_effect=command), patch.object(app, 'search_list', return_value=[]), self.assertRaises(app.Refusal):
            app.cleanup(self.root)

    def test_import_failure_runs_journal_bound_cleanup(self):
        calls = []
        def command(stage, *args, **kwargs):
            calls.append(stage)
            if stage == 'create-keychain': (self.root / 'readiness.keychain-db').write_bytes(b'fixture')
            if stage == 'import-certificate': raise app.Refusal('import-certificate')
            if stage == 'delete-temporary-keychain': (self.root / 'readiness.keychain-db').unlink()
            return subprocess.CompletedProcess(args, 0, '"/fixture/original.keychain-db"\n', '')
        with patch.object(app, 'command', side_effect=command), self.assertRaisesRegex(app.Refusal, 'import-certificate'):
            with app.signing_keychain(self.root, b'fixture', configuration()):
                self.fail('must not yield after failed import')
        self.assertIn('restore-keychain-search-list', calls)
        self.assertIn('delete-temporary-keychain', calls)
        self.assertFalse((self.root / 'certificate.p12').exists())

    def test_cleanup_refuses_symlink_work_or_journal(self):
        link = self.root / 'link'; link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(app.Refusal): app.cleanup(link)
        (self.root / 'keychain-cleanup.json').symlink_to(self.root / 'absent')
        # A dangling journal cannot hide a credential artifact.
        (self.root / 'certificate.p12').write_bytes(b'fixture')
        with self.assertRaises(app.Refusal): app.cleanup(self.root)

    def prepared(self):
        env = {**context(), **configuration(), 'RUNNER_TEMP': str(self.root)}
        work = app.work_directory(env); work.mkdir(mode=0o700)
        for name in ('sign_update', 'probe', 'verify-update'): (work / name).write_bytes(name.encode())
        hashes = {name: hashlib.sha256((work / name).read_bytes()).hexdigest() for name in ('sign_update', 'probe', 'verify-update')}
        app.write_json(work / 'prepared.json', {'revision': 'a' * 40, 'files': hashes,
                       'os_version': '26.6.2', 'xcode': 'Xcode 26.6\nBuild version 17F113',
                       'swift': 'fixture-swift', 'sdk': '26.5', 'runner_image': 'fixture-image'})
        return env, work, hashes

    def test_prepared_tool_tampering_refuses_before_secret_use(self):
        env, work, _ = self.prepared(); (work / 'probe').write_bytes(b'tampered')
        with patch.object(app, 'configuration') as cfg, self.assertRaisesRegex(app.Refusal, 'prepared-tool-integrity'):
            app.qualify(env)
        cfg.assert_not_called()

    def test_qualification_receipt_is_nonsecret_and_has_separate_product_gates(self):
        env, work, hashes = self.prepared(); calls = []
        @contextlib.contextmanager
        def keychain(*args): yield work / 'fixture.keychain-db'
        def command(stage, *args, **kwargs):
            calls.append((stage, args, kwargs))
            stdout, stderr, code = '', '', 0
            if stage == 'certificate-trust': stdout = '"' + env['APPLE_SIGNING_IDENTITY'] + '"'
            if stage == 'inspect-code-signature': stderr = 'TeamIdentifier=' + env['APPLE_TEAM_ID'] + '\nAuthority=' + env['APPLE_SIGNING_IDENTITY'] + '\nTimestamp=fixture\nflags=0x10000(runtime)\n'
            if stage == 'sparkle-signature': stdout = 'fixture-signature'
            if stage == 'tamper-rejection': code = 1
            return subprocess.CompletedProcess(args, code, stdout, stderr)
        with patch.object(app, 'ROOT', self.root), patch.object(app, 'SIGNER_SHA256', hashes['sign_update']), patch.object(app, 'signing_keychain', keychain), patch.object(app, 'command', side_effect=command), patch.object(app, 'cleanup') as clean:
            app.qualify(env)
        raw = (self.root / 'outputs/release-credential-readiness.json').read_text(); result = json.loads(raw)
        for key in app.CONFIG: self.assertNotIn(env[key], raw)
        self.assertTrue(result['temporary_credentials_removed']); clean.assert_called_once_with(work)
        for key in ('product_notarized', 'release_published', 'installed_update_verified'): self.assertFalse(result[key])
        signing = next(x for x in calls if x[0] == 'sparkle-signature')
        self.assertEqual(signing[2]['input'], env['SPARKLE_PRIVATE_ED_KEY'] + '\n')
        self.assertNotIn(env['SPARKLE_PRIVATE_ED_KEY'], signing[1])
        self.assertFalse(any('submit' in args or '--sync' in args for _, args, _ in calls))

    def test_unexpected_exception_is_redacted(self):
        err = io.StringIO()
        with patch.dict(os.environ, context(), clear=True), patch.object(sys, 'argv', ['readiness', 'prepare']), patch.object(app, 'prepare', side_effect=RuntimeError('fixture-confidential')), contextlib.redirect_stderr(err):
            self.assertEqual(app.main(), 1)
        self.assertNotIn('fixture-confidential', err.getvalue())


if __name__ == '__main__':
    unittest.main()
