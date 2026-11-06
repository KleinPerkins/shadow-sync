#!/usr/bin/env -S python3 -I
"""Admit only physical private development fixtures; never inspect a live home."""
import os
import stat
import sys


def directory(parent, name):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                   dir_fd=parent)


def bundle_entries(parent, name, budget):
    value = os.stat(name, dir_fd=parent, follow_symlinks=False)
    budget[0] -= 1
    if (budget[0] < 0 or value.st_uid != os.geteuid()
            or value.st_mode & 0o022 or not (stat.S_ISDIR(value.st_mode) or stat.S_ISREG(value.st_mode))):
        raise ValueError('fixture bundle entry is unsafe')
    if stat.S_ISREG(value.st_mode):
        if value.st_nlink != 1:
            raise ValueError('fixture bundle file has multiple links')
        return
    fd = directory(parent, name)
    try:
        if (os.fstat(fd).st_dev, os.fstat(fd).st_ino) != (value.st_dev, value.st_ino):
            raise ValueError('fixture bundle directory changed')
        for child in os.listdir(fd):
            bundle_entries(fd, child, budget)
    finally:
        os.close(fd)


def verify(root, doctor=False, stub_required=False):
    # Reject disallowed literals before opening any caller-supplied component.
    if not root.startswith('/private/tmp/') or any(c in root for c in ('\n', '\r', '\0')):
        raise ValueError('fixture root must be beneath /private/tmp')
    parts = root.split('/')[1:]
    if any(part in ('', '.', '..') for part in parts):
        raise ValueError('fixture root must be a canonical physical path')
    fd = directory(None, '/')
    try:
        for part in parts:
            child = directory(fd, part)
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('fixture root must be owner-private mode 0700')
        if doctor:
            # Validate every ancestor traversed by the retained diagnostic before
            # it performs existence probes, file reads, directory listings or code execution.
            for path in ('home', 'home/Applications', 'home/Library', 'home/Library/LaunchAgents',
                         'home/.local', 'home/.local/state', 'home/.local/state/shadow-sync',
                         'home/.local/state/shadow-sync/retention'):
                cursor = os.dup(fd)
                try:
                    for part in path.split('/'):
                        try:
                            child = directory(cursor, part)
                        except FileNotFoundError:
                            break  # An absent path cannot redirect to an external namespace.
                        os.close(cursor)
                        cursor = child
                        value = os.fstat(cursor)
                        if value.st_uid != os.geteuid() or stat.S_IMODE(value.st_mode) != 0o700:
                            raise ValueError('fixture diagnostic directory is not private')
                finally:
                    os.close(cursor)
            # Development bundles have no framework aliases. Validate their entire
            # topology before codesign/plutil or executable existence checks can follow it.
            try:
                app_parent = directory(fd, 'home/Applications')
            except FileNotFoundError:
                app_parent = None
            if app_parent is not None:
                try:
                    try:
                        bundle_entries(app_parent, 'ShadowSync.app', [10000])
                    except FileNotFoundError:
                        if os.path.lexists(root + '/home/Applications/ShadowSync.app'):
                            raise
                finally:
                    os.close(app_parent)
        if stub_required:
            stub = os.stat('launchctl-stub', dir_fd=fd, follow_symlinks=False)
            if (not stat.S_ISREG(stub.st_mode) or stub.st_nlink != 1
                    or stub.st_uid != os.geteuid() or stat.S_IMODE(stub.st_mode) != 0o700):
                raise ValueError('fixture launchctl stub is unsafe')
    finally:
        os.close(fd)
    return root


def main():
    if not sys.flags.isolated or len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ('--doctor', '--doctor-absent')):
        sys.stderr.write('usage: python3 -I verify-fixture-root.py ROOT [--doctor|--doctor-absent]\n')
        return 2
    try:
        print(verify(sys.argv[1], len(sys.argv) == 3, sys.argv[-1] == '--doctor-absent'))
        return 0
    except (ValueError, OSError):
        sys.stderr.write('Development fixture root is unsafe.\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
