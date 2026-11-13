"""Bounded, sanitized crash frames for the exact GitHub-hosted fixture process.

Never runs on a local host, changes suite results or reads user repository/state.
Apple format: https://developer.apple.com/documentation/xcode/interpreting-the-json-format-of-a-crash-report
"""
from datetime import datetime
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import time

UUID = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
SYMBOL = re.compile(r'[A-Za-z0-9_$<> .,:()\[\]&?!=+*~-]{1,600}')


def project(data, *, pid, executable, binary_uuid, started, finished):
    decoder = json.JSONDecoder()
    header, end = decoder.raw_decode(data)
    report, end = decoder.raw_decode(data[end:].lstrip())
    if not isinstance(header, dict) or not isinstance(report, dict):
        raise ValueError('invalid report object')
    if header.get('bug_type') != '309' or report.get('pid') != pid \
            or report.get('procName') != 'ShadowSyncSelfTest' \
            or report.get('procPath') != str(executable):
        raise ValueError('foreign process')
    captured = datetime.fromisoformat(report['captureTime'])
    launched = datetime.fromisoformat(report['procLaunch'])
    # Apple timestamps may round sub-millisecond wall time; tolerate 1ms only.
    if captured.tzinfo is None or launched.tzinfo is None or not (
            started - .001 <= launched.timestamp() <= captured.timestamp() <= finished + .001):
        raise ValueError('foreign execution interval')
    images = report['usedImages']
    own = [i for i, row in enumerate(images) if row.get('uuid', '').lower() == binary_uuid.lower()
           and row.get('name') == 'ShadowSyncSelfTest']
    if len(own) != 1:
        raise ValueError('foreign executable')
    thread = report['threads'][report['faultingThread']]
    frames = []
    for row in thread['frames'][:64]:
        index, offset = row['imageIndex'], row['imageOffset']
        if type(index) is not int or not 0 <= index < len(images) \
                or type(offset) is not int or not 0 <= offset < 2**40:
            raise ValueError('invalid frame')
        image = images[index]
        image_uuid = image.get('uuid', '')
        if UUID.fullmatch(image_uuid) is None:
            raise ValueError('invalid image identity')
        # Keep image identity and offsets for symbolication, never paths, machine
        # identifiers, register contents, process arguments or arbitrary strings.
        item = {'image_uuid': image_uuid.lower(), 'image_offset': offset,
                'fixture_executable': index == own[0]}
        symbol = row.get('symbol', '')
        if SYMBOL.fullmatch(symbol) is not None:
            item['symbol'] = symbol
        frames.append(item)
    if not frames:
        raise ValueError('empty crash')
    return {'schema': 'shadow-sync-hosted-crash-frames/v1', 'binary_uuid': binary_uuid.lower(),
            'frames': frames}


def capture(result, *, executable, evidence, started, source_sha256):
    finished = time.time()
    # These platform facts must all agree before consulting the ephemeral runner
    # account. Local fixture execution never opens a diagnostic-report directory.
    if not (os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
            and os.environ.get('RUNNER_OS') == 'macOS'
            and os.environ.get('GITHUB_REPOSITORY') == 'KleinPerkins/shadow-sync'
            and result.get('exit') in (-4, -6, -7, -10, -11)
            and result.get('original_reaped') is True and type(result.get('pid')) is int):
        return
    record = {'schema': 'shadow-sync-hosted-crash-observation/v1', 'status': 'unavailable',
              'source_sha256': source_sha256, 'exit': result['exit']}
    try:
        account = pwd.getpwuid(os.getuid())
        if account.pw_name != 'runner' or not str(executable).startswith('/private/tmp/shadow-sync-ci.'):
            return
        identity = subprocess.run(['/usr/bin/xcrun', 'dwarfdump', '--uuid', str(executable)],
            check=True, capture_output=True, text=True, timeout=5).stdout
        values = re.findall(r'^UUID: ([0-9A-Fa-f-]{36}) \(arm64\) ', identity, re.MULTILINE)
        if len(values) != 1 or UUID.fullmatch(values[0]) is None:
            raise ValueError('unavailable executable identity')
        root = Path(account.pw_dir) / 'Library/Logs/DiagnosticReports'
        if root.resolve(strict=True) != root or not root.is_dir():
            raise ValueError('unavailable report directory')
        for attempt in range(5):
            matches = sorted(root.glob('ShadowSyncSelfTest*.ips'))[-32:]
            for path in matches:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                try:
                    info = os.fstat(fd)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 \
                            or not started <= info.st_mtime <= time.time() or not 0 < info.st_size <= 4_194_304:
                        continue
                    data = os.read(fd, info.st_size + 1)
                    after = os.fstat(fd)
                    if len(data) != info.st_size or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns):
                        continue
                    try:
                        report = project(data.decode('utf-8'), pid=result['pid'], executable=executable,
                                         binary_uuid=values[0], started=started, finished=finished)
                    except (ValueError, KeyError, TypeError, IndexError, AttributeError):
                        continue
                    record.update(status='captured', crash=report)
                    break
                finally:
                    os.close(fd)
            if record['status'] == 'captured':
                break
            if attempt != 4:
                time.sleep(.5)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass  # A diagnostic failure cannot replace or hide the original failure.
    try:
        with (Path(evidence) / 'hosted-crash.json').open('x') as out:
            json.dump(record, out, sort_keys=True); out.write('\n')
    except OSError:
        pass  # Preserve the original runtime failure and its ownership assertions.
