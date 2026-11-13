"""Retain the original suite process through cancellation and actual cleanup.

The trusted caller supplies a verified build and a reviewed isolation profile.
No timeout, exception, stream fault or interrupt authorizes killing the guardian.
"""
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import time

from guardian_protocol import GuardianProtocol, InvalidGuardianReceipt


def execute(*, executable, app, suite, cases, nonce, source_sha256, executable_sha256,
            app_sha256, profile, environment, evidence, seconds, behavior='run', target_probe=None, source_root=None):
    """Testing behaviors are closed qualification cases, never shell commands."""
    if behavior not in {'run', 'cancel-before-run', 'lost-before-run', 'invalid-before-run',
                        'deadline-before-run', 'status-reader-lost', 'cancel-at-probe', 'lost-at-probe',
                        'status-reader-lost-at-probe'}:
        raise ValueError('unknown guardian qualification behavior')
    if suite not in {'m1', 'm3', 'practical-m3', 'm2', 'practical-m2', 'policy-projection', 'closed-runner', 'runtime-custody', 'policy-wire', 'policy-binding', 'm4', 'policy-input', 'policy-transport', 'runtime-guardian', 'm6', 'm6-custody-capture', 'm6-staged-reconciliation', 'reconciliation-observer', 'release-identity', 'identity-history', 'policy-authority', 'policy-snapshot', 'policy-catalog', 'policy-catalog-session', 'publisher-policy', 'runtime-ownership', 'discovery-spawn', 'discovery-caller', 'discovery-bootstrap', 'retention-custody', 'body1', 'body2', 'body3', 'body4', 'v3-preflight', 'v4-preflight', 'beta-v02-chooser', 'beta-v02-device-drift', 'beta-v03', 'beta-v04', 'beta-v05', 'beta-v06', 'beta-v07', 'beta-v08', 'beta-v09'} or not 0 < seconds <= 3600:
        raise ValueError('unsupported suite or deadline')
    at_probe = behavior.endswith('-at-probe')
    if at_probe != (target_probe is not None) or (at_probe and
            (suite not in {'runtime-guardian', 'closed-runner', 'runtime-ownership', 'discovery-spawn'} or target_probe not in cases)):
        raise ValueError('invalid qualification cut point')
    executable, app, profile, evidence = map(Path, (executable, app, profile, evidence))
    working_directory = evidence
    if source_root is not None:
        source_root = Path(source_root)
        if not source_root.is_absolute() or source_root.resolve(strict=True) != source_root:
            raise ValueError('source working directory is not physical')
        info = source_root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('source working directory is not owner-controlled')
        working_directory = source_root
    for path, digest in [(executable, executable_sha256), (app, app_sha256)]:
        if path.resolve(strict=True) != path or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('artifact binding mismatch')
    if environment.get('SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE') != nonce:
        raise ValueError('fixture namespace mismatch')
    # Never replace an existing descriptor, including one from another writer.
    for fd in (207, 208):
        try:
            fcntl.fcntl(fd, fcntl.F_GETFD)
        except OSError as error:
            if error.errno != errno.EBADF:
                raise
        else:
            raise ValueError('reserved guardian descriptor is already open')
    evidence.mkdir(mode=0o700, parents=False, exist_ok=False)
    parser = GuardianProtocol(suite, cases, nonce, source_sha256, executable_sha256, app_sha256, target_probe)
    deadline = time.monotonic_ns() + int(seconds * 1_000_000_000)
    command = ['/usr/bin/sandbox-exec', '-f', str(profile), str(executable),
               '--shadow-sync-runtime-guardian', suite, str(app), nonce, str(deadline),
               source_sha256, executable_sha256, app_sha256, target_probe or 'none']
    record = dict(schema='shadow-sync-runtime-guardian-execution/v1', command=command,
                  passed=False, errors=[], automatic_termination=False, original_reaped=False,
                  behavior=behavior, working_directory=str(working_directory), streams={}, protocol_complete=False)
    process = None
    control = None
    descriptors = set()
    readers = {}
    child_ends = set()
    outputs = {}
    interrupted = []
    previous_signals = {}
    sent_initial = False
    parser_valid = True
    cancelled = False
    eof = set()
    exit_code = None
    status_fd = None
    stdout_line = bytearray()
    probe_triggered = False

    def error(message):
        # Bounded error evidence; the first failures are never overwritten.
        if len(record['errors']) < 64:
            record['errors'].append(message)

    def close_control():
        nonlocal control
        if control is not None:
            try: os.close(control)
            except OSError as failure:
                error('control close: ' + repr(failure))
                try: fcntl.fcntl(control, fcntl.F_GETFD)
                except OSError as observed:
                    if observed.errno != errno.EBADF: return
                else: return
            descriptors.discard(control); control = None

    def close_child_ends():
        # Each close is independent. A failed close remains tracked and retried
        # while the original guardian and all read pipes remain retained.
        for fd in tuple(child_ends):
            try:
                os.close(fd)
            except OSError as failure:
                try: fcntl.fcntl(fd, fcntl.F_GETFD)
                except OSError as observed:
                    if observed.errno == errno.EBADF:
                        child_ends.discard(fd); descriptors.discard(fd)
                error('child-side duplicate close: ' + repr(failure))
            else:
                child_ends.discard(fd); descriptors.discard(fd)

    def send(value):
        if control is None:
            return
        try:
            if os.write(control, value) != len(value): error('short control write')
        except OSError as failure:
            error('control write: ' + repr(failure)); close_control()

    def cancel():
        nonlocal cancelled
        if not cancelled:
            cancelled = True; send(b'C')
        close_control()

    def signal_received(number, _frame):
        if len(interrupted) < 16: interrupted.append(number)

    try:
        for name in ('stdout', 'stderr', 'status'):
            outputs[name] = (evidence / (name + '.raw')).open('xb', buffering=0)
            record['streams'][name] = {'bytes': 0, 'retained_bytes': 0, 'eof': False}
        for number in (signal.SIGINT, signal.SIGTERM):
            previous_signals[number] = signal.signal(number, signal_received)
        control_read, control = os.pipe()
        descriptors.update((control_read, control)); child_ends.add(control_read)
        status_fd, status_write = os.pipe()
        descriptors.update((status_fd, status_write)); child_ends.add(status_write)
        if any(fd in {207, 208} for fd in descriptors):
            raise ValueError('pipe allocation collided with reserved descriptors')
        os.dup2(control_read, 207, inheritable=True); descriptors.add(207); child_ends.add(207)
        os.dup2(status_write, 208, inheritable=True); descriptors.add(208); child_ends.add(208)
        os.set_blocking(control, False)
        process = subprocess.Popen(command, cwd=working_directory, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   pass_fds=(207, 208), start_new_session=True)
        record['pid'] = process.pid
    except BaseException as failure:
        error('setup: ' + repr(failure)); cancel()
    finally:
        # Once Popen returned, every path stays here with that original handle.
        # Exceptions in readers/evidence cannot discard live cleanup ownership.
        if process is not None:
            # Establish all fallback readers even after any post-spawn failure.
            # select readiness makes a sole read safe if nonblocking setup fails.
            readers = {process.stdout.fileno(): 'stdout', process.stderr.fileno(): 'stderr', status_fd: 'status'}
            for fd in readers:
                try: os.set_blocking(fd, False)
                except OSError as failure: error('nonblocking setup: ' + repr(failure)); cancel()
            close_child_ends()
            next_diagnostic = time.monotonic() + 20
            while exit_code is None or readers or child_ends:
                try:
                    close_child_ends()
                    if interrupted or record['errors'] or time.monotonic_ns() >= deadline:
                        cancel()
                    try:
                        exit_code = process.poll()
                    except Exception as failure:
                        error('original-handle observation: ' + repr(failure)); cancel()
                    available, _, _ = select.select(list(readers), [], [], 0.02)
                    for fd in available:
                        if fd not in readers: continue
                        name = readers[fd]
                        try:
                            chunk = os.read(fd, 16_384)
                        except BlockingIOError:
                            continue
                        except OSError as failure:
                            error('stream read: ' + repr(failure)); cancel()
                            continue
                        if not chunk:
                            readers.pop(fd); eof.add(name)
                            record['streams'][name]['eof'] = True
                            if name == 'status' and parser.terminal is None:
                                error('status EOF without terminal'); cancel()
                            continue
                        stats = record['streams'][name]; stats['bytes'] += len(chunk)
                        limit = 4_194_304 if name == 'status' else 262_144
                        remaining = max(0, limit - stats['retained_bytes'])
                        if remaining:
                            try:
                                stored = outputs[name].write(chunk[:remaining])
                                stats['retained_bytes'] += stored
                                if stored != min(len(chunk), remaining): error('short evidence write')
                            except Exception as failure:
                                error('evidence write: ' + repr(failure)); cancel()
                        if stats['bytes'] > limit:
                            error(name + ' overflow'); cancel()
                        if name == 'stdout' and at_probe and not probe_triggered:
                            for byte in chunk:
                                stdout_line.append(byte)
                                if len(stdout_line) > 2048:
                                    error('qualification output frame overflow'); cancel(); break
                                if byte == 10:
                                    line = bytes(stdout_line); stdout_line.clear()
                                    if line == ('GUARDIAN PROBE ' + target_probe + '\n').encode():
                                        probe_triggered = True
                                        if behavior == 'cancel-at-probe': send(b'C')
                                        elif behavior == 'lost-at-probe': close_control()
                                        else:
                                            readers.pop(status_fd); os.close(status_fd)
                                            descriptors.discard(status_fd); status_fd = None
                        if name == 'status' and parser_valid:
                            try:
                                parser.feed(chunk)
                            except InvalidGuardianReceipt as failure:
                                parser_valid = False; error('protocol: ' + str(failure)); cancel()
                            if parser_valid and parser.ready and not sent_initial:
                                sent_initial = True
                                if behavior == 'run' or at_probe: send(b'R')
                                elif behavior == 'cancel-before-run': send(b'C')
                                elif behavior == 'lost-before-run': close_control()
                                elif behavior == 'invalid-before-run': send(b'X')
                                elif behavior == 'status-reader-lost':
                                    readers.pop(status_fd); os.close(status_fd)
                                    descriptors.discard(status_fd); status_fd = None
                                # deadline-before-run intentionally sends no R.
                    if time.monotonic() >= next_diagnostic:
                        # The receipt remains pending, never a passing timeout.
                        try:
                            os.write(2, b'Guardian original handle retained; cleanup pending.\n')
                        except OSError:
                            error('diagnostic output failed'); cancel()
                        next_diagnostic += 20
                except BaseException as failure:
                    error('observer: ' + repr(failure)); cancel()
                    time.sleep(0.01)
            record['original_reaped'] = True
            record['exit'] = exit_code
            try:
                protocol_passed = parser.finish(exit_code)
                record['protocol_complete'] = True
                record['terminal'] = parser.terminal
                record['passed'] = protocol_passed and not record['errors'] and not interrupted
            except InvalidGuardianReceipt as failure:
                error('completion: ' + str(failure))
        close_control()
        for fd in descriptors:
            try: os.close(fd)
            except OSError as failure: error('descriptor close: ' + repr(failure))
        if process is not None:
            for stream in (process.stdout, process.stderr):
                try: stream.close()
                except OSError as failure: error('pipe close: ' + repr(failure))
        for stream in outputs.values():
            try: os.fsync(stream.fileno())
            except OSError as failure: error('evidence fsync: ' + repr(failure))
            try: stream.close()
            except OSError as failure: error('evidence close: ' + repr(failure))
        for number, handler in previous_signals.items():
            try: signal.signal(number, handler)
            except (OSError, ValueError) as failure: error('signal restore: ' + repr(failure))
        record['interrupts'] = interrupted
        record['probe_triggered'] = probe_triggered
        record['passed'] = record['passed'] and not record['errors'] and not interrupted
        try:
            with (evidence / 'receipt.json').open('x') as out:
                json.dump(record, out, indent=2); out.write('\n'); out.flush(); os.fsync(out.fileno())
        except (OSError, ValueError) as failure:
            error('receipt persistence: ' + repr(failure)); record['passed'] = False
    return record
