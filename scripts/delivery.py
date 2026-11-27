#!/usr/bin/env python3
"""Owner-only Cloudflare delivery administration. Importing this module does no I/O.

Secrets are captured in memory from pinned Wrangler's original owner auth and are
never printed, placed in argv, written to config, or passed to recipient apps.
"""
import argparse
import base64
from contextlib import ExitStack, contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
_toolchain_spec = importlib.util.spec_from_file_location('delivery_toolchain', ROOT / 'scripts/delivery-toolchain.py')
toolchain = importlib.util.module_from_spec(_toolchain_spec)
_toolchain_spec.loader.exec_module(toolchain)
APP = 'com.kleinperkins.shadow-sync'
WRANGLER = '4.158.0'
MAX_ARCHIVE = 512 * 1024 * 1024
PART_SIZE = 20 * 1024 * 1024
PIECE_SIZE = 256 * 1024
MAX_PIECES = 2048
WIRE_LIMIT = 256 * 1024
MAX_FILES = 20000
FREE_PROOF_MAX_AGE = 3600
WORKER_MODULES = ('worker.mjs', 'contract.mjs', 'web.mjs')
WORKER_PACKAGING = {
    'no_bundle': True,
    'find_additional_modules': True,
    'preserve_file_names': True,
    'rules': [
        {'type': 'ESModule', 'globs': ['contract.mjs', 'web.mjs']},
        {'type': 'Text', 'globs': [], 'fallthrough': False},
        {'type': 'Data', 'globs': [], 'fallthrough': False},
        {'type': 'CompiledWasm', 'globs': [], 'fallthrough': False},
    ],
}
DEPLOYMENT_SCHEMA = 'shadow-sync/private-deployment/v2'
LEGACY_DEPLOYMENT_SCHEMA = 'shadow-sync/private-deployment/v1'
CHECKS = ('ci_required', 'merged_source', 'developer_id', 'notarization',
          'stapled_ticket', 'gatekeeper', 'archive_signature', 'coordinator_packaged')
FRIEND_CHECKS = ('clean_install', 'failure_recovery', 'preserved_state_migration', 'operator_acceptance')

class DeliveryError(Exception):
    """Safe, credential-free user-facing failure."""


class _AccessFileAbsent(DeliveryError):
    """Only an unopened name absent inside an unchanged private parent."""


def bounded_json(path, maximum=65536):
    with Path(path).open('rb') as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise DeliveryError('JSON input exceeds its size limit.')
    try:
        return json.loads(data)
    except (ValueError, UnicodeError):
        raise DeliveryError('Invalid JSON input.') from None


def outside_git(path):
    if not Path(path).is_absolute():
        raise DeliveryError('Private paths must be explicit absolute canonical paths.')
    path = Path(path).absolute()
    if path != path.resolve():
        raise DeliveryError('Private files must use canonical paths without symlinks.')
    parent = path.parent
    if not parent.is_dir():
        raise DeliveryError('Create the private output directory first.')
    environment = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'GIT_CONFIG_GLOBAL': os.devnull,
                   'GIT_CONFIG_NOSYSTEM': '1', 'GIT_TERMINAL_PROMPT': '0'}
    result = subprocess.run(['/usr/bin/git', '-C', str(parent), 'rev-parse', '--show-toplevel'],
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=10, env=environment)
    if result.returncode == 0:
        raise DeliveryError('Private configuration/access files must be outside Git repositories.')
    missing = (b'fatal: not a git repository (or any of the parent directories): .git',
               b'fatal: not a git repository (or any parent directories): .git')
    stderr_lines = result.stderr.splitlines()
    if result.returncode != 128 or not stderr_lines or stderr_lines[-1] not in missing:
        raise DeliveryError('Could not verify private path is outside Git repositories.')
    return path


def require_named_parent(path, directory_fd, expected):
    if (path.parent != path.parent.resolve() or
            access_parent(path.parent.stat(follow_symlinks=False)) != expected or
            access_parent(os.fstat(directory_fd)) != expected):
        raise DeliveryError('Private output directory identity changed.')


@contextmanager
def private_write_parent(path, *, owner_only=False):
    path = outside_git(path)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY | os.O_CLOEXEC
    with ExitStack() as handles:
        directory_fd = os.open('/', flags)
        handles.callback(os.close, directory_fd)
        for component in path.parent.parts[1:]:
            directory_fd = os.open(component, flags, dir_fd=directory_fd)
            handles.callback(os.close, directory_fd)
        directory = os.fstat(directory_fd)
        if (directory.st_uid != os.getuid() or directory.st_mode & 0o022 or
                (owner_only and stat.S_IMODE(directory.st_mode) != 0o700)):
            raise DeliveryError('Private output requires an owner-controlled directory.')
        expected = access_parent(directory)
        # Recheck the Git boundary after acquiring the descriptor and bracket
        # that observation with the physical identity of the named parent.
        require_named_parent(path, directory_fd, expected)
        outside_git(path)
        require_named_parent(path, directory_fd, expected)
        yield path, directory_fd, expected


