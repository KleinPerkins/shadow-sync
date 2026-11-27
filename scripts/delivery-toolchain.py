"""Pinned, credential-free verification runtimes; no global installation."""
import fcntl
import hashlib
import io
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NODE_VERSION = '26.4.0'
NODE_ARCHIVE = f'node-v{NODE_VERSION}-darwin-arm64.tar.xz'
NODE_SHA256 = 'bef4c7e75087c029835f519a7ba640eba52fa617fadb3a9049828ff3b45b57dd'
NODE_BINARY_BYTES = 145_172_672
NODE_BINARY_SHA256 = 'd23e520f5bcd497bdd0c6a6242356a4fd255abaceba7c3549727caacb936ddae'
WRANGLER_FILES = {
    'bin/wrangler.js': (3088, '780661a508810f3b65786895b1ca9aacbc4f55d329ae6b8c1e49ec8433569f77'),
    'package.json': (6937, '9746d6df16da6f6a8d9609d5e5c22a70235ead6278f975fe446ca5edda7eae12'),
    'wrangler-dist/cli.js': (14870680, '480ecc13facecf9b62ba7fbc51c29df931618ef84b83de149d44e0e374ee4059'),
}
MAX_ARCHIVE = 100 * 1024**2
MAX_EXPANDED = 512 * 1024**2


def download_bytes(url, maximum, timeout):
    """Retry transient transport failures three times, retaining no partial body.

    Callers still verify the size and pinned digest before extracting any bytes.
    Permanent HTTP errors, TLS validation and content failures do not retry.
    """
    for attempt, delay in enumerate((0, 1, 3)):
        if delay:
            time.sleep(delay)
        try:
            with urllib.request.urlopen(url, timeout=timeout) as response:
                return response.read(maximum + 1)
        except urllib.error.HTTPError as error:
            error.close()
            if error.code not in (500, 502, 503, 504) or attempt == 2:
                raise
        except urllib.error.URLError as error:
            if not isinstance(error.reason, (TimeoutError, ConnectionResetError, ConnectionAbortedError)) or attempt == 2:
                raise
        except (TimeoutError, ConnectionResetError, ConnectionAbortedError):
            if attempt == 2:
                raise


def node_environment():
    names = ('HOME', 'PATH', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL')
    return {name: os.environ[name] for name in names if name in os.environ}


def _version(binary, *, privileged=False):
    binary = verify_node_binary(binary, privileged=privileged)
    result = subprocess.run([str(binary), '--version'], capture_output=True, timeout=10, check=True,
                            env=node_environment())
    if result.stdout.strip() != ('v' + NODE_VERSION).encode('ascii'):
        raise ValueError('Verification requires Node ' + NODE_VERSION)
    return binary


def _cache_directory(path, *, private=False):
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or
            (private and stat.S_IMODE(info.st_mode) != 0o700)):
        raise ValueError('Toolchain cache must be an owner-private physical directory')


def _trusted_parents(path, *, privileged=False):
    owners = (0,) if privileged else (0, os.getuid())
    for parent in path.parents:
        info = parent.lstat()
        protected = not info.st_mode & 0o022
        sticky_fixture_parent = not privileged and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in owners or not (protected or sticky_fixture_parent):
            raise ValueError('Toolchain ancestors must be trusted physical directories')


def _verify_file(path, expected, *, privileged, executable=False):
    owners = (0,) if privileged else (0, os.getuid())
    expected_size, expected_digest = expected
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid not in owners or before.st_nlink != 1 or
                before.st_mode & 0o7022 or (executable and not before.st_mode & 0o100) or
                before.st_size != expected_size):
            raise ValueError('Pinned toolchain file changed')
        digest = hashlib.sha256()
        remaining = before.st_size
        while remaining:
            chunk = stream.read(min(remaining, 1024 * 1024))
            if not chunk:
                raise ValueError('Pinned toolchain file changed')
            digest.update(chunk)
            remaining -= len(chunk)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_uid, value.st_mode, value.st_nlink,
                                  value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if (stream.read(1) or digest.hexdigest() != expected_digest or
                identity(before) != identity(os.fstat(fd)) or identity(before) != identity(path.lstat())):
            raise ValueError('Pinned toolchain file changed')


def verify_node_binary(binary, *, privileged=False):
    binary = Path(binary).resolve(strict=True)
    _trusted_parents(binary, privileged=privileged)
    _verify_file(binary, (NODE_BINARY_BYTES, NODE_BINARY_SHA256), privileged=privileged, executable=True)
    return binary


