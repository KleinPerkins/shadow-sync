#!/usr/bin/env -S python3 -I
"""Reject unapproved legacy identity in tracked paths and bytes.

Exceptions bind one path, token, scope, count, and complete entry digest. The
policy document is a closed control format, not a directory-wide exclusion.
Generated bundles can be checked separately with --artifact-root; their
exceptions must bind the exact generated entry in a separate reviewed policy.
"""

# This check must reject an unsafe direct launch before importing any module
# that could be shadowed by caller-controlled startup or search-path state.
import sys

if __name__ == "__main__" and not sys.flags.isolated:
    sys.stderr.write(
        "technical identity gate: refusing non-isolated Python startup; "
        "run with python3 -I\n"
    )
    raise SystemExit(2)

import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess


# Encoded legacy Carbon shortcut identity is an active namespace too. Build
# the matcher from byte values so the check does not allowlist its own source.
LEGACY_SHORTCUT_BYTES = bytes((68, 77, 83, 89))
LEGACY_SHORTCUT_VALUE = int.from_bytes(LEGACY_SHORTCUT_BYTES, "big")


def legacy_integer_pattern(prefix, digits):
    return (r"(?<![A-Za-z0-9_])" + prefix + r"(?:0_*)*"
            + r"_*".join(digits) + r"_*(?![A-Za-z0-9_])")


LEGACY_SHORTCUT_NUMERIC = "|".join(
    legacy_integer_pattern(prefix, format(LEGACY_SHORTCUT_VALUE, style))
    for prefix, style in (("0x", "x"), ("0o", "o"), ("0b", "b"), ("", "d"))
)
LEGACY = re.compile(
    r"(?:dev[ _-]?main[ _-]?sync)"
    r"|(?<![A-Za-z0-9])(?:[d][m][s])(?=[_-]|[A-Za-z]|\b)"
    r"|com\.kleinperkins\.shadowsync"
    + "|" + LEGACY_SHORTCUT_NUMERIC,
    re.IGNORECASE,
)
SCHEMA = "shadow-sync-identity-exceptions/v1"
RECEIPT_SCHEMA = "shadow-sync-identity-verification/v1"
INVENTORY_SCHEMA = "shadow-sync-identity-inventory/v2"
LIMIT = 256 * 1024 * 1024
ENTRY_LIMIT = 1_000_000
POLICY_LIMIT = 1024 * 1024
EXCEPTION_LIMIT = 4096
METADATA_LIMIT = 4096
ENTRY_KEYS = {
    "path",
    "scope",
    "token",
    "count",
    "sha256",
    "class",
    "owner",
    "reason",
    "retirement",
}
CLASSES = {"migration-reader", "compatibility-fixture", "historical-record"}
GIT_MODES = {"100644": "file", "100755": "file", "120000": "symlink"}


class Refusal(Exception):
    pass


@dataclass(frozen=True)
class Entry:
    path: str
    kind: str
    git_mode: str = ""
    git_oid: str = ""


@dataclass(frozen=True)
class Inventory:
    entries: tuple[Entry, ...]
    root_identity: tuple[int, ...]
    object_format: str = ""
    index_listing: bytes = b""

    def logical_identity(self):
        return (self.entries, self.object_format, self.index_listing)


def closed_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal("duplicate JSON key")
        result[key] = value
    return result


def safe_path(value):
    if not isinstance(value, str) or not value or "\\" in value:
        raise Refusal("invalid relative path")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise Refusal("relative path must be valid UTF-8") from exc
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise Refusal("control character in relative path")
    path = PurePosixPath(value)
    parts = value.split("/")
    if path.is_absolute() or any(
        part in ("", ".", "..") or part.casefold() == ".git" for part in parts
    ):
        raise Refusal("unsafe relative path")
    return value


def stat_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def open_root(root):
    """Open each absolute root component with O_NOFOLLOW."""
    if not root.is_absolute():
        raise Refusal("root must be absolute")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in root.parts[1:]:
            if part in ("", ".", ".."):
                raise Refusal("unsafe root component")
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=fd,
            )
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def entry_kind(value):
    if stat.S_ISREG(value.st_mode):
        return "file"
    if stat.S_ISLNK(value.st_mode):
        return "symlink"
    if stat.S_ISDIR(value.st_mode):
        return "directory"
    return "special"


def git_blob_oid(data, object_format):
    if object_format not in ("sha1", "sha256"):
        raise Refusal("unsupported Git object format")
    digest = hashlib.new(object_format)
    digest.update(b"blob " + str(len(data)).encode("ascii") + b"\0")
    digest.update(data)
    return digest.hexdigest()


