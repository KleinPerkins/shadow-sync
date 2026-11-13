#!/usr/bin/env -S python3 -I -S -B
"""Bounded pre-access adapter for the separately owned AWA lexical classifier.

The sealed contract pins the separately qualified AWA maintenance release.
The deployed module and policy must still match the owner-authored binding.
No candidate is opened, resolved, inspected, or placed in process arguments here.
"""
import sys

if __name__ == "__main__" and (not sys.flags.isolated or not sys.flags.no_site
                              or not sys.flags.dont_write_bytecode):
    sys.stderr.write("Policy adapter requires isolated Python without site initialization or bytecode writes.\n")
    raise SystemExit(2)

import contextlib
import base64
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import stat
import secrets
import types


REQUEST_SCHEMA = "shadow-sync-policy-request/v1"
RESPONSE_SCHEMA = "shadow-sync-policy-response/v1"
BINDING_SCHEMA = "shadow-sync-host-policy-binding/v1"
CONTRACT_SCHEMA = "shadow-sync-awa-contract/v1"
BINDING_PATH = "Library/Application Support/ShadowSync/host-policy-binding.json"
MAX_REQUEST = 16_384
MAX_BATCH_REQUEST = 262_144
MAX_BATCH_CANDIDATES = 64
MAX_FILE = 1_048_576
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX40 = re.compile(r"[0-9a-f]{40}")
NONCE = re.compile(r"[0-9a-f]{32}")


