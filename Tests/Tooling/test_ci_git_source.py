"""Disposable Git repositories prove revision-to-checkout evidence binding."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('git_source_shards', ROOT / 'scripts/ci-shards.py')
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class GitSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-ci-git-source-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.root.mkdir()
        self.home = Path(self.temp.name) / 'home'
        self.home.mkdir()
        self.template = Path(self.temp.name) / 'empty-template'
        self.template.mkdir()
        self.environment = {'PATH': os.defpath, 'HOME': str(self.home),
                            'LANG': 'C', 'LC_ALL': 'C', 'GIT_CONFIG_NOSYSTEM': '1',
                            'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null',
                            'GIT_AUTHOR_NAME': 'Fixture', 'GIT_COMMITTER_NAME': 'Fixture',
                            'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                            'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}
        self.git('init', '-q', '-b', 'main', '--object-format=sha1',
                 '--template=' + str(self.template))
        (self.root / 'input.txt').write_bytes(b'original\n')
        (self.root / 'empty').touch()
        self.git('add', 'input.txt', 'empty')
        self.git('commit', '-q', '-m', 'fixture')
        self.revision = self.git('rev-parse', 'HEAD').decode().strip()

    def git(self, *args, input=None):
        return subprocess.run(['/usr/bin/git', '-C', str(self.root), *args],
                              env=self.environment, input=input, check=True,
                              capture_output=True, timeout=15).stdout

    def refuses(self):
        with self.assertRaises((ci.InvalidEvidence, OSError, subprocess.SubprocessError)):
            ci.git_source_digest(self.root, self.revision)

    def test_exact_clean_revision_with_empty_file_passes(self):
        self.assertEqual(ci.git_source_digest(self.root, self.revision),
                         ci.source_digest(self.root, ['input.txt', 'empty']))

    def test_working_bytes_cannot_claim_unchanged_revision(self):
        (self.root / 'input.txt').write_bytes(b'modified\n')
        self.refuses()

    def test_assume_unchanged_and_restored_mtime_do_not_hide_changed_bytes(self):
        path = self.root / 'input.txt'
        info = path.stat()
        self.git('update-index', '--assume-unchanged', 'input.txt')
        path.write_bytes(b'modified\n')
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
        self.assertEqual(self.git('diff', '--name-only'), b'')
        self.refuses()

    def test_staged_bytes_and_new_membership_refuse(self):
        (self.root / 'input.txt').write_bytes(b'staged\n')
        self.git('add', 'input.txt')
        self.refuses()
        self.git('reset', '-q', 'HEAD', '--', 'input.txt')
        (self.root / 'input.txt').write_bytes(b'original\n')
        (self.root / 'added').write_bytes(b'new')
        self.git('add', 'added')
        self.refuses()

    def test_untracked_build_output_does_not_become_source(self):
        expected = ci.git_source_digest(self.root, self.revision)
        (self.root / 'build-output').mkdir()
        (self.root / 'build-output' / 'untracked').write_bytes(b'generated')
        self.assertEqual(ci.git_source_digest(self.root, self.revision), expected)

    def test_executable_mode_and_missing_source_refuse(self):
        path = self.root / 'input.txt'
        path.chmod(0o755)
        self.refuses()
        path.chmod(0o644)
        path.unlink()
        self.refuses()

    def test_git_symlink_and_submodule_entries_refuse(self):
        (self.root / 'link').symlink_to('input.txt')
        self.git('add', 'link')
        self.git('commit', '-q', '-m', 'link fixture')
        self.revision = self.git('rev-parse', 'HEAD').decode().strip()
        self.refuses()
        self.git('rm', '-q', 'link')
        self.git('commit', '-q', '-m', 'remove fixture link')
        self.revision = self.git('rev-parse', 'HEAD').decode().strip()
        self.git('update-index', '--add', '--cacheinfo', '160000,' + self.revision + ',module')
        self.git('commit', '-q', '-m', 'gitlink fixture')
        self.revision = self.git('rev-parse', 'HEAD').decode().strip()
        self.refuses()

    def test_control_characters_in_tracked_paths_refuse(self):
        (self.root / 'unsafe\nname').write_bytes(b'fixture')
        self.git('add', 'unsafe\nname')
        self.git('commit', '-q', '-m', 'path fixture')
        self.revision = self.git('rev-parse', 'HEAD').decode().strip()
        self.refuses()

    def test_inherited_git_redirects_cannot_change_source_authority(self):
        expected = ci.git_source_digest(self.root, self.revision)
        with mock.patch.dict(os.environ, {'GIT_DIR': '/nonexistent/fixture',
                                        'GIT_WORK_TREE': '/nonexistent/fixture',
                                        'GIT_INDEX_FILE': '/nonexistent/fixture',
                                        'GIT_CONFIG_COUNT': '1',
                                        'GIT_CONFIG_KEY_0': 'core.worktree',
                                        'GIT_CONFIG_VALUE_0': '/nonexistent/fixture'}):
            self.assertEqual(ci.git_source_digest(self.root, self.revision), expected)

    def test_head_change_during_hashing_refuses(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'second fixture')
        other = self.git('rev-parse', 'HEAD').decode().strip()
        self.git('update-ref', 'refs/heads/main', self.revision)
        original = ci.source_digest
        def move_head(*args, **kwargs):
            result = original(*args, **kwargs)
            self.git('update-ref', 'refs/heads/main', other)
            return result
        with mock.patch.object(ci, 'source_digest', side_effect=move_head):
            self.refuses()

    def test_index_change_during_hashing_refuses(self):
        original = ci.source_digest
        def change_index(*args, **kwargs):
            result = original(*args, **kwargs)
            self.git('update-index', '--force-remove', 'empty')
            return result
        with mock.patch.object(ci, 'source_digest', side_effect=change_index):
            self.refuses()

    def test_replacement_objects_cannot_substitute_for_reviewed_tree(self):
        old = self.revision
        (self.root / 'input.txt').write_bytes(b'replacement\n')
        self.git('add', 'input.txt')
        self.git('commit', '-q', '-m', 'replacement fixture')
        other = self.git('rev-parse', 'HEAD').decode().strip()
        self.git('replace', old, other)
        self.git('update-ref', 'refs/heads/main', old)
        self.refuses()


if __name__ == '__main__':
    unittest.main()