def read_entry(root, entry, object_format=""):
    """Read one entry through no-follow handles and bind its type and bytes."""
    parts = safe_path(entry.path).split("/")
    fd = open_root(root)
    try:
        for part in parts[:-1]:
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=fd,
            )
            os.close(fd)
            fd = next_fd
        before = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        kind = entry_kind(before)
        if kind != entry.kind:
            raise Refusal("entry type differs from inventory")

        if kind == "symlink":
            data = os.fsencode(os.readlink(parts[-1], dir_fd=fd))
        elif kind == "file":
            file_fd = os.open(
                parts[-1],
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=fd,
            )
            try:
                opened = os.fstat(file_fd)
                if stat_identity(opened) != stat_identity(before):
                    raise Refusal("file changed during opening")
                if opened.st_size > LIMIT:
                    raise Refusal("file exceeds identity scanner bound")
                chunks = []
                total = 0
                while True:
                    chunk = os.read(file_fd, min(1024 * 1024, LIMIT + 1 - total))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    total += len(chunk)
                    if total > LIMIT:
                        raise Refusal("file grew beyond scanner bound")
                data = b"".join(chunks)
                after_open = os.fstat(file_fd)
                if stat_identity(opened) != stat_identity(after_open):
                    raise Refusal("file changed while scanning")
            finally:
                os.close(file_fd)
        elif kind == "directory":
            directory_fd = os.open(
                parts[-1],
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=fd,
            )
            try:
                opened = os.fstat(directory_fd)
                if stat_identity(opened) != stat_identity(before):
                    raise Refusal("directory changed during opening")
            finally:
                os.close(directory_fd)
            data = b""
        else:
            raise Refusal("non-regular identity input")

        after = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        if stat_identity(before) != stat_identity(after):
            raise Refusal("path changed while scanning")

        if entry.git_mode:
            if GIT_MODES.get(entry.git_mode) != kind or kind == "directory":
                raise Refusal("working entry type differs from Git index mode")
            if kind == "file":
                executable = bool(before.st_mode & 0o111)
                if executable != (entry.git_mode == "100755"):
                    raise Refusal("working executable mode differs from Git index")
            if git_blob_oid(data, object_format) != entry.git_oid:
                raise Refusal("working bytes differ from Git index blob")

        return data, stat_identity(before)
    finally:
        os.close(fd)


def occurrences(data):
    result = Counter(match.group() for match in LEGACY.finditer(data.decode("latin1")))
    for encoding in ("utf-16-le", "utf-16-be"):
        for offset in (0, 1):
            decoded = data[offset:].decode(encoding, errors="ignore")
            result.update(match.group() for match in LEGACY.finditer(decoded))
    return result


def load_policy(data):
    if len(data) > POLICY_LIMIT:
        raise Refusal("identity policy exceeds size bound")
    try:
        policy = json.loads(data, object_pairs_hook=closed_object)
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise Refusal("invalid identity policy JSON") from exc
    if (
        not isinstance(policy, dict)
        or set(policy) != {"schema", "exceptions"}
        or policy["schema"] != SCHEMA
    ):
        raise Refusal("unknown identity policy shape")
    if not isinstance(policy["exceptions"], list):
        raise Refusal("exceptions must be an array")
    if len(policy["exceptions"]) > EXCEPTION_LIMIT:
        raise Refusal("exceptions array exceeds entry bound")
    entries = {}
    for item in policy["exceptions"]:
        if not isinstance(item, dict) or set(item) != ENTRY_KEYS:
            raise Refusal("unknown exception shape")
        path = safe_path(item["path"])
        scope, token = item["scope"], item["token"]
        if (
            scope not in ("content", "path")
            or not isinstance(token, str)
            or len(token) > METADATA_LIMIT
            or not LEGACY.fullmatch(token)
        ):
            raise Refusal("invalid exception token or scope")
        if type(item["count"]) is not int or item["count"] < 1:
            raise Refusal("exception count must be a positive integer")
        if not isinstance(item["sha256"], str) or not re.fullmatch(
            r"[0-9a-f]{64}", item["sha256"]
        ):
            raise Refusal("invalid exception digest")
        if not isinstance(item["class"], str) or item["class"] not in CLASSES:
            raise Refusal("unsupported exception class")
        for field in ("owner", "reason", "retirement"):
            value = item[field]
            if (
                not isinstance(value, str)
                or not value.strip()
                or len(value) > METADATA_LIMIT
                or LEGACY.search(value)
            ):
                raise Refusal(
                    "exception metadata must be nonempty and free of legacy tokens"
                )
        key = (path, scope, token)
        if key in entries:
            raise Refusal("duplicate identity exception")
        entries[key] = item
    return entries


