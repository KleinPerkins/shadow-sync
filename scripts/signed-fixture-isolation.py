#!/usr/bin/env python3
"""Emit the separate signed fixture isolation profile; never execute a case.

Native canaries remain mandatory. Rendering does not qualify Seatbelt behavior,
AppKit access, anonymous AF_UNIX channels, or any process/ownership boundary.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import stat


def require(value, reason):
    if not value:
        raise ValueError(reason)


def root_name(root, nonce):
    root = str(root)
    require(re.fullmatch('[0-9a-f]{32}', nonce) is not None, 'fixture-nonce')
    require(re.fullmatch('/private/tmp/shadow-sync-ic[.]' + nonce + '[.][A-Za-z0-9]{6}', root) is not None,
            'fixture-root-name')
    return root


def render(root, nonce, real_home):
    root = root_name(root, nonce)
    require(type(real_home) is str and real_home.startswith('/') and real_home not in ('/', '/private', '/private/tmp')
            and not any(ord(c) < 32 for c in real_home), 'account-home')
    quote = lambda value: json.dumps(str(value), ensure_ascii=True)
    # Keep AppKit and Security system-service access available. Filesystem,
    # network and exec authority are reduced separately, with no general shell,
    # Git, launchctl, codesign or interpreter execution exception.
    lines = ['(version 1)', '(allow default)', '(deny network*)', '(deny process-exec)', '(deny file-write*)']
    for home in sorted({'/Users', real_home}):
        lines.append('(deny file-read* file-write* (subpath ' + quote(home) + '))')
    # Per-user macOS temporary/cache trees can contain another fixture's files
    # with the same UID. Cover both physical paths and their standard aliases;
    # only this fixture's fixed physical root receives a file-read exception.
    for temporary in ('/private/tmp', '/tmp', '/private/var/tmp', '/var/tmp',
                      '/private/var/folders', '/var/folders'):
        lines.append('(deny file-read* file-write* (subpath ' + quote(temporary) + '))')
    lines.append('(allow file-read* file-write* (subpath ' + quote(root) + '))')
    lines.append('(allow file-write* (literal "/dev/null"))')
    for executable in (root + '/candidate/ShadowSync.app/Contents/Helpers/ShadowSyncLifecycleCoordinator',
                       root + '/home/Applications/ShadowSync.app/Contents/MacOS/ShadowSync'):
        lines.append('(allow process-exec (literal ' + quote(executable) + '))')
    for socket in ('installation.sock', 'host.sock'):
        lines.append('(allow network-bind network-inbound network-outbound (literal '
                     + quote(root + '/state/shadow-sync/' + socket) + '))')
    # There is intentionally no broad Unix-socket or anonymous-channel exception.
    # Actual socketpair and Security peer behavior must pass native canaries;
    # refusal cannot be recategorized as a successful installation case.
    return '\n'.join(lines) + '\n'


def emit(root, nonce):
    root = Path(root_name(root, nonce))
    require(root.resolve(strict=True) == root, 'physical-root')
    before = root.lstat()
    require(stat.S_ISDIR(before.st_mode) and stat.S_IMODE(before.st_mode) == 0o700
            and before.st_uid == os.getuid(), 'private-root')
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        held = os.fstat(descriptor)
        require((held.st_dev, held.st_ino, held.st_uid, held.st_mode) ==
                (before.st_dev, before.st_ino, before.st_uid, before.st_mode), 'root-replaced')
        profile = render(root, nonce, pwd.getpwuid(os.getuid()).pw_dir).encode()
        leaf = os.open('signed-isolation.sb', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                       0o600, dir_fd=descriptor)
        try:
            offset = 0
            while offset < len(profile):
                count = os.write(leaf, profile[offset:]); require(count > 0, 'profile-write'); offset += count
            os.fsync(leaf)
        finally:
            os.close(leaf)
        os.fsync(descriptor)
        after = root.lstat()
        require((before.st_dev, before.st_ino, before.st_uid, before.st_mode) ==
                (after.st_dev, after.st_ino, after.st_uid, after.st_mode), 'root-changed')
        return root / 'signed-isolation.sb'
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    parser.add_argument('--nonce', required=True)
    args = parser.parse_args()
    try:
        emit(args.root, args.nonce)
        print('Signed fixture isolation profile written; native controls remain unqualified.')
        return 0
    except Exception:
        print('Signed fixture isolation profile unavailable; partial output is retained.')
        return 78


if __name__ == '__main__':
    raise SystemExit(main())