def preserve_private_output(target, staged, directory_fd):
    try:
        previous = os.stat(target, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if (not stat.S_ISREG(previous.st_mode) or previous.st_uid != os.getuid() or
            stat.S_IMODE(previous.st_mode) != 0o600 or previous.st_nlink != 1):
        raise DeliveryError('Existing private receipt is unsafe or has an unresolved recovery copy.')
    backup = staged + '.previous'
    os.link(target, backup, src_dir_fd=directory_fd, dst_dir_fd=directory_fd, follow_symlinks=False)
    preserved = os.stat(backup, dir_fd=directory_fd, follow_symlinks=False)
    if (previous.st_dev, previous.st_ino) != (preserved.st_dev, preserved.st_ino):
        raise DeliveryError('Previous private receipt identity changed.')
    os.fsync(directory_fd)
    return backup


def private_write(path, value, *, replace=False):
    with private_write_parent(path) as (path, directory_fd, expected):
        name = path.name + '.' + secrets.token_hex(8) if replace else path.name
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
        fd = os.open(name, flags, 0o600, dir_fd=directory_fd)
        with os.fdopen(fd, 'w') as stream:
            created = os.fstat(stream.fileno())
            backup = None
            try:
                json.dump(value, stream, separators=(',', ':'))
                stream.write('\n')
                stream.flush()
                os.fsync(stream.fileno())
                observed = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                if access_stat(observed) != access_stat(os.fstat(stream.fileno())):
                    raise DeliveryError('Private output file identity changed.')
                require_named_parent(path, directory_fd, expected)
                if replace:
                    backup = preserve_private_output(path.name, name, directory_fd)
                    require_named_parent(path, directory_fd, expected)
                    os.replace(name, path.name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
                os.fsync(directory_fd)
                require_named_parent(path, directory_fd, expected)
                observed = os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False)
                if access_stat(observed) != access_stat(os.fstat(stream.fileno())):
                    raise DeliveryError('Private output file identity changed.')
                if backup is not None:
                    os.unlink(backup, dir_fd=directory_fd)
            except BaseException:
                # A previous receipt that was durably linked remains available
                # even if the new receipt landed but could not be confirmed.
                try:
                    observed = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    if (observed.st_dev, observed.st_ino) == (created.st_dev, created.st_ino):
                        os.unlink(name, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
                raise


def load_config(path):
    path = outside_git(path)
    info = path.stat(follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise DeliveryError('Private configuration must be an owner-owned mode-0600 regular file.')
    config = bounded_json(path)
    required = {'origin', 'account_id', 'database_id', 'database_name', 'worker_name', 'wrangler', 'assets_directory', 'free_plan_proof', 'deployment_state'}
    if set(config) != required:
        raise DeliveryError('Private configuration keys do not match the template.')
    parsed = urllib.parse.urlsplit(config['origin'])
    if (parsed.scheme != 'https' or parsed.username or parsed.password or parsed.query or parsed.fragment or
        parsed.path or not parsed.hostname or parsed.hostname.endswith('.r2.dev') or
        parsed.netloc != parsed.hostname):
        raise DeliveryError('Select a canonical HTTPS download hostname (default port).')
    if not re.fullmatch(r'[a-f0-9]{32}', config['account_id']) or not re.fullmatch(r'[a-f0-9-]{36}', config['database_id']):
        raise DeliveryError('Invalid explicit account/database binding.')
    for key in ('database_name', 'worker_name'):
        if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', config[key]):
            raise DeliveryError('Invalid private resource name.')
    binary = Path(config['wrangler'])
    if not binary.is_absolute() or not binary.is_file():
        raise DeliveryError('Configure the absolute path of preinstalled pinned Wrangler.')
    private_directory(config['assets_directory'])
    outside_git(config['free_plan_proof'])
    outside_git(config['deployment_state'])
    return config


def private_json(path):
    path = outside_git(path)
    info = path.stat(follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise DeliveryError('Private evidence must be an owner-owned mode-0600 regular file.')
    return bounded_json(path, 16 * 1024 * 1024)


def require_free(config, now=None):
    # An explicit owner observation, not an independent provider/API assertion.
    try:
        proof = private_json(config['free_plan_proof'])
        current = int(time.time()) if now is None else now
        if (set(proof) != {'schema', 'account_id', 'observed_plan', 'source', 'source_reference', 'observed_at', 'expires_at'} or
            proof['schema'] != 'shadow-sync/free-plan-observation/v1' or
            proof['account_id'] != config['account_id'] or proof['observed_plan'] != 'Workers Free' or
            proof['source'] != 'owner-dashboard-observation' or
            not isinstance(proof['source_reference'], str) or not 1 <= len(proof['source_reference'].strip()) <= 512 or
            type(proof['observed_at']) is not int or type(proof['expires_at']) is not int or
            not proof['observed_at'] <= current < proof['expires_at'] or
            not 0 < proof['expires_at'] - proof['observed_at'] <= FREE_PROOF_MAX_AGE):
            raise DeliveryError('Current account-bound Workers Free owner observation required; no operation performed.')
    except (OSError, KeyError, ValueError, TypeError):
        raise DeliveryError('Current account-bound Workers Free owner observation required; no operation performed.') from None
    return proof


def private_directory(path):
    root = outside_git(path)
    info = root.stat(follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise DeliveryError('Assets require an explicit owner-owned mode-0700 directory outside Git.')
    return root


def asset_inventory(config):
    root = private_directory(config['assets_directory'])
    expected_root = root.stat(follow_symlinks=False)
    inventory = {}
    pattern = r'/_private/' + re.escape(APP) + r'/[A-Za-z0-9_-]{1,128}/(?:archive|package)/[a-f0-9]{64}/(?:0|[1-9][0-9]{0,3})-([a-f0-9]{64})\.part'
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    with ExitStack() as handles:
        root_fd = os.open(root, flags | os.O_DIRECTORY)
        handles.callback(os.close, root_fd)
        for directory, subdirs, files, directory_fd in os.fwalk('.', dir_fd=root_fd):
            opened = os.fstat(directory_fd)
            if opened.st_uid != os.getuid() or stat.S_IMODE(opened.st_mode) != 0o700:
                raise DeliveryError('Private asset directories must be owner-owned with mode 0700.')
            for name in subdirs:
                info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                    raise DeliveryError('Asset symlinks/foreign ownership are forbidden.')
            for name in files:
                relative = '/' + (Path(directory) / name).as_posix()
                match = re.fullmatch(pattern, relative)
                if not match or int(name.split('-', 1)[0]) >= MAX_PIECES:
                    raise DeliveryError('Only bounded private immutable part files may be deployed; no routing/control files.')
                fd = os.open(name, flags, dir_fd=directory_fd)
                with os.fdopen(fd, 'rb') as stream:
                    before = os.fstat(stream.fileno())
                    if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1 or
                        stat.S_IMODE(before.st_mode) != 0o600 or not 0 < before.st_size <= PART_SIZE):
                        raise DeliveryError('Only bounded private mode-0600 regular part files may be deployed.')
                    hashed = hashlib.sha256()
                    remaining = before.st_size
                    while remaining:
                        chunk = stream.read(min(remaining, 1024 * 1024))
                        if not chunk:
                            raise DeliveryError('Retained asset length changed.')
                        remaining -= len(chunk)
                        hashed.update(chunk)
                    if (stream.read(1) or access_stat(before) != access_stat(os.fstat(stream.fileno())) or
                        access_stat(before) != access_stat(os.stat(name, dir_fd=directory_fd, follow_symlinks=False)) or
                        hashed.hexdigest() != match[1]):
                        raise DeliveryError('Retained asset hash or custody changed.')
                    inventory[relative] = {'sha256': match[1], 'size': before.st_size}
                    if len(inventory) > MAX_FILES:
                        raise DeliveryError('Complete retained asset set exceeds Workers Free file-count bound.')
        if (access_parent(expected_root) != access_parent(os.fstat(root_fd)) or
            access_parent(expected_root) != access_parent(root.stat(follow_symlinks=False))):
            raise DeliveryError('Private asset root changed during inventory.')
    return inventory


def stage_artifact(config, source, release_id, kind, descriptor):
    require_free(config)
    if (not isinstance(descriptor, dict) or not re.fullmatch(r'[a-f0-9]{64}', descriptor.get('sha256', '')) or
        type(descriptor.get('size')) is not int or not 0 < descriptor['size'] <= MAX_ARCHIVE):
        raise DeliveryError('Invalid bounded artifact descriptor.')
    root = private_directory(config['assets_directory'])
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', release_id) or kind not in ('archive', 'package'):
        raise DeliveryError('Invalid immutable artifact identity.')
    parts, digest, total = [], hashlib.sha256(), 0
    relative = ('_private', APP, release_id, kind, descriptor['sha256'])
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    with ExitStack() as handles:
        folder = os.open('/', directory_flags)
        handles.callback(os.close, folder)
        ancestry = []
        for position, component in enumerate((*root.parts[1:], *relative), start=1):
            if position >= len(root.parts):
                try:
                    os.mkdir(component, mode=0o700, dir_fd=folder)
                    os.fsync(folder)
                except FileExistsError:
                    pass
            child = os.open(component, directory_flags, dir_fd=folder)
            handles.callback(os.close, child)
            info = os.fstat(child)
            private = position >= len(root.parts) - 1
            if private and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700):
                raise DeliveryError('Asset directory ownership/mode refused.')
            ancestry.append((folder, component, child, private))
            folder = child
        stream = handles.enter_context(Path(source).open('rb'))
        while chunk := stream.read(PIECE_SIZE):
            total += len(chunk)
            if total > MAX_ARCHIVE:
                raise DeliveryError('Archive exceeds the delivery bound.')
            digest.update(chunk)
            part_hash = hashlib.sha256(chunk).hexdigest()
            name = f'{len(parts)}-{part_hash}.part'
            flags = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
            try:
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | flags, 0o600, dir_fd=folder)
            except FileExistsError:
                fd = os.open(name, os.O_RDONLY | flags, dir_fd=folder)
                with os.fdopen(fd, 'rb') as retained:
                    info = os.fstat(retained.fileno())
                    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or
                        stat.S_IMODE(info.st_mode) != 0o600 or info.st_size != len(chunk) or
                        retained.read(len(chunk) + 1) != chunk):
                        raise DeliveryError('Existing immutable part differs.')
            else:
                with os.fdopen(fd, 'wb') as target:
                    target.write(chunk)
                    target.flush()
                    os.fsync(target.fileno())
                os.fsync(folder)
            parts.append(dict(index=len(parts), path='/' + '/'.join((*relative, name)), size=len(chunk), sha256=part_hash))
        if (digest.hexdigest(), total) != (descriptor['sha256'], descriptor['size']):
            raise DeliveryError('Archive hash or length differs from the qualified manifest.')
        for parent, component, child, private in ancestry:
            observed = os.stat(component, dir_fd=parent, follow_symlinks=False)
            retained = os.fstat(child)
            if (not os.path.samestat(observed, retained) or
                (private and (retained.st_uid != os.getuid() or stat.S_IMODE(retained.st_mode) != 0o700))):
                raise DeliveryError('Asset directory changed while staging.')
    return parts


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise DeliveryError('Cloudflare API redirect refused.')


class Cloudflare:
    def __init__(self, config, *, wrangler_auth=None):
        self._wrangler_auth = dict(wrangler_auth or {})
        if (set(self._wrangler_auth) - {'CLOUDFLARE_API_TOKEN'} or
                any(not isinstance(value, str) or not value or len(value) > 4096 or
                    any(ord(character) < 32 for character in value)
                    for value in self._wrangler_auth.values())):
            raise DeliveryError('Only explicit owner Wrangler API-token authentication is supported.')
        if os.getuid() == 0:
            raise DeliveryError('Run provider operations as the release owner, without elevated privileges.')
        self.config = config
        self.node = pinned_node()
        try:
            self.wrangler_entry = str(toolchain.verify_wrangler(config['wrangler']))
        except (OSError, ValueError):
            raise DeliveryError('The administrator-owned official Wrangler installation is unavailable.') from None
        # Keep HOME/auth unchanged. Never run login or activate a plan here.
        version = self.wrangler('--version').strip()
        if version != WRANGLER:
            raise DeliveryError('Wrangler must be exactly ' + WRANGLER + '.')
        try:
            auth = json.loads(self.wrangler('auth', 'token', '--json'))
        except (ValueError, UnicodeError):
            raise DeliveryError('Owner Wrangler authentication is unavailable.') from None
        if auth.get('type') not in ('oauth', 'api_token') or not isinstance(auth.get('token'), str):
            raise DeliveryError('Use the original owner OAuth/API-token authentication.')
        self._authorization = 'Bearer ' + auth['token']
        self._opener = urllib.request.build_opener(NoRedirect)

    def require_free(self):
        return require_free(self.config)

    def wrangler(self, *args, timeout=60):
        if args not in (('--version',), ('auth', 'token', '--json')):
            self.require_free()
            if len(args) != 3 or args[:2] != ('deploy', '--config'):
                raise DeliveryError('Only the fixed Free-only deployment command is supported.')
            configured = private_json(args[2])
            validate_deployment_config(configured)
            if configured != deployment_config(self.config, self):
                raise DeliveryError('Deployment bindings differ from the explicit private configuration.')
            state_path = outside_git(self.config['deployment_state'])
            if state_path.exists():
                audit_deployment(self, require_current_source=False)
            elif self.api('/workers/scripts/' + self.config['worker_name'] + '/deployments', allow_not_found=True) is not None:
                raise DeliveryError('Existing Worker has no known private deployment receipt.')
            self.preflight_retention(asset_inventory(self.config))
        # Capture all output: even upstream diagnostics must never expose credentials.
        environment = dict(toolchain.node_environment(), WRANGLER_SEND_METRICS='false', WRANGLER_SEND_ERROR_REPORTS='false',
                           WRANGLER_WRITE_LOGS='false', WRANGLER_LOG='log', WRANGLER_LOG_SANITIZE='true',
                           CLOUDFLARE_API_BASE_URL='https://api.cloudflare.com/client/v4',
                           CF_API_BASE_URL='https://api.cloudflare.com/client/v4', CI='true', NO_COLOR='1')
        if self.config.get('account_id'):
            environment['CLOUDFLARE_ACCOUNT_ID'] = self.config['account_id']
        # Scoped callers retain authentication outside the process environment.
        # Preflight Git/Node helpers never inherit this explicit capability.
        environment.update(self._wrangler_auth)
        try:
            toolchain.verify_node_binary(self.node, privileged=True)
            if str(toolchain.verify_wrangler(self.wrangler_entry)) != self.wrangler_entry:
                raise ValueError('Wrangler identity changed')
            result = subprocess.run([self.node, '--no-global-search-paths', self.wrangler_entry, *args], stdin=subprocess.DEVNULL,
                                    capture_output=True, env=environment, cwd=ROOT, timeout=timeout)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise DeliveryError('Pinned Wrangler operation failed or timed out.') from None
        if result.returncode:
            raise DeliveryError('Pinned Wrangler operation failed. Check owner authentication/resource permissions privately.')
        return result.stdout.decode('utf-8')

    def api(self, suffix, body=None, method=None, *, allow_not_found=False):
        effective_method = method or ('POST' if body is not None else 'GET')
        # D1 query uses POST even for SELECT; conservatively guard every POST.
        if effective_method != 'GET':
            self.require_free()
            allowed = (suffix == '/d1/database' and effective_method == 'POST' and isinstance(body, dict) and set(body) == {'name'}) or (suffix == '/workers/subdomain' and effective_method == 'PUT' and isinstance(body, dict) and set(body) == {'subdomain'}) or bool(re.fullmatch(r'/d1/database/[a-f0-9-]{36}/query', suffix) and effective_method == 'POST')
            if not allowed:
                raise DeliveryError('Provider mutation is outside the fixed Free-only interface.')
        module_read = (effective_method == 'GET' and body is None and re.fullmatch(
            r'/workers/workers/[a-z0-9][a-z0-9_-]{0,62}/versions/[a-f0-9-]{36}\?include=modules', suffix))
        if not suffix.startswith('/') or ('?' in suffix and not module_read) or '#' in suffix or '..' in suffix:
            raise DeliveryError('Invalid account API path.')
        account = self.config['account_id']
        if not isinstance(account, str) or not re.fullmatch(r'[a-f0-9]{32}', account):
            raise DeliveryError('Invalid explicit account identity.')
        url = 'https://api.cloudflare.com/client/v4/accounts/' + account + suffix
        payload = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=payload, method=method or ('POST' if body is not None else 'GET'),
            headers={'Authorization': self._authorization, 'Content-Type': 'application/json'})
        try:
            with self._opener.open(request, timeout=60) as response:
                data = response.read(2 * 1024 * 1024 + 1)
            if len(data) > 2 * 1024 * 1024:
                raise DeliveryError('Cloudflare response exceeded its size limit.')
            parsed = json.loads(data)
            if parsed.get('success') is not True:
                raise DeliveryError('Cloudflare refused the operation.')
            if effective_method=='GET' and parsed.get('result') is None:
                raise DeliveryError('Cloudflare resource inventory is unknown; no operation performed.')
            return parsed['result']
        except urllib.error.HTTPError as error:
            absent=False
            try:
                if (allow_not_found and error.code == 404 and effective_method == 'GET' and
                    (suffix=='/workers/subdomain' or re.fullmatch(r'/workers/scripts/[a-z0-9][a-z0-9_-]{0,62}/deployments', suffix))):
                    data=error.read(65537)
                    if len(data)<=65536:
                        missing=json.loads(data)
                        absent=(isinstance(missing,dict) and missing.get('success') is False and
                            isinstance(missing.get('errors'),list) and len(missing['errors'])==1 and
                            missing['errors'][0].get('code')==10007)
            except (ValueError,UnicodeError,AttributeError,TypeError):pass
            finally:error.close()
            if absent:return None
            raise DeliveryError('Cloudflare API operation failed; no public fallback was used.') from None
        except (urllib.error.URLError, ValueError, KeyError):
            raise DeliveryError('Cloudflare API operation failed; no public fallback was used.') from None

    def query(self, sql, params=()):
        result = self.api('/d1/database/' + self.config['database_id'] + '/query', {'sql': sql, 'params': list(params)})
        if not isinstance(result, list) or not result or any(row.get('success') is not True for row in result):
            raise DeliveryError('D1 query failed.')
        return result[-1].get('results', [])

    def zone_routes(self):
        # Zone routes are distinct from account custom domains. Enumerate every
        # account-owned zone, including pages, and refuse any route to this Worker.
        routes = []
        for page in range(1, 101):
            query = urllib.parse.urlencode({'account.id': self.config['account_id'], 'per_page': 50, 'page': page})
            zones = self._zone_read('/zones?' + query)
            if not isinstance(zones, list) or len(zones) > 50:
                raise DeliveryError('Account zone inventory is unknown.')
            for zone in zones:
                identity = zone.get('id')
                if not isinstance(identity, str) or not re.fullmatch(r'[a-f0-9]{32}', identity):
                    raise DeliveryError('Invalid account zone identity.')
                found = self._zone_read('/zones/' + identity + '/workers/routes')
                if not isinstance(found, list): raise DeliveryError('Zone route inventory is unknown.')
                routes.extend(found)
            if len(zones) < 50: return routes
        raise DeliveryError('Zone inventory exceeds the bounded read limit.')

    def _zone_read(self, suffix):
        # Internal read-only path; account/auth stay unchanged and redirects deny.
        listing = '/zones?' + urllib.parse.urlencode({'account.id': self.config['account_id'], 'per_page': 50, 'page': 1})
        if not (re.fullmatch(r'/zones/[a-f0-9]{32}/workers/routes', suffix) or
                re.fullmatch(re.escape(listing.rsplit('=', 1)[0]) + r'=(?:[1-9][0-9]?|100)', suffix)):
            raise DeliveryError('Unsupported zone read.')
        request = urllib.request.Request('https://api.cloudflare.com/client/v4' + suffix,
                                         headers={'Authorization': self._authorization})
        try:
            with self._opener.open(request, timeout=30) as response:
                data = response.read(2 * 1024 * 1024 + 1)
            if len(data) > 2 * 1024 * 1024: raise DeliveryError('Zone inventory too large.')
            result = json.loads(data)
            if result.get('success') is not True: raise DeliveryError('Zone inventory unavailable.')
            return result['result']
        except (OSError, ValueError, KeyError):
            raise DeliveryError('Fail-closed route readback is unavailable.') from None

    def create_database(self, name):
        self.require_free()
        if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', name): raise DeliveryError('Invalid database name.')
        databases = self.api('/d1/database')
        if not isinstance(databases, list) or len(databases) >= 10 or any(d.get('name') == name for d in databases):
            raise DeliveryError('Explicit new Free database requires known available capacity and a unique name.')
        return self.api('/d1/database', {'name': name}, 'POST')

    def create_subdomain(self, name):
        self.require_free()
        if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', name): raise DeliveryError('Invalid subdomain.')
        current = self.api('/workers/subdomain',allow_not_found=True)
        if current is not None:
            raise DeliveryError('Existing subdomain must be retained; no replacement is supported.')
        created=self.api('/workers/subdomain', {'subdomain': name}, 'PUT')
        if not isinstance(created,dict) or created.get('subdomain')!=name:
            raise DeliveryError('Created subdomain readback differs; inspect privately before continuing.')
        return created

    def privacy(self):
        return audit_deployment(self)

    def preflight_retention(self, inventory):
        path = outside_git(self.config['deployment_state'])
        if path.exists():
            prior = private_json(path)
            for name, details in prior['assets'].items():
                if inventory.get(name) != details:
                    raise DeliveryError('Deployment would drop/change retained parts.')
        for row in self.query('SELECT parts_json FROM artifact_parts'):
            for part in json.loads(row['parts_json']):
                if inventory.get(part['path']) != {k: part[k] for k in ('sha256', 'size')}:
                    raise DeliveryError('Deployment would drop/change published or rollback parts.')

    def deploy(self):
        self.require_free()
        configured = deployment_config(self.config, self)
        modules = worker_source_hashes()
        inventory = asset_inventory(self.config)
        state_path = outside_git(self.config['deployment_state'])
        prior = private_json(state_path) if state_path.exists() else None
        if not prior:
            existing = self.api('/workers/scripts/' + self.config['worker_name'] + '/deployments', allow_not_found=True)
            if existing is not None:
                raise DeliveryError('An existing Worker without its private deployment receipt must be investigated; no replacement performed.')
        if prior:
            audit_deployment(self, require_current_source=False)
            for path, details in prior['assets'].items():
                if inventory.get(path) != details:
                    raise DeliveryError('Deployment would drop/change previously retained parts; no deletion is supported.')
        # Additive schema only, after all local/config/Free gates.
        self.query((ROOT / 'delivery/schema.sql').read_text())
        for row in self.query('SELECT parts_json FROM artifact_parts'):
            for part in json.loads(row['parts_json']):
                if inventory.get(part['path']) != {k: part[k] for k in ('sha256', 'size')}:
                    raise DeliveryError('Deployment would drop/change published or rollback parts.')
        with tempfile.TemporaryDirectory(prefix='monitor-deploy-') as folder:
            filename = Path(folder).resolve() / 'wrangler.json'
            private_write(filename, configured)
            output = self.wrangler('deploy', '--config', str(filename), timeout=300)
        match = re.search(r'Current Version ID:\s*([a-f0-9-]{36})', output)
        if not match:
            raise DeliveryError('Deployment version identity unavailable; publication blocked pending private investigation.')
        version_id = match[1]
        base = '/workers/scripts/' + self.config['worker_name']
        deployed = current_version(self.api(base + '/deployments'))
        if deployed != version_id:
            raise DeliveryError('Deployment is not the single reviewed version at 100 percent.')
        etag = provider_version_etag(self, base, version_id)
        state = dict(schema=DEPLOYMENT_SCHEMA, account_id=self.config['account_id'],
                     worker_name=self.config['worker_name'], version_id=version_id, etag=etag,
                     module_sha256=modules, config=configured, assets=inventory)
        # A failed source, binding or routing check must preserve the last receipt.
        audit_deployment(self, pending_state=state)
        # Atomically replace only this tool's explicit state file, never asset data.
        private_write(state_path, state, replace=True)

    def readback(self, release_id, descriptor, kind):
        # Owner-only short-lived qualification grant stays in process memory.
        self.require_free()
        token, grant = secrets.token_urlsafe(32), str(uuid.uuid4())
        now = int(time.time())
        identity = dict(grant_id=grant, token_hash=hashlib.sha256(token.encode()).hexdigest(),
                        label='publication-readback', is_owner=1, expires_at=now + 600, created_at=now)
        parent = private_directory(Path(self.config['deployment_state']).parent)
        intent = parent / ('readback-grant-' + grant + '.json')
        private_write(intent, dict(schema='shadow-sync/readback-grant/v1', app_id=APP,
                                  binding=access_binding(self.config), grant=identity))
        try:
            self.query('INSERT INTO grants(grant_id,token_hash,label,is_owner,expires_at,created_at) VALUES(?,?,?,?,?,?)',
                       tuple(identity.values()))
            self.query('INSERT INTO entitlements(grant_id,app_id,channel) VALUES(?,?,?)', (grant, APP, 'qualification'))
            path = f'/v1/apps/{APP}/releases/{release_id}/{kind}'
            headers = {'Authorization': 'Bearer ' + token, 'User-Agent': 'ShadowSync-Delivery/1.0'}
            digest, size = hashlib.sha256(), 0
            deadline = time.monotonic() + 300
            try:
                request = urllib.request.Request(self.config['origin'] + path + '/parts', headers=headers)
                with self._opener.open(request, timeout=30) as response:
                    raw = response.read(WIRE_LIMIT + 1)
                    if response.status != 200 or len(raw) > WIRE_LIMIT:
                        raise DeliveryError('Private remote readback failed.')
                ordered = validate_piece_descriptor(raw, release_id, kind, descriptor)
                for part in ordered:
                    if time.monotonic() >= deadline:
                        raise DeliveryError('Private remote readback deadline exceeded.')
                    request = urllib.request.Request(self.config['origin'] + path + '/parts/' + str(part['index']), headers=headers)
                    part_hash, part_size = hashlib.sha256(), 0
                    with self._opener.open(request, timeout=min(30, deadline - time.monotonic())) as response:
                        if response.status != 200 or response.headers.get('Content-Length') != str(part['size']):
                            raise DeliveryError('Private piece readback failed.')
                        while chunk := response.read(65536):
                            if time.monotonic() >= deadline:
                                raise DeliveryError('Private remote readback deadline exceeded.')
                            part_size += len(chunk)
                            if part_size > part['size']:
                                raise DeliveryError('Remote piece length exceeded.')
                            part_hash.update(chunk); digest.update(chunk); size += len(chunk)
                    if (part_size, part_hash.hexdigest()) != (part['size'], part['sha256']):
                        raise DeliveryError('Remote piece hash/length mismatch.')
            except (OSError, urllib.error.URLError):
                raise DeliveryError('Private remote readback failed; channel was not advanced.') from None
            if (digest.hexdigest(), size) != (descriptor['sha256'], descriptor['size']):
                raise DeliveryError('Remote readback hash/length mismatch; channel was not advanced.')
        finally:
            recover_readback_grant(self, intent)