def git_environment():
    environment = dict(
        os.environ,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_TERMINAL_PROMPT="0",
    )
    for key in tuple(environment):
        if key.startswith("GIT_") and key not in {
            "GIT_CONFIG_NOSYSTEM",
            "GIT_CONFIG_GLOBAL",
            "GIT_TERMINAL_PROMPT",
        }:
            del environment[key]
    return environment


def git_command(root):
    return [
        "git",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-C",
        str(root),
    ]


def git_inventory(root):
    root_fd = open_root(root)
    try:
        root_identity = stat_identity(os.fstat(root_fd))
    finally:
        os.close(root_fd)
    command = git_command(root)
    environment = git_environment()
    top = subprocess.check_output(
        command + ["rev-parse", "--show-toplevel"], env=environment, timeout=30
    ).decode("utf-8", errors="strict").strip()
    if Path(top).resolve() != root:
        raise Refusal("repository root must be the exact Git top level")
    object_format = subprocess.check_output(
        command + ["rev-parse", "--show-object-format"],
        env=environment,
        timeout=30,
    ).decode("ascii", errors="strict").strip()
    if object_format not in ("sha1", "sha256"):
        raise Refusal("unsupported Git object format")
    oid_length = 40 if object_format == "sha1" else 64
    raw = subprocess.check_output(
        command + ["ls-files", "--stage", "-z"], env=environment, timeout=30
    )
    entries = []
    for row in raw.split(b"\0"):
        if not row:
            continue
        try:
            metadata, name = row.split(b"\t", 1)
            mode, oid, stage = metadata.split()
            path = safe_path(name.decode("utf-8", errors="strict"))
            mode_text = mode.decode("ascii", errors="strict")
            oid_text = oid.decode("ascii", errors="strict")
        except (UnicodeError, ValueError) as exc:
            raise Refusal("malformed Git index inventory") from exc
        if (
            stage != b"0"
            or mode_text not in GIT_MODES
            or not re.fullmatch(rf"[0-9a-f]{{{oid_length}}}", oid_text)
        ):
            raise Refusal("unmerged or unsupported tracked entry")
        entries.append(Entry(path, GIT_MODES[mode_text], mode_text, oid_text))
    entries.sort(key=lambda item: item.path)
    if not entries or len({item.path for item in entries}) != len(entries):
        raise Refusal("empty or duplicate tracked inventory")
    return Inventory(tuple(entries), root_identity, object_format, raw)


def artifact_inventory(root):
    root_fd = open_root(root)
    try:
        root_identity = stat_identity(os.fstat(root_fd))
        entries = []

        def walk(directory_fd, prefix):
            try:
                names = sorted(os.listdir(directory_fd))
            except OSError as exc:
                raise Refusal("artifact directory is unreadable") from exc
            for name in names:
                path = safe_path(f"{prefix}/{name}" if prefix else name)
                before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                kind = entry_kind(before)
                if kind == "special":
                    raise Refusal("unsupported artifact entry type")
                entries.append(Entry(path, kind))
                if len(entries) > ENTRY_LIMIT:
                    raise Refusal("artifact inventory exceeds entry bound")
                if kind == "directory":
                    try:
                        child_fd = os.open(
                            name,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=directory_fd,
                        )
                    except OSError as exc:
                        raise Refusal("artifact directory is unreadable") from exc
                    try:
                        if stat_identity(os.fstat(child_fd)) != stat_identity(before):
                            raise Refusal("artifact directory changed during opening")
                        walk(child_fd, path)
                    finally:
                        os.close(child_fd)
                    after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    if stat_identity(before) != stat_identity(after):
                        raise Refusal("artifact directory changed during inventory")

        try:
            walk(root_fd, "")
        except RecursionError as exc:
            raise Refusal("artifact directory nesting exceeds scanner bound") from exc
    finally:
        os.close(root_fd)
    if not entries:
        raise Refusal("empty artifact inventory")
    entries.sort(key=lambda item: item.path)
    return Inventory(tuple(entries), root_identity)


