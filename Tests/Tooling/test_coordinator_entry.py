import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('coordinator_entry', ROOT / 'scripts/verify-coordinator-entry.py')
entry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(entry)


class CoordinatorEntryTests(unittest.TestCase):
    def test_parent_escape_refuses_before_executing_any_binary(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-coordinator-path-', dir='/private/tmp') as temp:
            parent = Path(temp); root = parent / 'fixture'; root.mkdir(mode=0o700)
            outside = parent / 'outside'; outside.mkdir(mode=0o700)
            binary = outside / 'coordinator'; binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
            for candidate in (root / '../outside/coordinator', binary):
                with self.subTest(path=str(candidate)), patch.object(entry.subprocess, 'run') as execute:
                    with self.assertRaises(ValueError): entry.verify(root, candidate, root / 'ShadowSync.app')
                    execute.assert_not_called()

    def test_owned_contained_executable_accepts_and_alias_refuses(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-coordinator-path-', dir='/private/tmp') as temp:
            root = Path(temp); binary = root / 'coordinator'
            binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
            entry.contained(root, binary)
            alias = root / 'alias'; alias.symlink_to(binary)
            with self.assertRaises(ValueError): entry.contained(root, alias)