def recover_readback_grant(api, path):
    path = outside_git(path)
    private_directory(path.parent)
    record, _ = access_custody(path)
    if (set(record) != {'schema', 'app_id', 'binding', 'grant'}
            or record['schema'] != 'shadow-sync/readback-grant/v1'
            or record['app_id'] != APP or record['binding'] != access_binding(api.config)
            or path.parent != Path(api.config['deployment_state']).parent):
        raise DeliveryError('Readback grant attempt does not match the configured private provider.')
    grant = record['grant']
    if (set(grant) != {'grant_id','token_hash','label','is_owner','expires_at','created_at'}
            or str(uuid.UUID(grant['grant_id'])) != grant['grant_id']
            or path.name != 'readback-grant-' + grant['grant_id'] + '.json'
            or grant['label'] != 'publication-readback' or type(grant['is_owner']) is not int or grant['is_owner'] != 1
            or not re.fullmatch(r'[a-f0-9]{64}', grant['token_hash'])
            or type(grant['created_at']) is not int or type(grant['expires_at']) is not int
            or not 0 < grant['created_at'] < grant['expires_at'] <= 253402300799
            or grant['expires_at'] - grant['created_at'] != 600):
        raise DeliveryError('Readback grant attempt is invalid.')
    api.require_free()

    def observe():
        rows = api.query('''SELECT g.*,e.app_id,e.channel FROM grants g
            LEFT JOIN entitlements e ON e.grant_id=g.grant_id WHERE g.grant_id=?''', (grant['grant_id'],))
        if (len(rows) != 1 or any(rows[0].get(k) != v for k, v in grant.items())
                or (rows[0]['app_id'], rows[0]['channel']) not in ((None, None), (APP, 'qualification'))):
            raise DeliveryError('Readback grant could not be verified. Retain its attempt for recovery.')
        revoked = rows[0]['revoked_at']
        if revoked is not None and (type(revoked) is not int or not grant['created_at'] <= revoked <= 253402300799):
            raise DeliveryError('Readback grant revocation time is invalid.')
        return revoked

    revoked = observe()
    if revoked is None:
        try:
            api.query('''UPDATE grants SET revoked_at=? WHERE grant_id=? AND token_hash=?
                AND label=? AND is_owner=? AND expires_at=? AND created_at=? AND revoked_at IS NULL
                AND (SELECT COUNT(*) FROM entitlements e WHERE e.grant_id=grants.grant_id)<=1
                AND NOT EXISTS (SELECT 1 FROM entitlements e WHERE e.grant_id=grants.grant_id
                  AND (e.app_id!=? OR e.channel!='qualification'))''',
                (int(time.time()), grant['grant_id'], grant['token_hash'], grant['label'], grant['is_owner'],
                 grant['expires_at'], grant['created_at'], APP))
        except (DeliveryError, OSError):
            # An ambiguous write is resolved by observation, never by a retry in this call.
            pass
        revoked = observe()
    if revoked is None:
        raise DeliveryError('Readback revocation is unverified. Keep the private attempt and use recover-readback-grant.')
    # The durable intent remains available if a process stops after the provider update.
    return dict(grant_id=grant['grant_id'], revoked_at=revoked)