def inventory_digest(records):
    digest = hashlib.sha256()
    prefix = INVENTORY_SCHEMA.encode("ascii")
    digest.update(len(prefix).to_bytes(8, "big"))
    digest.update(prefix)
    for record in records:
        encoded = json.dumps(
            record,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("ascii")
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
    return digest.hexdigest()


def compare_inventory(before, after):
    if before.logical_identity() != after.logical_identity():
        raise Refusal("inventory changed during verification")
    if before.root_identity != after.root_identity:
        raise Refusal("root changed during verification")


def scan(root, inventory, inventory_loader, policy_path):
    if LEGACY.search(policy_path):
        raise Refusal("identity policy path must use the current identity")
    by_path = {entry.path: entry for entry in inventory.entries}
    policy_entry = by_path.get(policy_path)
    if policy_entry is None:
        raise Refusal("policy must be present in the inspected inventory")
    if policy_entry.kind != "file":
        raise Refusal("policy must be a regular file")
    policy_bytes, _ = read_entry(root, policy_entry, inventory.object_format)
    exceptions = load_policy(policy_bytes)

    findings = []
    used = set()
    records = []
    first_reads = {}
    files_scanned = 0
    directories_scanned = 0
    for entry in inventory.entries:
        data, identity = read_entry(root, entry, inventory.object_format)
        content_digest = hashlib.sha256(data).hexdigest()
        first_reads[entry.path] = (content_digest, identity)
        if entry.kind == "directory":
            directories_scanned += 1
        else:
            files_scanned += 1
        records.append(
            {
                "path": entry.path,
                "kind": entry.kind,
                "git_mode": entry.git_mode,
                "git_oid": entry.git_oid,
                "sha256": content_digest,
            }
        )
        if entry.path == policy_path:
            if data != policy_bytes:
                raise Refusal("policy changed during scan")
            continue
        scopes = {
            "path": Counter(match.group() for match in LEGACY.finditer(entry.path)),
            "content": Counter() if entry.kind == "directory" else occurrences(data),
        }
        for scope, tokens in scopes.items():
            for token, count in tokens.items():
                key = (entry.path, scope, token)
                exception = exceptions.get(key)
                if (
                    exception
                    and exception["sha256"] == content_digest
                    and exception["count"] == count
                ):
                    used.add(key)
                else:
                    findings.append(
                        {
                            "path": entry.path,
                            "scope": scope,
                            "token": token,
                            "count": count,
                            "reason": "unapproved or changed legacy reference",
                        }
                    )
    for key in sorted(set(exceptions) - used):
        findings.append(
            {
                "path": key[0],
                "scope": key[1],
                "token": key[2],
                "reason": "unused, changed, or stale exception",
            }
        )

    compare_inventory(inventory, inventory_loader())
    for entry in inventory.entries:
        data, identity = read_entry(root, entry, inventory.object_format)
        digest = hashlib.sha256(data).hexdigest()
        if first_reads[entry.path] != (digest, identity):
            raise Refusal("entry changed during end revalidation")
    compare_inventory(inventory, inventory_loader())

    return {
        "schema": RECEIPT_SCHEMA,
        "passed": not findings,
        "entries_scanned": len(inventory.entries),
        "files_scanned": files_scanned,
        "directories_scanned": directories_scanned,
        "exceptions_used": len(used),
        "policy_sha256": hashlib.sha256(policy_bytes).hexdigest(),
        "inventory_schema": INVENTORY_SCHEMA,
        "inventory_sha256": inventory_digest(records),
        "git_object_format": inventory.object_format or None,
        "git_index_sha256": (
            hashlib.sha256(inventory.index_listing).hexdigest()
            if inventory.index_listing
            else None
        ),
        "findings": findings,
    }


def main(argv=None):
    if not sys.flags.isolated:
        raise Refusal("main requires isolated Python; run with python3 -I")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--policy", default="config/identity-exceptions.json")
    parser.add_argument(
        "--artifact-root",
        action="store_true",
        help="scan every artifact entry instead of Git-tracked entries",
    )
    args = parser.parse_args(argv)
    try:
        root = args.root.absolute()
        root_fd = open_root(root)
        os.close(root_fd)
        if root.resolve() != root:
            raise Refusal("root must be a canonical directory without symlink components")
        policy = safe_path(args.policy)
        loader = (
            (lambda: artifact_inventory(root))
            if args.artifact_root
            else (lambda: git_inventory(root))
        )
        inventory = loader()
        result = scan(root, inventory, loader, policy)
        print(json.dumps(result, sort_keys=True, indent=2))
        return 0 if result["passed"] else 1
    except (
        Refusal,
        OSError,
        UnicodeError,
        ValueError,
        RecursionError,
        subprocess.SubprocessError,
    ) as exc:
        print(
            json.dumps(
                {"schema": RECEIPT_SCHEMA, "passed": False, "error": str(exc)},
                sort_keys=True,
            )
        )
        return 2


if __name__ == "__main__":
    sys.exit(main())
