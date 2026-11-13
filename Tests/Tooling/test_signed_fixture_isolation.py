"""Pure profile controls; no Seatbelt, executable, network or host file probes."""
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('signed_fixture_isolation', ROOT / 'scripts/signed-fixture-isolation.py')
isolation = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(isolation)


def read_filters(profile, action):
    """Inspect the renderer's closed rule syntax, not Seatbelt precedence."""
    filters = []
    for line in profile.splitlines():
        if not line.startswith('(' + action + ' file-read*'):
            continue
        match = re.fullmatch(r'\(' + action + r' file-read\* file-write\* \(subpath ("(?:[^"\\]|\\.)*")\)\)', line)
        if match is None:
            raise AssertionError('unexpected file-read rule: ' + line)
        filters.append(json.loads(match[1]))
    return filters


def covered(path, roots):
    return any(path == root or path.startswith(root + '/') for root in roots)


def require_foreign_read_fence(profile, path):
    # Default reads are allowed. Every foreign sample must have an explicit
    # denying ancestor and no file-read exception covering it. This deliberately
    # makes no claim about native alias resolution or kernel rule enforcement.
    if not covered(path, read_filters(profile, 'deny')):
        raise AssertionError('foreign read missing deny')
    if covered(path, read_filters(profile, 'allow')):
        raise AssertionError('foreign read has exception')


class SignedFixtureIsolationTests(unittest.TestCase):
    nonce = 'a' * 32
    root = '/private/tmp/shadow-sync-ic.' + nonce + '.A1b2C3'

    def test_only_two_fixed_executables_and_two_fixed_sockets(self):
        value = isolation.render(self.root, self.nonce, '/Users/fixture-account')
        executable_lines = [line for line in value.splitlines() if line.startswith('(allow process-exec')]
        self.assertEqual(executable_lines, [
            '(allow process-exec (literal "' + self.root + '/candidate/ShadowSync.app/Contents/Helpers/ShadowSyncLifecycleCoordinator"))',
            '(allow process-exec (literal "' + self.root + '/home/Applications/ShadowSync.app/Contents/MacOS/ShadowSync"))'])
        self.assertEqual(sum(line.startswith('(allow network-') for line in value.splitlines()), 2)
        self.assertIn('(deny network*)', value)
        self.assertIn('(deny process-exec)', value)
        for tool in ('/bin/sh', '/bin/bash', '/bin/launchctl', '/usr/bin/git', '/usr/bin/codesign', '/usr/bin/python3'):
            self.assertNotIn(tool, value)

    def test_real_home_and_foreign_temporary_roots_are_denied(self):
        value = isolation.render(self.root, self.nonce, '/Users/fixture-account')
        for path in ('/Users/fixture-account/private', '/Users/fixture-other/private',
                     '/private/tmp/foreign-case/payload', '/tmp/foreign-case/payload',
                     '/private/var/tmp/foreign-case/payload', '/var/tmp/foreign-case/payload',
                     '/private/var/folders/ab/fixture-other/T/foreign-case/payload',
                     '/private/var/folders/ab/fixture-other/C/cache-payload',
                     '/var/folders/ab/fixture-other/T/foreign-case/payload',
                     self.root + '-foreign/payload'):
            with self.subTest(path=path):
                require_foreign_read_fence(value, path)
        self.assertEqual(read_filters(value, 'allow'), [self.root])
        self.assertTrue(covered(self.root + '/tmp/payload', read_filters(value, 'allow')))
        self.assertNotIn('(regex', value)

    def test_var_folders_rule_removal_and_broad_exception_are_detected(self):
        value = isolation.render(self.root, self.nonce, '/Users/fixture-account')
        for namespace in ('/private/var/folders', '/var/folders'):
            path = namespace + '/ab/fixture-other/T/foreign-case/payload'
            rule = '(deny file-read* file-write* (subpath "' + namespace + '"))\n'
            self.assertEqual(value.count(rule), 1)
            with self.subTest(namespace=namespace, mutation='remove'):
                with self.assertRaisesRegex(AssertionError, 'foreign read missing deny'):
                    require_foreign_read_fence(value.replace(rule, ''), path)
            with self.subTest(namespace=namespace, mutation='broad-exception'):
                with self.assertRaisesRegex(AssertionError, 'foreign read has exception'):
                    require_foreign_read_fence(value + '(allow file-read* file-write* (subpath "'
                                               + namespace + '"))\n', path)

    def test_escaping_root_or_nonce_cannot_expand_profile(self):
        for root, nonce in [(self.root + '/..', self.nonce), ('/private/tmp/foreign', self.nonce),
                             (self.root, 'b' * 32), (self.root + '") (allow process-exec)', self.nonce)]:
            with self.assertRaises(ValueError):
                isolation.render(root, nonce, '/Users/fixture-account')
        with self.assertRaises(ValueError):
            isolation.render(self.root, self.nonce, '/')


if __name__ == '__main__':
    unittest.main()