def worker_source_hashes():
    return {name: hashlib.sha256((ROOT / 'delivery' / name).read_bytes()).hexdigest()
            for name in WORKER_MODULES}


def provider_version_etag(api, base, version):
    detail = api.api(base + '/versions/' + version)
    try:
        etag = detail['resources']['script']['etag']
        if detail['id'] == version and isinstance(etag, str) and 0 < len(etag) <= 256:
            return etag
    except (KeyError, TypeError):
        pass
    raise DeliveryError('Provider version source identity unavailable.')


def verify_worker_modules(api, version, expected):
    worker = api.config['worker_name']
    detail = api.api(f'/workers/workers/{worker}/versions/{version}?include=modules')
    try:
        modules = detail['modules']
        if (detail['id'] != version or detail['main_module'] != WORKER_MODULES[0] or
                not isinstance(modules, list) or len(modules) != len(WORKER_MODULES)):
            raise ValueError('version identity or module inventory')
        observed = {}
        for module in modules:
            name = module['name']
            if (name not in WORKER_MODULES or name in observed or
                    module['content_type'] != 'application/javascript+module'):
                raise ValueError('module identity')
            body = base64.b64decode(module['content_base64'], validate=True)
            observed[name] = hashlib.sha256(body).hexdigest()
        if observed == expected:
            return
    except (KeyError, TypeError, ValueError):
        pass
    raise DeliveryError('Deployed Worker module bytes do not match the reviewed release source.')


