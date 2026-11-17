#!/usr/bin/env python3
"""Execute one recomputed CI unit; retain failures and require explicit cleanup.

This is the execution half of ci-shards.py. Commands are the registered direct
argv, never shell text. A suite publishes completion only after its own fixture
owners drain; process exit alone does not assert cleanup. Cancellation asks the
original command to stop and retains it until exit, never kills a guardian.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import uuid

_spec = importlib.util.spec_from_file_location('ci_shards', Path(__file__).with_name('ci-shards.py'))
ci = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ci)
require = ci.require


def write_new(path, value):
    with Path(path).open('xb') as stream:
        stream.write(ci.encode(value) + b'\n')
        stream.flush()
        os.fsync(stream.fileno())


def command_completed(cleanup_complete, *, environment=None):
    """Called by a canonical suite entrypoint after actual cleanup, even on failure."""
    env = os.environ if environment is None else environment
    require(type(cleanup_complete) is bool)
    context = ci.coverage.closed(ci.coverage.decode(env['SHADOW_SYNC_CI_CONTEXT']),
        ('nonce', 'suite', 'unit_id', 'plan_sha256', 'source_sha256', 'revision', 'run_id', 'run_attempt'))
    require(type(context['nonce']) is str and len(context['nonce']) == 32)
    write_new(Path(env['SHADOW_SYNC_CI_COMPLETION']), {
        'schema': 'shadow-sync-ci-command-completion/v1', **context,
        'cleanup_complete': cleanup_complete})


def observe_command(argv, *, cwd, environment, log, timeout_seconds):
    """Bound output, request cooperative cancellation, and reap the original child.

    There is deliberately no kill-after-timeout branch. Runtime commands own the
    guardian control channel and drain it on TERM. A stuck cleanup cannot produce
    a complete unit; the hosted job's separate deadline fails that execution.
    """
    started = time.monotonic()
    interrupts, errors = [], []
    previous = {}
    process = None
    requested = False
    count = 0
    retained = 0
    eof = False
    exit_code = None
    def interrupted(number, _frame):
        interrupts.append(number)
    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.signal(number, interrupted)
        with Path(log).open('xb') as output:
            process = subprocess.Popen(argv, cwd=cwd, env=environment,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, close_fds=True, start_new_session=True)
            os.set_blocking(process.stdout.fileno(), False)
            while exit_code is None or not eof:
                if time.monotonic() - started >= timeout_seconds and 'deadline' not in errors:
                    errors.append('deadline')
                if (interrupts or errors) and not requested:
                    # Popen retains the unreaped original child; never use a PID
                    # supplied by a receipt or signal its independently owned groups.
                    process.send_signal(signal.SIGTERM)
                    requested = True
                ready, _, _ = select.select([] if eof else [process.stdout], [], [], .02)
                if ready:
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        eof = True
                    else:
                        count += len(chunk)
                        remaining = max(0, ci.coverage.MAX_LOG - retained)
                        output.write(chunk[:remaining])
                        retained += min(len(chunk), remaining)
                        if count > ci.coverage.MAX_LOG and 'output-limit' not in errors:
                            errors.append('output-limit')
                exit_code = process.poll()
            output.flush()
            os.fsync(output.fileno())
    finally:
        # The normal observation loop owns cancellation and actual reaping. An
        # observer I/O failure must not discard that ownership or assert cleanup.
        if process is not None and process.returncode is None:
            process.send_signal(signal.SIGTERM)
            while process.poll() is None:
                if process.stdout is not None:
                    ready, _, _ = select.select([process.stdout], [], [], .02)
                    if ready:
                        os.read(process.stdout.fileno(), 65536)
                else:
                    time.sleep(.02)
        if process is not None and process.stdout is not None:
            process.stdout.close()
        for number, handler in previous.items():
            signal.signal(number, handler)
    return {'exit_code': exit_code, 'errors': errors, 'interrupts': interrupts,
            'original_reaped': process is not None and process.returncode is not None,
            'seconds': round(time.monotonic() - started, 6)}


def case_report(data):
    lines = data.decode('utf-8', errors='strict').splitlines()
    result = {}
    for prefix, key in (('PASS ', 'passed_cases'), ('FAIL ', 'failed_cases'), ('SKIP ', 'skipped_cases')):
        result[key] = [ci.coverage.TIMING_SUFFIX.sub('', line[len(prefix):])
                       for line in lines if line.startswith(prefix)]
    return result


def execute_unit(root, head, base, plan_bytes, unit_id, artifacts, diagnostics, *, identity,
                 environment=None, observe=observe_command, source=ci.git_source_digest):
    require(source(root, identity['revision']) == identity['source_sha256'])
    plan = ci.make_plan(head, base, **identity)
    require(ci.coverage.decode(plan_bytes) == plan)
    units = [unit for unit in plan['units'] if unit['id'] == unit_id]
    require(len(units) == 1)
    unit = units[0]
    contract = ci.registration(head)
    directory, detail = Path(artifacts) / unit_id, Path(diagnostics) / unit_id
    directory.mkdir(mode=0o700)
    detail.mkdir(mode=0o700)
    started = time.monotonic()
    errors = []
    completed = []
    for name in unit['suites']:
        expected = contract['coverage']['suites'][name]
        command = contract['commands'][name]
        command_dir = detail / name
        command_dir.mkdir(mode=0o700)
        completion = command_dir / 'completion.json'
        context = {'nonce': uuid.uuid4().hex, 'suite': name, 'unit_id': unit_id,
                   'plan_sha256': ci.digest(ci.encode(plan)), **identity}
        env = dict(os.environ if environment is None else environment)
        env.update(SHADOW_SYNC_CI_CONTEXT=ci.encode(context).decode('ascii'),
                   SHADOW_SYNC_CI_COMPLETION=str(completion),
                   SHADOW_SYNC_CI_EVIDENCE=str(command_dir),
                   SHADOW_SYNC_CI_WORK=str(detail / 'build'),
                   PYTHONDONTWRITEBYTECODE='1')
        result = None
        cleanup = False
        observed = dict(passed_cases=[], failed_cases=[], skipped_cases=[])
        log_path = directory / (name + '.log')
        try:
            result = observe(command['argv'], cwd=root, environment=env,
                             log=log_path, timeout_seconds=command['timeout_seconds'])
            data = ci.coverage.read_regular(log_path, ci.coverage.MAX_LOG)
            observed = case_report(data)
            terminal = ci.coverage.decode(ci.coverage.read_regular(completion))
            require(type(terminal) is dict and terminal.get('cleanup_complete') is True)
            require(terminal == {'schema': 'shadow-sync-ci-command-completion/v1',
                                **context, 'cleanup_complete': True})
            cleanup = True
            require(result['exit_code'] == 0 and result['original_reaped'] is True
                    and not result['errors'] and not result['interrupts'])
            require(set(ci.coverage.unique_ids(observed['passed_cases'])) == set(expected['cases'])
                    and not observed['failed_cases'] and not observed['skipped_cases'])
            completed.append(name)
        except (ci.InvalidEvidence, OSError, ValueError, UnicodeError, subprocess.SubprocessError) as error:
            errors.append({'suite': name, 'error': type(error).__name__})
        if not log_path.exists():
            log_path.write_bytes(b'Command did not start.\n')
        data = log_path.read_bytes()
        receipt = {'schema': 'shadow-sync-ci-sharded-suite-result/v1', 'suite': name,
            'kind': expected['kind'], **identity, 'unit_id': unit_id,
            'plan_sha256': ci.digest(ci.encode(plan)),
            'manifest_sha256': ci.digest(ci.encode(contract['coverage'])),
            'status': 'complete' if name in completed else 'failed',
            'exit_code': None if result is None else result['exit_code'],
            'expected_cases': expected['cases'], **observed, 'cleanup_complete': cleanup,
            'command_sha256': ci.digest(ci.encode(command)), 'log_sha256': ci.digest(data)}
        write_new(directory / (name + '.json'), receipt)
        write_new(command_dir / 'observer.json', result)
        if not cleanup or result is None or result['interrupts']:
            break  # No next suite may inherit unresolved fixture ownership.
    try:
        require(source(root, identity['revision']) == identity['source_sha256'])
    except (ci.InvalidEvidence, OSError, ValueError, subprocess.SubprocessError):
        errors.append({'error': 'source-binding-changed'})
    passed = not errors and completed == unit['suites']
    receipt = {'schema': 'shadow-sync-ci-shard-result/v1',
        'plan_sha256': ci.digest(ci.encode(plan)), 'unit': unit, **identity,
        'status': 'complete' if passed else 'failed',
        'seconds': round(time.monotonic() - started, 6), 'suites': completed}
    write_new(directory / 'unit.json', receipt)
    write_new(detail / 'errors.json', errors)
    if passed:
        ci.verify_unit(contract, plan, unit, directory)
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--registration', type=Path, required=True)
    base = parser.add_mutually_exclusive_group(required=True)
    base.add_argument('--base-registration', type=Path)
    base.add_argument('--initial-registration', action='store_true')
    for name in ('root', 'plan', 'artifacts', 'diagnostics'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('unit', 'revision', 'run-id', 'run-attempt'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        identity = dict(revision=args.revision, run_id=args.run_id, run_attempt=args.run_attempt,
                        source_sha256=ci.git_source_digest(args.root, args.revision))
        passed = execute_unit(args.root, ci.coverage.read_regular(args.registration),
            None if args.initial_registration else ci.coverage.read_regular(args.base_registration),
            ci.coverage.read_regular(args.plan), args.unit, args.artifacts, args.diagnostics,
            identity=identity)
        return 0 if passed else 1
    except (ci.InvalidEvidence, OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        print('CI unit execution refused or incomplete.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