class Refusal(Exception):
    """A closed refusal; details and candidate data must never reach diagnostics."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def closed_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal()
        result[key] = value
    return result


def decode(data, keys):
    try:
        value = json.loads(data, object_pairs_hook=closed_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(Refusal()))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Refusal() from error
    return exact(value, keys)


def exact(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise Refusal()
    return value


def matches(pattern, value):
    return type(value) is str and pattern.fullmatch(value) is not None


def components(path):
    if type(path) is not str or not path or len(path.encode("utf-8")) > 4096:
        raise Refusal()
    if "\\" in path or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise Refusal()
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise Refusal()
    return parts


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_owned_absolute(path, uid, *, root_owner_allowed=False, limit=MAX_FILE):
    if type(path) is not str or not path.startswith("/"):
        raise Refusal()
    parts = components(path[1:])
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    parent = os.open("/", flags | os.O_DIRECTORY)
    descriptor = -1
    try:
        for part in parts[:-1]:
            next_parent = os.open(part, flags | os.O_DIRECTORY, dir_fd=parent)
            os.close(parent)
            parent = next_parent
            info = os.fstat(parent)
            sticky_system_parent = info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
            if (info.st_uid not in (0, uid)
                    or (stat.S_IMODE(info.st_mode) & 0o022 and not sticky_system_parent)):
                raise Refusal()
        descriptor = os.open(parts[-1], flags, dir_fd=parent)
        before = os.fstat(descriptor)
        owners = (0, uid) if root_owner_allowed else (uid,)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid not in owners
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) & 0o022
                or not 0 < before.st_size <= limit):
            raise Refusal()
        chunks, total = [], 0
        while total <= limit:
            chunk = os.read(descriptor, min(16_384, limit + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        after = os.fstat(descriptor)
        current = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if (total != before.st_size or identity(before) != identity(after)
                or identity(after) != identity(current)):
            raise Refusal()
        return b"".join(chunks), identity(after)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def read_bound(home, item, uid, *, module=False):
    keys = ("module_path", "module_sha256", "release_revision") if module else ("path", "sha256")
    exact(item, keys)
    path_key, hash_key = ("module_path", "module_sha256") if module else ("path", "sha256")
    relative = "/".join(components(item[path_key]))
    if not matches(HEX64, item[hash_key]):
        raise Refusal()
    path = home + "/" + relative
    data, file_identity = read_owned_absolute(path, uid)
    if digest(data) != item[hash_key]:
        raise Refusal()
    return path, data, file_identity


def require_deployed_no_touch_section(policy_bytes):
    """Require the host producer's explicit top-level field, without parsing it.

    AWA owns validation and matching. Its generic contract permits absence, while
    this product's deployment contract requires one canonical unquoted field.
    This check cannot authorize a candidate; the verified AWA classifier still
    validates the complete field and must return the exact allow result.
    """
    try:
        lines = policy_bytes.decode('utf-8').splitlines()
    except UnicodeError as error:
        raise Refusal() from error
    declarations = sum(re.match(r'^hard_no_touch_paths[ \t]*:', line) is not None
                       for line in lines)
    if declarations != 1:
        raise Refusal()


def validate_host_projection(data, policy_binding):
    """Validate generated host data, never infer host layout or classify targets.

    The dev owner supplies concrete values. AWA alone supplies no-touch matching.
    The application consumes this closed projection only under its digest binding.
    No path in this routine is opened, normalized against disk, or resolved.
    """
    if type(data) is not bytes or not 0 < len(data) <= MAX_FILE:
        raise Refusal()
    value = decode(data, ('schema', 'source_inputs', 'governed_root', 'shelves',
                          'path_policy', 'permanent_no_touch_repository_ids',
                          'managed_locations', 'hooks', 'awa_evidence'))
    if value['schema'] != 'shadow-sync-host-policy-projection/v1':
        raise Refusal()

    def sequence(items, *, maximum=256, empty=True):
        if type(items) is not list or len(items) > maximum or (not empty and not items):
            raise Refusal()
        return items

    def path_parts(parts, *, maximum=16, hidden=True):
        sequence(parts, maximum=maximum, empty=False)
        if any(type(part) is not str or '/' in part or part.startswith('~')
               or (not hidden and part.startswith('.')) for part in parts):
            raise Refusal()
        if components('/'.join(parts)) != parts:
            raise Refusal()
        return tuple(parts)

    def distinct(items):
        if len(set(items)) != len(items):
            raise Refusal()

    def overlapping(left, right):
        return left[:len(right)] == right or right[:len(left)] == left

    def disjoint(paths):
        for index, path in enumerate(paths):
            if any(overlapping(path, other) for other in paths[:index]):
                raise Refusal()

    def repository_id(item):
        if (type(item) is not str or len(item) > 200
                or re.fullmatch(r'[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._-]*', item) is None):
            raise Refusal()

    def source(item):
        exact(item, ('path', 'sha256'))
        components(item['path'])
        if item['path'].startswith('~') or not matches(HEX64, item['sha256']):
            raise Refusal()

    sources = exact(value['source_inputs'], ('worktree_policy', 'host_overlay', 'hook_dispatcher'))
    for item in sources.values():
        source(item)
    distinct([item['path'] for item in sources.values()])
    if sources['worktree_policy'] != policy_binding:
        raise Refusal()
    root = exact(value['governed_root'], ('components', 'display_label', 'repository_id'))
    root_parts = path_parts(root['components'])
    if root['display_label'] != '~/' + '/'.join(root_parts):
        raise Refusal()
    repository_id(root['repository_id'])
    shelves = [path_parts(parts, maximum=3, hidden=False)
               for parts in sequence(value['shelves'], maximum=32, empty=False)]
    disjoint(shelves)

    paths = exact(value['path_policy'], ('excluded', 'read_only', 'artifacts', 'writable'))
    for key, patterns in paths.items():
        sequence(patterns)
        for pattern in patterns:
            if type(pattern) is not str:
                raise Refusal()
            if pattern == '.':
                continue
            concrete = pattern[:-2] if pattern.endswith('/*') and key != 'writable' else pattern
            if any(char in concrete for char in '*?[]'):
                raise Refusal()
            path_parts(components(concrete), hidden=False)
        distinct(patterns)
    # The explicit root-repository role may override the umbrella's '.' exclusion.
    # No descendant writable override can suppress an excluded/read-only/artifact path.
    restricted = paths['excluded'] + paths['read_only'] + paths['artifacts']
    for writable in paths['writable']:
        for pattern in restricted:
            if (writable == pattern == '.' and pattern in paths['excluded']
                    and pattern not in paths['read_only'] + paths['artifacts']):
                continue
            prefix = pattern[:-2] if pattern.endswith('/*') else pattern
            if writable == prefix or writable.startswith(prefix + '/'):
                raise Refusal()

    ids = sequence(value['permanent_no_touch_repository_ids'])
    for item in ids:
        repository_id(item)
    distinct(ids)
    if root['repository_id'] in ids:
        raise Refusal()
    locations, kinds = [], []
    for item in sequence(value['managed_locations'], maximum=16):
        exact(item, ('kind', 'components', 'minimum_depth'))
        if (item['kind'] not in ('cursor', 'codex', 'awa') or type(item['minimum_depth']) is not int
                or not 1 <= item['minimum_depth'] <= 16):
            raise Refusal()
        kinds.append(item['kind'])
        locations.append(path_parts(item['components']))
    distinct(kinds)
    disjoint([root_parts] + locations)

    hooks = exact(value['hooks'], ('foreign_markers', 'dispatcher_base64', 'dispatcher_sha256'))
    markers = sequence(hooks['foreign_markers'], maximum=32, empty=False)
    for marker in markers:
        if type(marker) is not str or re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', marker) is None:
            raise Refusal()
    distinct(markers)
    if type(hooks['dispatcher_base64']) is not str or len(hooks['dispatcher_base64']) > 90_000:
        raise Refusal()
    try:
        dispatcher = base64.b64decode(hooks['dispatcher_base64'], validate=True)
    except (ValueError, UnicodeError) as error:
        raise Refusal() from error
    if (not 0 < len(dispatcher) <= 65_536 or b'\0' in dispatcher
            or base64.b64encode(dispatcher).decode() != hooks['dispatcher_base64']
            or digest(dispatcher) != hooks['dispatcher_sha256']
            or hooks['dispatcher_sha256'] != sources['hook_dispatcher']['sha256']):
        raise Refusal()

    evidence = value['awa_evidence']
    if evidence is not None:
        exact(evidence, ('adapter_path', 'root_records_path', 'lease_components'))
        for key in ('adapter_path', 'root_records_path'):
            path_parts(components(evidence[key]))
        path_parts(evidence['lease_components'], maximum=4)
    return value


def open_private_directory(path, uid):
    """Anchor configuration scratch space without following any component."""
    if type(path) is not str or not path.startswith('/'):
        raise Refusal()
    parts = components(path[1:])
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open('/', flags)
    try:
        for part in parts:
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            info = os.fstat(descriptor)
            sticky_system_parent = info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, uid)
                    or (stat.S_IMODE(info.st_mode) & 0o022 and not sticky_system_parent)):
                raise Refusal()
        info = os.fstat(descriptor)
        if info.st_uid != uid or stat.S_IMODE(info.st_mode) & 0o077:
            raise Refusal()
        result, descriptor = descriptor, -1
        return result
    finally:
        if descriptor >= 0:
            os.close(descriptor)


@contextlib.contextmanager
def policy_snapshot(policy_bytes, temporary_parent, uid):
    """Give the path-based AWA API an owned, unlinked, read-only Darwin fd."""
    if not 0 < len(policy_bytes) <= MAX_FILE:
        raise Refusal()
    parent = open_private_directory(temporary_parent, uid)
    writer = reader = -1
    name = None
    file_identity = None
    try:
        for _ in range(8):
            candidate_name = 'shadow-sync-policy-' + secrets.token_hex(16)
            try:
                writer = os.open(candidate_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
            except FileExistsError:
                continue
            name = candidate_name
            file_identity = identity(os.fstat(writer))
            break
        else:
            raise Refusal()
        offset = 0
        while offset < len(policy_bytes):
            written = os.write(writer, policy_bytes[offset:])
            if written <= 0:
                raise Refusal()
            offset += written
        os.fchmod(writer, 0o400)
        os.fsync(writer)
        file_identity = identity(os.fstat(writer))
        reader = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                         dir_fd=parent)
        if (identity(os.fstat(reader)) != file_identity
                or identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != file_identity):
            raise Refusal()
        os.close(writer)
        writer = -1
        os.unlink(name, dir_fd=parent)
        name = None
        before = os.fstat(reader)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != uid or before.st_nlink != 0
                or stat.S_IMODE(before.st_mode) != 0o400 or before.st_size != len(policy_bytes)):
            raise Refusal()
        os.lseek(reader, 0, os.SEEK_SET)
        yield '/dev/fd/' + str(reader)
        if (identity(os.fstat(reader)) != identity(before)
                or os.pread(reader, MAX_FILE + 1, 0) != policy_bytes):
            raise Refusal()
    finally:
        try:
            if writer >= 0:
                # A partial write changes size/times; compare the retained fd.
                file_identity = identity(os.fstat(writer))
            if name is not None:
                try:
                    current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    if file_identity is not None and identity(current) == file_identity:
                        os.unlink(name, dir_fd=parent)
                except FileNotFoundError:
                    pass
        finally:
            # Cleanup failure still refuses, but never leaks our open descriptors.
            for descriptor in (reader, writer, parent):
                if descriptor >= 0:
                    with contextlib.suppress(OSError):
                        os.close(descriptor)


class RejectOutput:
    def write(self, value):
        if value:
            raise Refusal()
        return 0

    def flush(self):
        pass


def classify(request_bytes, contract_bytes, *, home, uid, temporary_parent, _compiled_module=None):
    """Internal seam accepts explicit fixture roots; production main never does."""
    if len(request_bytes) > MAX_REQUEST:
        raise Refusal()
    request = decode(request_bytes, ("schema", "nonce", "binding_sha256", "candidate"))
    if (request["schema"] != REQUEST_SCHEMA or not matches(NONCE, request["nonce"])
            or not matches(HEX64, request["binding_sha256"])
            or type(request["candidate"]) is not str
            or len(request["candidate"].encode("utf-8")) > 4096):
        raise Refusal()
    # The later filesystem operation must use exactly the string classified here.
    # Do not let a lexical collapse authorize a raw path that traverses a protected
    # component (for example, protected/../allowed). Expansion belongs to the
    # caller's verified scope construction, before this admission boundary.
    if not request["candidate"].startswith("/"):
        raise Refusal()
    components(request["candidate"][1:])
    contract = decode(contract_bytes, ("schema", "status", "release_revision", "module_sha256"))
    if (contract["schema"] != CONTRACT_SCHEMA or contract["status"] != "qualified"
            or not matches(HEX40, contract["release_revision"])
            or contract["release_revision"] == "0" * 40
            or not matches(HEX64, contract["module_sha256"])):
        raise Refusal()
    if type(home) is not str or not home.startswith("/") or home == "/":
        raise Refusal()
    components(home[1:])
    binding_path = home + "/" + BINDING_PATH
    binding_bytes, binding_identity = read_owned_absolute(binding_path, uid)
    if digest(binding_bytes) != request["binding_sha256"]:
        raise Refusal()
    binding = decode(binding_bytes, ("schema", "policy", "projection", "awa"))
    if binding["schema"] != BINDING_SCHEMA:
        raise Refusal()
    policy = read_bound(home, binding["policy"], uid)
    require_deployed_no_touch_section(policy[1])
    projection = read_bound(home, binding["projection"], uid)
    validate_host_projection(projection[1], binding['policy'])
    module_input = read_bound(home, binding["awa"], uid, module=True)
    if (binding["awa"]["release_revision"] != contract["release_revision"]
            or binding["awa"]["module_sha256"] != contract["module_sha256"]):
        raise Refusal()

    # Execute the exact verified bytes; importing by path would reopen mutable code.
    module_name = "_shadow_sync_verified_awa_policy"
    if module_name in sys.modules:
        raise Refusal()
    module = types.ModuleType(module_name)
    sys.modules[module_name] = module
    try:
        with contextlib.redirect_stdout(RejectOutput()), contextlib.redirect_stderr(RejectOutput()):
            # Reuse only compilation of exact bytes inside this batch. Every
            # candidate still reads/verifies its authority above, executes a new
            # module and matcher here, and checks all source identities below.
            if _compiled_module and _compiled_module[0] == module_input[1]:
                code = _compiled_module[1]
            else:
                code = compile(module_input[1], "<verified-awa-policy>", "exec")
                if _compiled_module is not None:
                    _compiled_module[:] = [module_input[1], code]
            exec(code, module.__dict__)
            if getattr(module, "HARD_NO_TOUCH_SCHEMA", None) != "awa-hard-no-touch/v1":
                raise Refusal()
            # Darwin's /dev/fd opens the existing regular-file descriptor even
            # with AWA's O_NOFOLLOW. No mutable temporary pathname reaches AWA.
            with policy_snapshot(policy[1], temporary_parent, uid) as snapshot:
                matcher = module.load_hard_no_touch_matcher(snapshot, home=home)
                if not isinstance(matcher, module.HardNoTouchMatcher):
                    raise Refusal()
                decision = matcher.classify(request["candidate"])
    finally:
        sys.modules.pop(module_name, None)

    expected = {"none": (False, True), "exact_root": (True, True),
                "managed_namespace": (True, True), "invalid_candidate": (True, True),
                "invalid_policy": (True, False)}
    kind = decision.kind
    if (type(kind) is not str or kind not in expected
            or type(decision.matched) is not bool or type(decision.policy_valid) is not bool
            or (decision.matched, decision.policy_valid) != expected[kind]):
        raise Refusal()
    for path, data, file_identity in [(binding_path, binding_bytes, binding_identity),
                                      policy, projection, module_input]:
        current_data, current_identity = read_owned_absolute(path, uid)
        if current_data != data or current_identity != file_identity:
            raise Refusal()
    return {"schema": RESPONSE_SCHEMA, "nonce": request["nonce"],
            "binding_sha256": digest(binding_bytes), "policy_sha256": digest(policy[1]),
            "module_sha256": digest(module_input[1]), "matched": decision.matched,
            "kind": kind, "policy_valid": decision.policy_valid}


def classify_batch(request_bytes, contract_bytes, *, home, uid, temporary_parent):
    """One atomic response; no partial allow escapes if any snapshot changes."""
    if type(request_bytes) is not bytes or len(request_bytes) > MAX_BATCH_REQUEST:
        raise Refusal()
    request = decode(request_bytes, ('schema', 'nonce', 'binding_sha256', 'candidates'))
    if (request['schema'] != 'shadow-sync-policy-batch-request/v1'
            or not matches(NONCE, request['nonce'])
            or not matches(HEX64, request['binding_sha256'])
            or type(request['candidates']) is not list
            or not 0 < len(request['candidates']) <= MAX_BATCH_CANDIDATES):
        raise Refusal()
    for candidate in request['candidates']:
        if type(candidate) is not str or not candidate.startswith('/') or candidate == '/':
            raise Refusal()
        components(candidate[1:])
    if len(set(request['candidates'])) != len(request['candidates']):
        raise Refusal()
    expected = {'none': (False, True), 'exact_root': (True, True),
                'managed_namespace': (True, True), 'invalid_candidate': (True, True),
                'invalid_policy': (True, False)}
    common, decisions = None, []
    compiled_module = []  # At most one byte/code pair; never authority or decisions.
    for index, candidate in enumerate(request['candidates']):
        single = {'schema': REQUEST_SCHEMA, 'nonce': request['nonce'],
                  'binding_sha256': request['binding_sha256'], 'candidate': candidate}
        response = classify(json.dumps(single, separators=(',', ':')).encode(), contract_bytes,
                            home=home, uid=uid, temporary_parent=temporary_parent,
                            _compiled_module=compiled_module)
        exact(response, ('schema', 'nonce', 'binding_sha256', 'policy_sha256', 'module_sha256',
                         'matched', 'kind', 'policy_valid'))
        identity_fields = {key: response[key] for key in ('binding_sha256', 'policy_sha256', 'module_sha256')}
        if (response['schema'] != RESPONSE_SCHEMA or response['nonce'] != request['nonce']
                or response['binding_sha256'] != request['binding_sha256']
                or not all(matches(HEX64, value) for value in identity_fields.values())
                or type(response['kind']) is not str or response['kind'] not in expected
                or type(response['matched']) is not bool or type(response['policy_valid']) is not bool
                or (response['matched'], response['policy_valid']) != expected[response['kind']]
                or (common is not None and common != identity_fields)):
            raise Refusal()
        common = identity_fields
        decisions.append({'index': index, 'matched': response['matched'],
                          'kind': response['kind'], 'policy_valid': response['policy_valid']})
    return {'schema': 'shadow-sync-policy-batch-response/v1', 'nonce': request['nonce'],
            **common, 'results': decisions}


def dispatch(request_bytes, contract_bytes, *, home, uid, temporary_parent):
    if type(request_bytes) is not bytes or len(request_bytes) > MAX_BATCH_REQUEST:
        raise Refusal()
    try:
        header = json.loads(request_bytes, object_pairs_hook=closed_pairs,
                            parse_constant=lambda _: (_ for _ in ()).throw(Refusal()))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Refusal() from error
    if type(header) is not dict:
        raise Refusal()
    schema = header.get('schema')
    if schema == REQUEST_SCHEMA:
        handler = classify
    elif schema == 'shadow-sync-policy-batch-request/v1':
        handler = classify_batch
    else:
        raise Refusal()
    return handler(request_bytes, contract_bytes, home=home, uid=uid, temporary_parent=temporary_parent)


def run_sealed(contract):
    """Native entrypoint: contract bytes arrived in an immutable resource descriptor."""
    try:
        if (sys.platform != "darwin" or not sys.flags.isolated or not sys.flags.no_site
                or not sys.flags.dont_write_bytecode
                or type(contract) is not bytes or not 0 < len(contract) <= 16_384):
            raise Refusal()
        uid = os.geteuid()
        if uid == 0 or uid != os.getuid():
            raise Refusal()
        home = pwd.getpwuid(uid).pw_dir
        temporary_parent = os.confstr("CS_DARWIN_USER_TEMP_DIR")
        if not temporary_parent:
            raise Refusal()
        # Only canonicalize the OS-provided scratch locator, never a candidate.
        temporary_parent = str(Path(temporary_parent).resolve(strict=True))
        request = sys.stdin.buffer.read(MAX_BATCH_REQUEST + 1)
        response = dispatch(request, contract, home=home, uid=uid, temporary_parent=temporary_parent)
        print(json.dumps(response, sort_keys=True, separators=(",", ":")))
        return 0
    except (Exception, SystemExit):
        sys.stderr.write("Policy classification unavailable.\n")
        return 2


def main():
    try:
        if len(sys.argv) != 1:
            raise Refusal()
        contract_path = str(Path(__file__).absolute().with_name("awa-contract.json"))
        contract, _ = read_owned_absolute(contract_path, os.geteuid(),
                                           root_owner_allowed=True, limit=16_384)
    except (Exception, SystemExit):
        sys.stderr.write("Policy classification unavailable.\n")
        return 2
    return run_sealed(contract)


if __name__ == "__main__":
    raise SystemExit(main())