def validate_piece_descriptor(raw, release_id, kind, descriptor):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate')
            result[key] = value
        return result
    try:
        if len(raw) > WIRE_LIMIT:
            raise ValueError('size')
        value = json.loads(raw, object_pairs_hook=unique)
        expected = dict(schema='shadow-sync/artifact-parts/v2', app_id=APP,
                        release_id=release_id, kind=kind, artifact_sha256=descriptor['sha256'],
                        artifact_size=descriptor['size'], part_size=PIECE_SIZE)
        if (set(value) != set(expected) | {'parts'} or any(type(value[k]) is not type(v) or value[k] != v for k, v in expected.items()) or
                not isinstance(value['parts'], list) or not 1 <= len(value['parts']) <= MAX_PIECES or
                len(value['parts']) != (descriptor['size'] + PIECE_SIZE - 1) // PIECE_SIZE):
            raise ValueError('fields')
        total = 0
        for index, part in enumerate(value['parts']):
            if (not isinstance(part, dict) or set(part) != {'index', 'size', 'sha256'} or
                    type(part['index']) is not int or part['index'] != index or
                    type(part['size']) is not int or not 1 <= part['size'] <= PIECE_SIZE or
                    (index < len(value['parts']) - 1 and part['size'] != PIECE_SIZE) or
                    not isinstance(part['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', part['sha256'])):
                raise ValueError('part')
            total += part['size']
        if total != descriptor['size']:
            raise ValueError('total')
        return value['parts']
    except (ValueError, TypeError, KeyError, UnicodeError):
        raise DeliveryError('Invalid bound private piece descriptor.') from None


def current_version(deployments):
    entries = deployments.get('deployments') if isinstance(deployments, dict) else None
    if not isinstance(entries, list) or not entries:
        raise DeliveryError('Current active deployment is unknown.')
    versions = entries[0].get('versions')
    # Include 0-percent versions: caller version overrides can select them.
    if not isinstance(versions, list) or len(versions) != 1 or versions[0].get('percentage') != 100:
        raise DeliveryError('Require exactly one reviewed active version at 100 percent, including zero-percent entries.')
    version = versions[0].get('version_id')
    if not isinstance(version, str) or not re.fullmatch(r'[a-f0-9-]{36}', version):
        raise DeliveryError('Invalid deployed version identity.')
    return version


def audit_deployment(api, require_current_source=True, *, pending_state=None):
    config = api.config
    require_free(config)
    state = private_json(config['deployment_state']) if pending_state is None else pending_state
    expected = deployment_config(config, api)
    legacy = state.get('schema') == LEGACY_DEPLOYMENT_SCHEMA
    if legacy and require_current_source:
        raise DeliveryError('Publication requires a deployment receipt with verified Worker modules.')
    # Old receipts can protect retained assets during an upgrade. They cannot authorize a channel write.
    observed_config = {key: value for key, value in expected.items() if key not in WORKER_PACKAGING} if legacy else expected
    modules = state.get('module_sha256')
    if (state.get('schema') not in (DEPLOYMENT_SCHEMA, LEGACY_DEPLOYMENT_SCHEMA) or
            state.get('account_id') != config['account_id'] or
            state.get('worker_name') != config['worker_name'] or state.get('config') != observed_config or
            (require_current_source and modules != worker_source_hashes())):
        raise DeliveryError('Deployment does not match this exact reviewed source/configuration.')
    base = '/workers/scripts/' + config['worker_name']
    version = current_version(api.api(base + '/deployments'))
    if version != state.get('version_id'):
        raise DeliveryError('Unrecognized active version; publication blocked.')
    if provider_version_etag(api, base, version) != state.get('etag'):
        raise DeliveryError('Active version source readback mismatch.')
    if not legacy:
        verify_worker_modules(api, version, modules)
    subdomain = api.api(base + '/subdomain')
    if subdomain.get('enabled') is not True or subdomain.get('previews_enabled') is not False:
        raise DeliveryError('Default/preview route configuration is unsafe or unknown.')
    # The supported workers.dev-only profile cannot have custom routes/domains.
    domains = api.api('/workers/domains')
    if not isinstance(domains, list) or any(not isinstance(d, dict) or
            not isinstance(d.get('service'), str) or not d['service'] or
            d['service'] == config['worker_name'] for d in domains):
        raise DeliveryError('Custom routes/domains require separately qualified fail-closed routing.')
    routes = api.zone_routes()
    if not isinstance(routes, list) or any(not isinstance(r, dict) or 'script' not in r or
            (r['script'] is not None and (not isinstance(r['script'], str) or not r['script'])) or
            r['script'] == config['worker_name'] for r in routes):
        raise DeliveryError('Any custom zone route requires separately qualified fail-closed routing.')
    if current_version(api.api(base + '/deployments')) != version:
        raise DeliveryError('Active version changed during Worker module readback.')
    return state


def file_digest(path):
    digest, size = hashlib.sha256(), 0
    with Path(path).open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_ARCHIVE:
                raise DeliveryError('Archive exceeds the 512-MiB delivery bound.')
            digest.update(chunk)
    return digest.hexdigest(), size


def pinned_node():
    try:
        return str(toolchain.node(privileged=True))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        raise DeliveryError('The pinned official Node runtime is unavailable.') from None


def validate_manifest(value):
    # Run the actual wire validator, not a second divergent Python implementation.
    binary = pinned_node()
    try:
        script = "import {manifest} from './delivery/contract.mjs'; let s=''; for await(const c of process.stdin)s+=c; manifest(JSON.parse(s));"
        result = subprocess.run([binary, '--input-type=module', '-e', script], input=json.dumps(value).encode(),
                                capture_output=True, cwd=ROOT, timeout=10, env=toolchain.node_environment())
        if result.returncode:
            raise DeliveryError('Invalid release manifest.')
    except (OSError, subprocess.SubprocessError):
        raise DeliveryError('Pinned Node contract validation failed.') from None
    return value


def validate_receipt(manifest, receipt, stable=False):
    expected = {'schema': 'shadow-sync/qualification/v1', 'app_id': APP,
        'qualification_id': manifest['qualification_id'], 'source_revision': manifest['source_revision'],
        'build': manifest['build'], 'archive_sha256': manifest['archive']['sha256'],
        'archive_size': manifest['archive']['size'], 'first_install_sha256': manifest['first_install']['sha256'],
        'first_install_size': manifest['first_install']['size']}
    if any(receipt.get(k) != v for k, v in expected.items()) or any(receipt.get('checks', {}).get(k) is not True for k in CHECKS):
        raise DeliveryError('Qualification receipt does not bind every required gate to these exact artifacts.')
    if stable and any(receipt.get('checks', {}).get(check) is not True for check in FRIEND_CHECKS):
        raise DeliveryError('Friend distribution requires exact-artifact installation, recovery, migration and operator acceptance evidence.')


def access_scope(channel, owner):
    if channel not in ('stable', 'qualification') or type(owner) is not bool or (channel == 'qualification' and not owner):
        raise DeliveryError('Select the original channel and owner authority; qualification requires owner access.')


def access_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def access_stat(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def access_parent(info):
    # Creating a later step marker legitimately changes directory size/timestamps.
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid)


def access_custody(path):
    """Read exact bytes from a stable private inode, retaining its named custody."""
    path = outside_git(path)
    directory = path.parent.stat(follow_symlinks=False)
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.getuid() or
            stat.S_IMODE(directory.st_mode) != 0o700):
        raise DeliveryError('Access custody requires an owner-private mode-0700 directory.')
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        # Absence is only the failed initial open. An error after a descriptor
        # has been acquired must never erase knowledge of an attempted write.
        if access_parent(path.parent.stat(follow_symlinks=False)) != access_parent(directory):
            raise DeliveryError('Private custody changed during observation.') from None
        raise _AccessFileAbsent('Private custody name is absent.') from None
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise DeliveryError('Access custody requires an unlinked owner-owned mode-0600 regular file.')
        data = stream.read(65537)
        if len(data) > 65536:
            raise DeliveryError('Access custody record exceeds its bound.')
        if (len(data) != info.st_size or access_stat(info) != access_stat(os.fstat(stream.fileno())) or
                access_stat(info) != access_stat(path.stat(follow_symlinks=False)) or
                access_parent(directory) != access_parent(path.parent.stat(follow_symlinks=False))):
            raise DeliveryError('Private custody changed during observation.')
    return json.loads(data), dict(identity=access_stat(info), directory=access_parent(directory),
                                 sha256=hashlib.sha256(data).hexdigest())


def access_file(path, value=None):
    """Exclusive durable writes; failed/partial files are retained for private diagnosis."""
    if value is None:
        value, custody = access_custody(path)
        return value, list(custody['identity'][:2])
    with private_write_parent(path, owner_only=True) as (path, directory_fd, expected):
        flags = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
        fd = os.open(path.name, flags, 0o600, dir_fd=directory_fd)
        with os.fdopen(fd, 'wb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise DeliveryError('Access custody requires an unlinked owner-owned mode-0600 regular file.')
            stream.write(access_bytes(value))
            stream.flush()
            os.fsync(stream.fileno())
            os.fsync(directory_fd)
            retained = os.fstat(stream.fileno())
            observed = os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False)
            if (access_stat(retained) != access_stat(observed) or
                access_stat(retained) != access_stat(path.stat(follow_symlinks=False))):
                raise DeliveryError('Private access custody changed during creation.')
            require_named_parent(path, directory_fd, expected)
    return value, [info.st_dev, info.st_ino]


def access_binding(config):
    return {key: config[key] for key in ('origin', 'account_id', 'database_id', 'worker_name')}


def access_rows(api, grant_id=None):
    # Do not return tokens, token hashes, labels or private configuration to operators.
    sql = '''SELECT g.grant_id,g.is_owner,g.expires_at,g.revoked_at,e.channel,
        (SELECT COUNT(*) FROM entitlements x WHERE x.grant_id=g.grant_id) AS scopes
        FROM grants g JOIN entitlements e ON e.grant_id=g.grant_id WHERE e.app_id=?'''
    params = [APP]
    if grant_id is not None:
        sql += ' AND g.grant_id=?'
        params.append(str(uuid.UUID(str(grant_id))))
    rows = api.query(sql + ' ORDER BY g.grant_id,e.channel', params)
    now = int(time.time())
    for row in rows:
        row['status'] = ('scope-conflict' if row.pop('scopes') != 1 else 'revoked' if row['revoked_at'] is not None
                         else 'expired' if row['expires_at'] <= now else 'active')
    return rows


def access_original(api, grant_id, channel, owner):
    access_scope(channel, owner)
    rows = api.query('''SELECT g.* FROM grants g WHERE g.grant_id=? AND g.is_owner=?
        AND EXISTS(SELECT 1 FROM entitlements e WHERE e.grant_id=g.grant_id AND e.app_id=? AND e.channel=?)
        AND (SELECT COUNT(*) FROM entitlements e WHERE e.grant_id=g.grant_id)=1''',
        (str(uuid.UUID(str(grant_id))), int(owner), APP, channel))
    if len(rows) != 1:
        raise DeliveryError('Grant does not have exactly the requested application/channel/owner scope.')
    return rows[0]


def change_grant(api, grant_id, channel='stable', owner=False, expires_at=None):
    api.require_free()
    original = access_original(api, grant_id, channel, owner)
    if expires_at is not None and (type(expires_at) is not int or not 0 < expires_at <= original['expires_at']):
        raise DeliveryError('Expiry can only be shortened to a positive Unix timestamp.')
    column = 'revoked_at' if expires_at is None else 'expires_at'
    value = int(time.time()) if expires_at is None else expires_at
    if (expires_at is None and original['revoked_at'] is not None) or (expires_at == original['expires_at']):
        current = access_rows(api, grant_id)
        if (len(current) != 1 or current[0]['status'] == 'scope-conflict' or
            current[0]['channel'] != channel or current[0]['is_owner'] != int(owner)):
            raise DeliveryError('Grant observation changed; inspect status before any further action.')
        return current[0]
    api.require_free()
    rows = api.query('UPDATE grants SET ' + column + '''=? WHERE grant_id=? AND token_hash=? AND is_owner=?
        AND expires_at=? AND revoked_at IS ?
        AND EXISTS(SELECT 1 FROM entitlements e WHERE e.grant_id=grants.grant_id AND e.app_id=? AND e.channel=?)
        AND (SELECT COUNT(*) FROM entitlements e WHERE e.grant_id=grants.grant_id)=1 RETURNING grant_id''',
        (value, original['grant_id'], original['token_hash'], original['is_owner'], original['expires_at'],
         original['revoked_at'], APP, channel))
    if len(rows) != 1:
        raise DeliveryError('Grant changed during mutation; inspect status before any further action.')
    current = access_rows(api, grant_id)
    if (len(current) != 1 or current[0][column] != value or current[0]['status'] == 'scope-conflict' or
        current[0]['channel'] != channel or current[0]['is_owner'] != int(owner)):
        raise DeliveryError('Grant mutation outcome is unknown; inspect status without replaying the write.')
    return current[0]


def create_grant(api, config, label, output, expires_at, owner=False, channel='stable', replaces=None):
    api.require_free()
    access_scope(channel, owner)
    now = int(time.time())
    if (not re.fullmatch(r'[A-Za-z0-9._-]{1,64}', label) or type(expires_at) is not int or
        not now < expires_at <= 253402300799):
        raise DeliveryError('Use an opaque label and a finite future expiry.')
    binding = access_binding(config)
    original = None if replaces is None else access_original(api, replaces, channel, owner)
    if original and (original['revoked_at'] is not None or original['expires_at'] <= now or expires_at > original['expires_at']):
        raise DeliveryError('Replace only active access without extending its original expiry or authority.')
    output = outside_git(output)
    attempt = Path(str(output) + '.attempt.json')
    if output.exists() or attempt.exists():
        raise DeliveryError('Use new access and attempt paths; recover the existing attempt instead of overwriting it.')
    grant, token = str(uuid.uuid4()), secrets.token_urlsafe(32)
    access = dict(schema='shadow-sync/access/v1', app_id=APP, origin=config['origin'], token=token)
    _, identity = access_file(output, access)
    intent = dict(schema='shadow-sync/access-attempt/v1', attempt_id=str(uuid.uuid4()), app_id=APP,
        binding=binding, output=str(output), file_identity=identity,
        access_sha256=hashlib.sha256(json.dumps(access, sort_keys=True).encode()).hexdigest(),
        grant=dict(grant_id=grant, token_hash=hashlib.sha256(token.encode()).hexdigest(), label=label,
                   is_owner=int(owner), expires_at=expires_at, created_at=now, revoked_at=None),
        channel=channel, original=original)
    access_file(attempt, intent)
    result = recover_grant(api, config, attempt, complete=True)
    if result['status'] != 'complete':
        raise DeliveryError('Access creation remains pending. Retain access/attempt files and inspect recover-grant.')
    return grant


def recover_grant(api, config, attempt, complete=False):
    """Observe first; explicit completion can issue each durable intent at most once."""
    import fcntl
    attempt = outside_git(attempt)
    descriptor = os.open(attempt, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise DeliveryError('Attempt must be a private regular file.')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        intent, attempt_custody = access_custody(attempt)
        if attempt_custody['identity'] != access_stat(os.fstat(lock.fileno())):
            raise DeliveryError('Attempt file changed during recovery.')
        required = {'schema','attempt_id','app_id','binding','output','file_identity','access_sha256','grant','channel','original'}
        if (set(intent) != required or intent['schema'] != 'shadow-sync/access-attempt/v1' or
            intent['app_id'] != APP or intent['binding'] != access_binding(config)):
            raise DeliveryError('Attempt identity or provider binding differs; no recovery write performed.')
        str(uuid.UUID(intent['attempt_id']))
        grant = intent['grant']
        if (set(grant) != {'grant_id','token_hash','label','is_owner','expires_at','created_at','revoked_at'} or
            grant['is_owner'] not in (0,1) or type(grant['expires_at']) is not int or
            not grant['created_at'] < grant['expires_at'] <= 253402300799 or grant['revoked_at'] is not None):
            raise DeliveryError('Invalid finite grant attempt.')
        str(uuid.UUID(grant['grant_id']))
        access_scope(intent['channel'], bool(grant['is_owner']))
        access, output_custody = access_custody(intent['output'])
        file_identity = list(output_custody['identity'][:2])
        if (attempt != Path(intent['output'] + '.attempt.json') or file_identity != intent['file_identity'] or
            set(access) != {'schema','app_id','origin','token'} or access['schema'] != 'shadow-sync/access/v1' or
            access['app_id'] != APP or access['origin'] != config['origin'] or
            hashlib.sha256(json.dumps(access, sort_keys=True).encode()).hexdigest() != intent['access_sha256'] or
            hashlib.sha256(access['token'].encode()).hexdigest() != grant['token_hash'] or
            output_custody['sha256'] != hashlib.sha256(access_bytes(access)).hexdigest() or
            attempt_custody['sha256'] != hashlib.sha256(access_bytes(intent)).hexdigest()):
            raise DeliveryError('Private access file identity or bytes changed; no recovery write performed.')
        original = intent['original']
        if original and (original['is_owner'] != grant['is_owner'] or original['expires_at'] < grant['expires_at'] or
                         original['revoked_at'] is not None or original['grant_id'] == grant['grant_id']):
            raise DeliveryError('Replacement attempt widens or changes original authority.')
        intent_digest = hashlib.sha256(json.dumps(intent, sort_keys=True).encode()).hexdigest()
        marker_paths = {step: Path(str(attempt) + '.' + step) for step in ('grant', 'entitlement', 'revoke')}
        marker_values = {step: dict(attempt_id=intent['attempt_id'], intent_sha256=intent_digest, step=step)
                         for step in marker_paths}
        def observe_marker(step):
            try:
                value, custody = access_custody(marker_paths[step])
            except _AccessFileAbsent:
                return None
            except (OSError, ValueError):
                raise DeliveryError('Attempt step custody is unavailable; preserve the evidence.') from None
            if (value != marker_values[step] or
                    custody['sha256'] != hashlib.sha256(access_bytes(marker_values[step])).hexdigest()):
                raise DeliveryError('Attempt step identity mismatch; preserve the evidence.')
            return value, custody
        # Remember the original observation. A marker that was already seen is
        # never reclassified as an unattempted step if its name later disappears.
        markers = {step: observe_marker(step) for step in marker_paths}
        def verify_custody():
            if (access_custody(attempt) != (intent, attempt_custody) or
                    access_custody(intent['output']) != (access, output_custody)):
                raise DeliveryError('Private custody changed during recovery.')
            for step, observed in markers.items():
                if observe_marker(step) != observed:
                    raise DeliveryError('Attempt step custody changed during recovery; preserve the evidence.')
            # Bracket both reads: keep the held lock bound to the original named inode,
            # and refuse observed changes made while the other file was being read.
            for path, custody in ((attempt, attempt_custody), (Path(intent['output']), output_custody)):
                if (access_stat(path.stat(follow_symlinks=False)) != custody['identity'] or
                        access_parent(path.parent.stat(follow_symlinks=False)) != custody['directory']):
                    raise DeliveryError('Private custody changed during recovery.')
            if access_stat(os.fstat(lock.fileno())) != attempt_custody['identity']:
                raise DeliveryError('Attempt lock custody changed during recovery.')
            # Bracket marker reads as well: a later marker/file observation may
            # not conceal replacement or deletion of an earlier observed name.
            for step, observed in markers.items():
                try:
                    named = marker_paths[step].stat(follow_symlinks=False)
                except FileNotFoundError:
                    if observed is None:
                        continue
                    raise DeliveryError('Attempt step custody changed during recovery; preserve the evidence.') from None
                if (observed is None or access_stat(named) != observed[1]['identity'] or
                        access_parent(marker_paths[step].parent.stat(follow_symlinks=False)) != observed[1]['directory']):
                    raise DeliveryError('Attempt step custody changed during recovery; preserve the evidence.')
        pending = dict(grant_id=grant['grant_id'], status='pending', stage='grant')
        # Immutable write-ahead markers never authorize replay, including after process death.
        def issue(step, sql, params):
            verify_custody()
            if markers[step] is not None:
                return False
            if not complete:
                return False
            api.require_free()
            # Revalidate custody immediately before every new provider effect.
            verify_custody()
            _, created_identity = access_file(marker_paths[step], marker_values[step])
            observed = observe_marker(step)
            if observed is None or list(observed[1]['identity'][:2]) != created_identity:
                raise DeliveryError('New attempt step custody changed before publication; preserve the evidence.')
            markers[step] = observed
            verify_custody()
            try:
                api.query(sql, params)
            except Exception:
                # Do not compensate/replay: the request may have committed.
                raise DeliveryError('Provider write outcome is unknown. Retain all files; run recover-grant to observe it.') from None
            return True
        rows = api.query('SELECT * FROM grants WHERE grant_id=?', (grant['grant_id'],))
        if not rows:
            if int(time.time()) >= grant['expires_at']:
                return dict(pending, stage='expired-before-creation')
            if not issue('grant', 'INSERT INTO grants(grant_id,token_hash,label,is_owner,expires_at,created_at) VALUES(?,?,?,?,?,?)',
                         tuple(grant[k] for k in ('grant_id','token_hash','label','is_owner','expires_at','created_at'))):
                return pending
            rows = api.query('SELECT * FROM grants WHERE grant_id=?', (grant['grant_id'],))
        if rows != [grant]:
            raise DeliveryError('Grant state differs from the exact retained attempt; no recovery write performed.')
        scopes = api.query('SELECT app_id,channel FROM entitlements WHERE grant_id=?', (grant['grant_id'],))
        expected_scope = [dict(app_id=APP, channel=intent['channel'])]
        if not scopes:
            if int(time.time()) >= grant['expires_at']:
                return dict(pending, stage='expired-before-entitlement')
            if not issue('entitlement', '''INSERT INTO entitlements(grant_id,app_id,channel)
                SELECT grant_id,?,? FROM grants WHERE grant_id=? AND token_hash=? AND is_owner=? AND expires_at=? AND revoked_at IS NULL
                AND NOT EXISTS(SELECT 1 FROM entitlements WHERE grant_id=?)''',
                (APP, intent['channel'], grant['grant_id'], grant['token_hash'], grant['is_owner'], grant['expires_at'], grant['grant_id'])):
                return dict(pending, stage='entitlement')
            scopes = api.query('SELECT app_id,channel FROM entitlements WHERE grant_id=?', (grant['grant_id'],))
        if scopes != expected_scope:
            raise DeliveryError('Grant entitlement differs from the exact retained attempt.')
        if original:
            current = access_original(api, original['grant_id'], intent['channel'], bool(original['is_owner']))
            if any(current[k] != v for k,v in original.items() if k != 'revoked_at'):
                raise DeliveryError('Original grant identity changed; no replacement write performed.')
            if current['revoked_at'] is None:
                if int(time.time()) >= grant['expires_at']:
                    return dict(pending, stage='replacement-expired')
                if not issue('revoke', '''UPDATE grants SET revoked_at=? WHERE grant_id=? AND token_hash=? AND is_owner=? AND expires_at=?
                    AND revoked_at IS NULL AND EXISTS(SELECT 1 FROM entitlements e WHERE e.grant_id=grants.grant_id AND e.app_id=? AND e.channel=?)
                    AND (SELECT COUNT(*) FROM entitlements e WHERE e.grant_id=grants.grant_id)=1
                    AND EXISTS(SELECT 1 FROM grants n JOIN entitlements ne ON ne.grant_id=n.grant_id
                        WHERE n.grant_id=? AND n.token_hash=? AND n.is_owner=? AND n.expires_at=? AND n.expires_at>?
                        AND n.revoked_at IS NULL AND ne.app_id=? AND ne.channel=?
                        AND (SELECT COUNT(*) FROM entitlements nx WHERE nx.grant_id=n.grant_id)=1)''',
                    (int(time.time()), original['grant_id'], original['token_hash'], original['is_owner'], original['expires_at'], APP, intent['channel'], grant['grant_id'], grant['token_hash'], grant['is_owner'], grant['expires_at'], int(time.time()), APP, intent['channel'])):
                    return dict(pending, stage='revoke-original')
                current = access_original(api, original['grant_id'], intent['channel'], bool(original['is_owner']))
                if current['revoked_at'] is None:
                    return dict(pending, stage='revoke-original')
        # One database observation covers both full grant identities and every scope.
        # Do not filter scope here: missing, additional or foreign entitlements must refuse.
        expected = [dict(grant, app_id=APP, channel=intent['channel'])]
        ids = [grant['grant_id']]
        if original:
            if (any(current[k] != v for k, v in original.items() if k != 'revoked_at') or
                    type(current['revoked_at']) is not int or not 0 < current['revoked_at'] <= 253402300799):
                raise DeliveryError('Original replacement grant identity or revocation is unknown.')
            expected.append(dict(current, app_id=APP, channel=intent['channel']))
            ids.append(original['grant_id'])
        observed = api.query('''SELECT g.*,e.app_id,e.channel FROM grants g
            LEFT JOIN entitlements e ON e.grant_id=g.grant_id
            WHERE g.grant_id IN (''' + ','.join('?' for _ in ids) + ''') ORDER BY g.grant_id,e.app_id,e.channel''', ids)
        if observed != sorted(expected, key=lambda row: row['grant_id']):
            raise DeliveryError('Final grant identity, scope or revocation changed; inspect status privately.')
        # Remote state and local files cannot be read atomically across services.
        # This bounded final custody check follows the final coherent database read;
        # no provider operation occurs after it, and any observed local drift refuses.
        verify_custody()
        return dict(grant_id=grant['grant_id'], status='complete',
                    access_status='expired' if grant['expires_at'] <= int(time.time()) else 'active')


def deployment_config(config, api=None):
    parsed = urllib.parse.urlsplit(config['origin'])
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment or parsed.netloc != parsed.hostname:
        raise DeliveryError('Select a canonical HTTPS download hostname.')
    result = json.loads((ROOT / 'delivery/wrangler.template.json').read_text())
    result.update(name=config['worker_name'], main=str(ROOT / 'delivery/worker.mjs'), account_id=config['account_id'])
    hostname = urllib.parse.urlsplit(config['origin']).hostname
    if hostname == 'workers.dev' or hostname.endswith('.workers.dev'):
        # Read-only ownership proof: never create or claim an account subdomain.
        if api is None:
            raise DeliveryError('Account-owned workers.dev origin requires current subdomain verification.')
        ownership = api.api('/workers/subdomain')
        subdomain = ownership.get('subdomain') if isinstance(ownership, dict) else None
        label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
        if (not isinstance(subdomain, str) or not re.fullmatch(label, subdomain) or
            not re.fullmatch(label, config['worker_name']) or
            hostname != config['worker_name'] + '.' + subdomain + '.workers.dev'):
            raise DeliveryError('Configured origin does not match this worker and the account-owned workers.dev subdomain.')
        result['workers_dev'] = True
        result['routes'] = []
    else:
        raise DeliveryError('Custom routes require separately qualified fail-closed routing; use exact account-owned workers.dev.')
    result['preview_urls'] = False
    result['vars'] = {'UPDATE_ORIGIN': config['origin']}
    result['d1_databases'] = [{'binding': 'DB', 'database_name': config['database_name'], 'database_id': config['database_id']}]
    result['assets'] = {'directory': str(private_directory(config['assets_directory'])), 'binding': 'ASSETS', 'run_worker_first': True, 'html_handling': 'none', 'not_found_handling': 'none'}
    validate_deployment_config(result)
    return result


def validate_deployment_config(value):
    allowed = {'name', 'main', 'account_id', 'compatibility_date', 'workers_dev', 'preview_urls', 'observability', 'routes', 'vars', 'd1_databases', 'assets'}
    if (set(value) != allowed | WORKER_PACKAGING.keys() or
        any(type(value.get(key)) is not type(setting) or value.get(key) != setting
            for key, setting in WORKER_PACKAGING.items()) or
        value.get('workers_dev') is not True or value.get('preview_urls') is not False or value.get('routes') != [] or
        value.get('observability') != {'enabled': False} or
        value.get('assets') != {'directory': value.get('assets', {}).get('directory'), 'binding': 'ASSETS', 'run_worker_first': True, 'html_handling': 'none', 'not_found_handling': 'none'}):
        raise DeliveryError('Only unconditional worker-first private static assets with no routing fallback are supported.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    subs = parser.add_subparsers(dest='command', required=True)
    create = subs.add_parser('create-grant')
    create.add_argument('--label', required=True)
    create.add_argument('--output', required=True, type=Path)
    create.add_argument('--expires-at', required=True, type=int, help='Unix seconds')
    create.add_argument('--owner', action='store_true')
    create.add_argument('--channel', choices=('stable', 'qualification'), default='stable')
    subs.add_parser('list-grants')
    status = subs.add_parser('grant-status')
    status.add_argument('--grant-id', required=True, type=uuid.UUID)
    for name in ('revoke-grant', 'expire-grant', 'replace-grant'):
        command = subs.add_parser(name)
        command.add_argument('--grant-id', required=True, type=uuid.UUID)
        command.add_argument('--channel', choices=('stable', 'qualification'), default='stable')
        command.add_argument('--owner', action='store_true')
        if name != 'revoke-grant':
            command.add_argument('--expires-at', required=True, type=int)
        if name == 'replace-grant':
            command.add_argument('--label', required=True)
            command.add_argument('--output', required=True, type=Path)
    recovery = subs.add_parser('recover-grant')
    recovery.add_argument('--attempt', required=True, type=Path)
    recovery.add_argument('--complete', action='store_true', help='Issue only never-attempted steps after reconciliation')
    readback = subs.add_parser('recover-readback-grant')
    readback.add_argument('--attempt', required=True, type=Path)
    subs.add_parser('check-privacy')
    subs.add_parser('deploy')
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        auth = {name: os.environ[name] for name in ('CLOUDFLARE_API_TOKEN',) if name in os.environ}
        api = Cloudflare(config, wrangler_auth=auth)
        if args.command == 'create-grant':
            grant = create_grant(api, config, args.label, args.output, args.expires_at, args.owner, args.channel)
            print('Created grant ' + grant + '; private access file written with mode 0600.')
        elif args.command in ('list-grants', 'grant-status'):
            rows = access_rows(api, None if args.command == 'list-grants' else args.grant_id)
            print(json.dumps(rows))
        elif args.command in ('revoke-grant', 'expire-grant'):
            result = change_grant(api, args.grant_id, args.channel, args.owner,
                                  args.expires_at if args.command == 'expire-grant' else None)
            print(json.dumps(result))
            print('Subsequent requests honor expiry/revocation; already downloaded or in-flight bytes remain available.')
        elif args.command == 'replace-grant':
            grant = create_grant(api, config, args.label, args.output, args.expires_at, args.owner, args.channel, args.grant_id)
            print('Replacement grant ' + grant + ' verified; original revoked. Already downloaded bytes remain available.')
        elif args.command == 'recover-grant':
            result = recover_grant(api, config, args.attempt, args.complete)
            print(json.dumps(result))
            if result['status'] == 'pending':
                return 2
        elif args.command == 'recover-readback-grant':
            print(json.dumps(recover_readback_grant(api, args.attempt)))
        elif args.command == 'check-privacy':
            api.privacy()
            print('Exact reviewed active version, private origin and preview restrictions verified; live quota/upgrade qualification remains separate.')
        elif args.command == 'deploy':
            api.deploy()
            print('Worker deployment completed. Binary publication and live qualification remain separate.')
    except DeliveryError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        # Never interpolate third-party errors or malformed inputs into diagnostics.
        print('Delivery operation failed. Check explicit configuration, permissions, privacy and exact qualification evidence privately.', file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