def verify_wrangler(entry):
    entry = Path(entry).resolve(strict=True)
    package = entry.parent.parent
    modules = package.parent
    if entry != modules / 'wrangler/bin/wrangler.js' or modules.name != 'node_modules':
        raise ValueError('Wrangler requires its official installed package layout')
    _trusted_parents(entry, privileged=True)
    for name, identity in WRANGLER_FILES.items():
        path = package / name
        _trusted_parents(path, privileged=True)
        _verify_file(path, identity, privileged=True)
    # Trust only administrator-managed dependencies beneath this installation.
    # Resolve links inside this installation and check the physical dependencies.
    pending = [modules]
    inspected = set()
    observed = 0
    while pending:
        directory = pending.pop()
        if directory in inspected:
            continue
        inspected.add(directory)
        for path in directory.iterdir():
            observed += 1
            if observed > 100_000:
                raise ValueError('Wrangler dependency inventory exceeds its limit')
            info = path.lstat()
            if info.st_uid != 0:
                raise ValueError('Wrangler dependencies must remain administrator-owned')
            if stat.S_ISLNK(info.st_mode):
                path = path.resolve(strict=True)
                if not path.is_relative_to(modules):
                    raise ValueError('Wrangler dependency link escapes the trusted installation')
                _trusted_parents(path, privileged=True)
                info = path.lstat()
                if info.st_uid != 0:
                    raise ValueError('Wrangler dependency link target must remain administrator-owned')
            if info.st_mode & 0o7022:
                raise ValueError('Wrangler dependencies must remain non-writable')
            elif stat.S_ISDIR(info.st_mode):
                pending.append(path)
            elif not stat.S_ISREG(info.st_mode):
                raise ValueError('Unexpected Wrangler dependency resource')
    return entry


def node(cache=None, *, privileged=False):
    """Use an exact installed runtime or verify/cache the official distribution."""
    configured = os.environ.get('SHADOW_SYNC_DELIVERY_NODE')
    if configured:
        return _version(configured, privileged=privileged)
    installed = shutil.which('node')
    if installed:
        try:
            return _version(installed, privileged=privileged)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    if privileged:
        raise ValueError('An administrator-owned official Node installation is required')
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise RuntimeError('Pinned verification runtime requires macOS Apple Silicon')
    if cache is None:
        raise ValueError('An explicit task-owned verification cache is required')
    cache = Path(cache).absolute()
    _trusted_parents(cache)
    cache.mkdir(mode=0o700, exist_ok=True)
    _cache_directory(cache, private=True)
    target = cache / f'node-v{NODE_VERSION}'
    lock_fd = os.open(cache / '.node.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
    with os.fdopen(lock_fd, 'r+b') as lock:
        info = os.fstat(lock_fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_size != 0):
            raise ValueError('Invalid toolchain cache lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        if os.path.lexists(target):
            for directory in (target, target / 'bin'):
                _cache_directory(directory)
            binary = target / 'bin/node'
            if binary.is_symlink():
                raise ValueError('Pinned Node executable changed')
            return _version(binary)
        payload = download_bytes(f'https://nodejs.org/dist/v{NODE_VERSION}/{NODE_ARCHIVE}', MAX_ARCHIVE, 30)
        if len(payload) > MAX_ARCHIVE or hashlib.sha256(payload).hexdigest() != NODE_SHA256:
            raise ValueError('Verification runtime archive checksum mismatch')
        with tempfile.TemporaryDirectory(prefix='node-stage-', dir=cache) as temporary:
            staging = Path(temporary)
            with tarfile.open(fileobj=io.BytesIO(payload), mode='r:xz') as archive:
                members = archive.getmembers()
                prefix = NODE_ARCHIVE.removesuffix('.tar.xz')
                if len(members) > 10000 or sum(member.size for member in members) > MAX_EXPANDED:
                    raise ValueError('Verification runtime archive exceeds limits')
                for member in members:
                    parts = Path(member.name).parts
                    if not parts or parts[0] != prefix or '..' in parts or Path(member.name).is_absolute():
                        raise ValueError('Unsafe verification runtime archive path')
                archive.extractall(staging, filter='data')
            unpacked = staging / prefix
            verify_node_binary(unpacked / 'bin/node')
            unpacked.rename(target)
        return _version(target / 'bin/node')
