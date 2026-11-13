#!/usr/bin/env python3
"""Discover and execute actual unittest cases with strict completion reports.

Discovery alone is not test execution. Each module is a whole shardable suite;
only unittest's successful completion callback emits its canonical PASS ID.
"""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import unittest

MODULE = re.compile(r'test_[a-z0-9_]+')
CASE = re.compile(r'[A-Za-z0-9_.]{1,160}')
DIAGNOSTIC_OPERATIONS = frozenset({
    'fixture-install', 'fixture-direct', 'live-home-refusal', 'live-launchctl-refusal',
})
DIAGNOSTIC_PHASES = frozenset({'run', 'returncode', 'output'})


def failure_diagnostic(test, err):
    # Never stringify an exception, its arguments, traceback, output or command.
    error = err[1]
    cause = ('timeout' if isinstance(error, subprocess.TimeoutExpired) else
             'assertion' if isinstance(error, AssertionError) else
             'os-error' if isinstance(error, OSError) else 'other')
    detail = getattr(error, 'shadow_sync_diagnostic', None)
    detail = detail if type(detail) is dict else {}
    operation = detail.get('operation')
    phase = detail.get('phase')
    exit_code = detail.get('exit_code')
    identifier = test.id()
    return {'schema': 'shadow-sync-python-failure/v1',
            'case': identifier if type(identifier) is str and CASE.fullmatch(identifier) else 'unavailable',
            'cause': cause,
            'operation': operation if type(operation) is str and operation in DIAGNOSTIC_OPERATIONS else 'unspecified',
            'phase': phase if type(phase) is str and phase in DIAGNOSTIC_PHASES else 'unspecified',
            'exit_code': exit_code if type(exit_code) is int and -255 <= exit_code <= 255 else None}


def discover(directory):
    directory = Path(directory).absolute()
    # Opening every component prevents a regular leaf reached through a linked
    # ancestor from being accepted as the requested source directory.
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(directory.anchor, flags)
    try:
        for component in directory.parts[1:]:
            if component in ('.', '..'):
                raise ValueError('test directory contains a traversal')
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
    finally:
        os.close(descriptor)
    files = sorted(directory.rglob('test_*.py'))
    if not files or any(p.is_symlink() or not p.is_file() or p.parent != directory
                        or MODULE.fullmatch(p.stem) is None for p in files):
        raise ValueError('test modules require flat, regular, canonical paths')
    if any(not stat.S_ISREG(p.lstat().st_mode) or p.lstat().st_nlink != 1 for p in files):
        raise ValueError('test modules must be single-link regular files')
    loader = unittest.TestLoader()
    suite = loader.discover(str(directory), pattern='test_*.py')
    if loader.errors:
        raise ValueError('test discovery failed')
    if any(hasattr(sys.modules.get(p.stem), 'load_tests') for p in files):
        raise ValueError('custom load_tests may not hide mandatory case discovery')
    cases = []

    def flatten(node):
        if isinstance(node, unittest.TestSuite):
            for child in node:
                flatten(child)
        elif isinstance(node, unittest.TestCase):
            cases.append(node)
        else:
            raise ValueError('unrecognized unittest node')
    flatten(suite)
    identifiers = [case.id() for case in cases]
    if not identifiers or len(identifiers) != len(set(identifiers)) \
            or any(CASE.fullmatch(name) is None for name in identifiers):
        raise ValueError('test case inventory is empty, duplicate or invalid')
    modules = {}
    for case in cases:
        module = case.__class__.__module__
        if MODULE.fullmatch(module) is None or not case.id().startswith(module + '.'):
            raise ValueError('test case is not owned by its module')
        modules.setdefault(module, []).append(case)
    if set(modules) != {p.stem for p in files}:
        raise ValueError('each test module must register executable cases')
    return {name: modules[name] for name in sorted(modules)}


class CompletionResult(unittest.TestResult):
    def __init__(self, emit):
        super().__init__()
        self.emit = emit
        self.started = []
        self.stopped = []
        self.passed = []
        self.rejected = []

    def startTest(self, test):
        super().startTest(test)
        self.started.append(test.id())

    def stopTest(self, test):
        self.stopped.append(test.id())
        super().stopTest(test)

    def addSuccess(self, test):
        super().addSuccess(test)
        self.passed.append(test.id())
        self.emit('PASS ' + test.id())

    def reject(self, test, status='FAIL', err=None):
        self.rejected.append(test.id())
        self.emit(status + ' ' + test.id())
        if err is not None:
            self.emit('DIAGNOSTIC ' + json.dumps(failure_diagnostic(test, err),
                                                sort_keys=True, separators=(',', ':')))

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.reject(test, err=err)

    def addError(self, test, err):
        super().addError(test, err)
        self.reject(test, err=err)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.reject(test, 'SKIP')

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.reject(test, err=err)

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.reject(test)

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            self.reject(test, err=err)

    def complete(self, expected):
        return bool(expected) and not self.rejected and self.wasSuccessful() \
            and self.started == expected and self.stopped == expected \
            and self.passed == expected and self.testsRun == len(expected)


def execute(modules, selected, emit):
    if not selected or len(selected) != len(set(selected)) or not set(selected) <= set(modules):
        raise ValueError('selected suites are empty, duplicate or unknown')
    cases = [case for name in selected for case in modules[name]]
    expected = [case.id() for case in cases]
    result = CompletionResult(emit)
    # unittest continues independent cases after failures; no successful retry is
    # substituted for a failed case, skip, expected failure or class setup error.
    unittest.TestSuite(cases).run(result)
    return result.complete(expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test-directory', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'Tests/Tooling')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--list', action='store_true')
    mode.add_argument('--suite')
    mode.add_argument('--all', action='store_true')
    args = parser.parse_args()
    try:
        modules = discover(args.test_directory)
        if args.list:
            print(json.dumps({'schema': 'shadow-sync-python-suite-discovery/v1',
                              'suites': [{'id': name, 'cases': [test.id() for test in tests]}
                                         for name, tests in modules.items()]},
                             sort_keys=True, separators=(',', ':')))
            return 0
        selected = list(modules) if args.all else [args.suite]
        return 0 if execute(modules, selected, lambda value: print(value, flush=True)) else 1
    except (ValueError, OSError, ImportError, UnicodeError):
        sys.stderr.write('Python suite discovery or completion failed.\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
