#!/usr/bin/env python3
"""Build the pinned, relocated arm64 policy runtime; never install it.

Inputs are an already downloaded PSF package and an explicit signing identity.
This script does not fetch dependencies, execute package installer scripts,
access signing secrets, publish, notarize, or install. The output directory must
not exist. Failures preserve that task-owned directory for diagnosis.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parent.parent
PIN_PATH = ROOT / "Resources/policy-runtime-source.json"
NOTICES_PATH = ROOT / "Resources/PolicyRuntimeNotices"
LEGACY = "/Library/Frameworks/Python.framework/"
MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
RECIPE = "stdlib-source-checked-bytecode-zip/v1"
STDLIB = "Versions/3.14/lib/python3.14"
STDLIB_ZIP = "Versions/3.14/lib/python314.zip"
STDLIB_MANIFEST = "Versions/3.14/Resources/ShadowSyncStdlibArchive.json"


class BuildRefused(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise BuildRefused(message)


def sha(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def run(argv, timeout=120):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"})
    require(result.returncode == 0, f"{argv[0]} failed ({result.returncode}): {result.stderr}")
    return result.stdout + result.stderr


def load_pin():
    value = json.loads(PIN_PATH.read_text())
    require(set(value) == {"schema", "version", "framework_version", "architecture",
        "package_url", "package_sha256", "package_bytes", "upstream_team",
        "package_license_sha256", "selection_recipe", "notices_manifest_sha256"}, "Unexpected pin fields")
    require(value["schema"] == "shadow-sync-policy-runtime-source/v1"
            and value["selection_recipe"] == RECIPE and value["architecture"] == "arm64"
            and value["version"] == "3.14.10" and value["framework_version"] == "3.14",
            "Unreviewed runtime or recipe")
    for key in ["package_sha256", "package_license_sha256", "notices_manifest_sha256"]:
        require(re.fullmatch(r"[0-9a-f]{64}", value[key]) is not None, "Invalid source digest")
    require(value["upstream_team"] == "BMM5U3QVKW"
            and value["package_url"] == "https://www.python.org/ftp/python/3.14.10/python-3.14.10-macos11.pkg"
            and type(value["package_bytes"]) is int and value["package_bytes"] > 0,
            "Unreviewed upstream source")
    return value


def load_notice_bundle(pin, root=NOTICES_PATH):
    """Snapshot the exact reviewed notice set before invoking packaging tools."""
    require(root.is_absolute() and root.parent.resolve(strict=True) == root.parent,
            "Noncanonical notice directory")
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        def read(name):
            require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name) is not None,
                    "Invalid notice filename")
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                 dir_fd=directory)
            try:
                before = os.fstat(descriptor)
                require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                        and 0 < before.st_size <= 1024 * 1024, "Invalid notice file")
                data = b""
                while len(data) <= before.st_size:
                    block = os.read(descriptor, min(65536, before.st_size - len(data) + 1))
                    if not block:
                        break
                    data += block
                after = os.fstat(descriptor)
                stable = lambda info: (info.st_dev, info.st_ino, info.st_size,
                                       info.st_mtime_ns, info.st_ctime_ns)
                require(len(data) == before.st_size and stable(before) == stable(after),
                        "Notice changed during snapshot")
                return data
            finally:
                os.close(descriptor)
        raw = read("manifest.json")
        require(hashlib.sha256(raw).hexdigest() == pin["notices_manifest_sha256"],
                "Notice manifest differs from source pin")
        manifest = json.loads(raw)
        require(set(manifest) == {"schema", "package_sha256", "cpython_revision",
                "selection_recipe", "files", "components"}
                and manifest["schema"] == "shadow-sync-policy-runtime-notices/v1"
                and manifest["package_sha256"] == pin["package_sha256"]
                and manifest["selection_recipe"] == pin["selection_recipe"]
                and manifest["cpython_revision"] == "b703b2c5e704341d61e367b9b940b77ed11dded0"
                and isinstance(manifest["files"], dict) and len(manifest["files"]) == 15,
                "Notice manifest does not bind the selected runtime")
        names = set(manifest["files"]) | {"manifest.json"}
        require(set(os.listdir(directory)) == names, "Missing or unexpected notice file")
        snapshot = {"manifest.json": raw}
        for name, expected in manifest["files"].items():
            require(set(expected) == {"bytes", "sha256", "source"}, "Unexpected notice metadata")
            data = read(name)
            require(len(data) == expected["bytes"]
                    and hashlib.sha256(data).hexdigest() == expected["sha256"],
                    "Notice bytes differ from reviewed manifest")
            snapshot[name] = data
        require(sum(map(len, snapshot.values())) <= 2 * 1024 * 1024, "Notice bundle too large")
        require(set(os.listdir(directory)) == names, "Notice directory changed during snapshot")
        return snapshot
    finally:
        os.close(directory)


def install_notice_snapshot(snapshot, resources):
    target = resources / "ThirdPartyNotices"
    target.mkdir(mode=0o755)
    for name, data in sorted(snapshot.items()):
        path = target / name
        with path.open("xb") as stream:
            stream.write(data)
        path.chmod(0o644)


def selected(relative):
    parts = PurePosixPath(relative).parts
    require(parts and all(p not in {"", ".", ".."} for p in parts)
            and not relative.startswith("/"), "Invalid payload path")
    if parts[0] in {"Python", "Resources"}:
        return len(parts) == 1
    if parts[0] != "Versions":
        return False
    if len(parts) == 1 or parts == ("Versions", "Current"):
        return True
    if parts[1] != "3.14":
        return False
    if len(parts) == 2:
        return True
    if parts[2] not in {"Python", "Resources", "lib"}:
        return False
    # Signatures are regenerated after relocation. This exact pinned package
    # contains source only; checked-hash bytecode is generated before compaction.
    if "_CodeSignature" in parts:
        return False
    if parts[2] == "lib":
        if len(parts) >= 4 and parts[3] == "pkgconfig":
            return False
        if len(parts) >= 5 and parts[3] == "python3.14":
            if parts[4] in {"tkinter", "idlelib", "turtledemo", "turtle.py",
                            "ensurepip", "venv", "test", "config-3.14-darwin"}:
                return False
            if parts[4] == "lib-dynload" and len(parts) >= 6 and parts[5].startswith("_tkinter."):
                return False
            if parts[4] == "__pycache__" and len(parts) >= 6 and parts[5].startswith("turtle."):
                return False
    return True


def inventory(root, include=None):
    rows = {}
    root = root.resolve(strict=True)
    for parent, directories, files in os.walk(root, followlinks=False):
        if include is not None:
            directories[:] = [name for name in directories
                              if include((Path(parent) / name).relative_to(root).as_posix())]
            files = [name for name in files
                     if include((Path(parent) / name).relative_to(root).as_posix())]
        for name in sorted(directories + files):
            path = Path(parent) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            row = {"mode": stat.S_IMODE(info.st_mode)}
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                require(not os.path.isabs(target), "Absolute framework link")
                require(path.resolve(strict=True).is_relative_to(root), "Escaping framework link")
                row.update(kind="symlink", target=target)
            elif stat.S_ISDIR(info.st_mode):
                row.update(kind="directory")
            elif stat.S_ISREG(info.st_mode):
                require(info.st_nlink == 1, "Hard-linked payload file")
                row.update(kind="file", bytes=info.st_size, sha256=sha(path))
            else:
                raise BuildRefused("Special payload node")
            rows[relative] = row
    return dict(sorted(rows.items()))


def copy_selected(source, destination):
    # The authenticated upstream package also contains excluded development
    # links (including dangling Tk headers). Do not traverse or copy that tree.
    # Every selected link must resolve inside the selected output after copy.
    wanted = inventory(source, include=selected)
    destination.mkdir(mode=0o755)
    for name, row in sorted(wanted.items(), key=lambda item: (len(PurePosixPath(item[0]).parts), item[0])):
        target = destination / name
        if row["kind"] == "directory":
            target.mkdir(mode=0o755)
        elif row["kind"] == "symlink":
            target.symlink_to(row["target"])
            os.lchmod(target, 0o755)
        else:
            # Copy data only; do not import source ACLs or extended attributes.
            with (source / name).open("rb") as incoming, target.open("xb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
            target.chmod(0o755 if row["mode"] & 0o111 else 0o644)
            require(sha(target) == row["sha256"], "Payload copy changed")
    observed = inventory(destination)
    require(set(observed) == set(wanted), "Incomplete selected payload")
    return wanted


def dependency_replacement(dependency, binary, framework):
    if dependency.startswith(LEGACY):
        suffix = dependency[len(LEGACY):]
        require(suffix and not PurePosixPath(suffix).is_absolute()
                and ".." not in PurePosixPath(suffix).parts, "Invalid framework dependency")
        target = framework / suffix
        require(target.resolve(strict=True).is_relative_to(framework.resolve(strict=True)),
                "Escaping dependency")
        return "@loader_path/" + os.path.relpath(target, binary.parent)
    if dependency.startswith(("/usr/lib/", "/System/Library/")):
        require(os.path.normpath(dependency) == dependency, "Noncanonical system dependency")
        return dependency
    raise BuildRefused("Unreviewed external dependency")


def dependencies(path):
    lines = run(["/usr/bin/otool", "-L", str(path)]).splitlines()
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in lines if line.startswith("\t")]


def signing_arguments(identity, team, fixture):
    if identity == "-":
        require(fixture and team is None, "Ad-hoc signing requires the explicit fixture flag")
        # Ad-hoc identities have no publisher Team ID, so they cannot qualify
        # hardened-runtime library validation between a helper and a framework.
        # Fixture mode proves layout/behavior only; it never adds a library-
        # validation exception or claims to qualify Developer ID execution.
        return ["--sign", "-", "--timestamp=none"]
    require(not fixture and re.fullmatch(r"[0-9A-Fa-f]{40}", identity) is not None
            and team is not None and re.fullmatch(r"[A-Z0-9]{10}", team) is not None,
            "Release signing requires a certificate fingerprint and publisher team")
    return ["--sign", identity, "--timestamp", "--options", "runtime"]


def intended_publisher_team():
    # Source is the trust authority. Release metadata must match the compiled
    # pin, and caller-supplied signing configuration cannot choose another team.
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, "Duplicate release-contract key")
            result[key] = value
        return result
    contract = json.loads((ROOT / "Resources/release-contract.json").read_bytes(), object_pairs_hook=unique)
    compiled = re.findall(r'public static let publisherTeamIdentifier = "([A-Z0-9]{10})"',
                          (ROOT / "Sources/ShadowSyncCore/ReleaseIdentity.swift").read_text())
    require(len(compiled) == 1 and contract.get("schema") == "shadow-sync-release-contract/v1"
            and contract.get("bundle_identifier") == "com.kleinperkins.shadow-sync"
            and contract.get("publisher_team_identifier") == compiled[0], "Publisher source binding differs")
    return compiled[0]


def validate_publisher_configuration(team, fixture):
    expected = intended_publisher_team()
    require(team is None if fixture else team == expected, "Signing configuration differs from intended publisher")


def validate_upstream_signature(signature):
    require(re.search(r"^\s+Status: signed by a developer certificate issued by Apple for distribution$",
                      signature, re.MULTILINE) is not None
            and re.search(r"^\s+1\. Developer ID Installer: Python Software Foundation \(BMM5U3QVKW\)$",
                          signature, re.MULTILINE) is not None
            and re.search(r"^\s+Signed with a trusted timestamp on: \d{4}-\d{2}-\d{2} .+$",
                          signature, re.MULTILINE) is not None,
            "Unexpected upstream installer identity")


def developer_id_requirement(team):
    require(re.fullmatch(r"[A-Z0-9]{10}", team) is not None, "Invalid publisher team")
    # Apple Development / App Store certificates of the same team are not
    # Developer ID Application certificates. Require both class-specific OIDs.
    return ('=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] '
            'and certificate leaf[field.1.2.840.113635.100.6.1.13] '
            'and certificate leaf[subject.OU] = "' + team + '"')


def snapshot_package(package, output, expected_bytes, expected_sha256):
    require(package.is_absolute(), "Expected an absolute package path")
    descriptor = os.open(package, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_size == expected_bytes,
                "Unexpected package input")
        destination = output / "upstream.pkg"
        with destination.open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            copied = 0
            while True:
                block = os.read(descriptor, min(1024 * 1024, expected_bytes - copied + 1))
                if not block:
                    break
                copied += len(block)
                require(copied <= expected_bytes, "Package grew while snapshotting")
                stream.write(block)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o400)
        after = os.fstat(descriptor)
        stable = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        require(stable(before) == stable(after), "Package changed while snapshotting")
        require(destination.stat().st_size == expected_bytes and sha(destination) == expected_sha256,
                "Package snapshot does not match the source pin")
        return destination
    finally:
        os.close(descriptor)


def valid_source_member(name):
    return (isinstance(name, str) and 0 < len(name) <= 512
            and re.fullmatch(r"[A-Za-z0-9_.\-/]+\.py", name) is not None
            and not name.startswith("/") and "//" not in name
            and all(p not in {".", ".."} for p in name.split("/")))


def read_member(root, name, expected):
    require(valid_source_member(name.removesuffix("c") if name.endswith(".pyc") else name),
            "Unsafe archive member")
    path = root / name
    require(path.resolve(strict=True) == path, "Redirected archive input")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 <= before.st_size <= 4 * 1024 * 1024,
                "Invalid archive input")
        with os.fdopen(os.dup(fd), "rb") as stream:
            data = stream.read(4 * 1024 * 1024 + 1)
        after = os.fstat(fd)
        stable = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(stable(before) == stable(after) and len(data) == before.st_size
                and hashlib.sha256(data).hexdigest() == expected, "Archive input drift")
        return data
    finally:
        os.close(fd)


def verify_stdlib_archive(archive, members):
    with zipfile.ZipFile(archive) as z:
        require(z.comment == b"" and z.namelist() == sorted(members)
                and len(z.namelist()) == len(set(z.namelist())), "Archive inventory differs")
        for info in z.infolist():
            require(info.compress_type == zipfile.ZIP_STORED
                    and info.date_time == (1980, 1, 1, 0, 0, 0)
                    and info.create_system == 3 and info.flag_bits == 0
                    and info.external_attr == (stat.S_IFREG | 0o644) << 16
                    and not info.extra and not info.comment, "Noncanonical archive metadata")
            row = members[info.filename]
            require(info.file_size == row['bytes'] and info.file_size <= 4 * 1024 * 1024,
                    "Archive member size differs")
            require(hashlib.sha256(z.read(info)).hexdigest() == row['sha256'], "Archive member bytes differ")


def write_stdlib_archive(source, bytecode, archive, sources, compiled):
    require(isinstance(sources, dict) and 1 <= len(sources) <= 1024
            and set(compiled) == set(sources), "Incomplete compiled inventory")
    payload = {}
    for name, digest in sorted(sources.items()):
        require(valid_source_member(name), "Unsafe source member")
        row = compiled[name]
        require(set(row) == {'source_sha256', 'bytecode_sha256', 'source_hash', 'bytecode_bytes'}
                and row['source_sha256'] == digest, "Bytecode source binding differs")
        source_bytes = read_member(source, name, digest)
        code = read_member(bytecode, name + 'c', row['bytecode_sha256'])
        require(len(code) == row['bytecode_bytes'] and len(code) > 16
                and code[:8] == bytes.fromhex('2b0e0d0a03000000')
                and code[8:16].hex() == row['source_hash'], "Bytecode format differs")
        payload[name] = source_bytes
        payload[name + 'c'] = code
    members = {name: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
               for name, data in sorted(payload.items())}
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_STORED) as z:
        for name, data in sorted(payload.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            info.compress_type = zipfile.ZIP_STORED
            z.writestr(info, data)
    archive.chmod(0o644)
    verify_stdlib_archive(archive, members)
    return members


def compact_stdlib(framework, out, pin):
    """Compile with the authenticated relocated interpreter before removing any source."""
    before = inventory(framework)
    sources = {name[len(STDLIB) + 1:]: row['sha256'] for name, row in before.items()
               if name.startswith(STDLIB + '/') and name.endswith('.py') and row['kind'] == 'file'}
    require(len(sources) == 554 and all(valid_source_member(n) for n in sources), "Unreviewed source inventory")
    require(not any(name.endswith('.pyc') for name in before) and STDLIB_ZIP not in before,
            "Unexpected precompiled runtime")
    interpreter = framework / 'Versions/3.14/Resources/Python.app/Contents/MacOS/Python'
    driver = ROOT / 'scripts/compile-runtime-bytecode.py'
    driver_digest, interpreter_digest = sha(driver), sha(interpreter)
    bytecode = out / 'bytecode'
    bytecode.mkdir(mode=0o700)
    # The exact source-owned driver cannot fork, access user data/network, or
    # write anywhere except this fresh output. subprocess.run retains and reaps
    # its direct child on failure/timeout; the kernel forbids descendants.
    literal = lambda p: json.dumps(str(p))
    profile = ('(version 1)(allow default)(deny network*)(deny process-fork)'
        '(deny file-read* file-write* (subpath "/Users"))(deny file-write*)(deny process-exec)'
        f'(allow file-read* (subpath {literal(framework)})(literal {literal(driver)})(subpath {literal(bytecode)}))'
        f'(allow file-write* (subpath {literal(bytecode)}))'
        f'(allow process-exec (literal {literal(interpreter)}))')
    argv = ['/usr/bin/sandbox-exec', '-p', profile, str(interpreter), '-I', '-S', '-B', str(driver),
            str(framework), str(framework / STDLIB), str(bytecode)]
    incoming = json.dumps(sources, sort_keys=True).encode()
    (out / 'bytecode-compiler-input.json').write_bytes(incoming)
    with (out / 'bytecode-compiler.stdout').open('xb') as stdout, (out / 'bytecode-compiler.stderr').open('xb') as stderr:
        result = subprocess.run(argv, input=incoming, stdout=stdout, stderr=stderr, timeout=120,
            env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
    require(result.returncode == 0, 'Exact bundled bytecode compiler failed; raw output retained')
    require(inventory(framework) == before and sha(driver) == driver_digest, 'Compiler input changed')
    response = json.loads((out / 'bytecode-compiler.stdout').read_bytes())
    require(set(response) == {'schema', 'version', 'magic', 'members'}
            and response['schema'] == 'shadow-sync-runtime-bytecode/v1'
            and response['version'] == pin['version'] and response['magic'] == '2b0e0d0a',
            'Compiler response differs')
    archive = framework / STDLIB_ZIP
    members = write_stdlib_archive(framework / STDLIB, bytecode, archive, sources, response['members'])
    # Delete only exact source copies after full archive read-back. All native
    # modules, data files, licenses and reviewed framework links stay in place.
    for name, digest in sources.items():
        path = framework / STDLIB / name
        read_member(framework / STDLIB, name, digest)
        path.unlink()
    for name, row in sorted(before.items(), key=lambda p: len(PurePosixPath(p[0]).parts), reverse=True):
        path = framework / name
        if name.startswith(STDLIB + '/') and row['kind'] == 'directory' and not any(path.iterdir()):
            path.rmdir()
    manifest = {'schema': 'shadow-sync-stdlib-archive/v1', 'selection_recipe': RECIPE,
        'package_sha256': pin['package_sha256'], 'version': pin['version'], 'magic': response['magic'],
        'optimization': 0, 'invalidation': 'checked-hash', 'filename_prefix': '/shadow-sync-runtime/lib/python3.14/',
        'archive_sha256': sha(archive), 'members': members}
    path = framework / STDLIB_MANIFEST
    with path.open('x') as stream:
        json.dump(manifest, stream, sort_keys=True, indent=2); stream.write('\n')
    path.chmod(0o644)
    after = inventory(framework)
    for name, row in before.items():
        if name.startswith(STDLIB + '/') and (name.endswith('.py') or row['kind'] == 'directory' and name not in after):
            continue
        require(after.get(name) == row, 'Unrelated runtime entry changed during compaction')
    return {'driver_sha256': driver_digest, 'interpreter_sha256': interpreter_digest,
        'compiler_stdout_sha256': sha(out / 'bytecode-compiler.stdout'),
        'compiler_stderr_sha256': sha(out / 'bytecode-compiler.stderr'),
        'archive_sha256': sha(archive), 'manifest_sha256': sha(path), 'source_members': len(sources),
        'members': len(members)}


def build(args):
    require(sys.platform == "darwin", "macOS packaging tools are required")
    validate_publisher_configuration(args.publisher_team, args.allow_ad_hoc_fixture)
    pin = load_pin()
    notices = load_notice_bundle(pin)
    sign = signing_arguments(args.signing_identity, args.publisher_team, args.allow_ad_hoc_fixture)
    out = Path(args.output)
    require(out.is_absolute() and out.name not in {"", ".", ".."}, "Expected an absolute output path")
    require(out.parent.resolve(strict=True) == out.parent and not os.path.lexists(out),
            "Output must be new under a canonical existing parent")
    out.mkdir(mode=0o700)
    # All subprocesses consume this verified owner-private copy. Reopening the
    # caller's path for signature/extraction could consume transient replacements
    # even if the original bytes were restored before a final hash comparison.
    package = snapshot_package(Path(args.package), out, pin["package_bytes"], pin["package_sha256"])
    signature = run(["/usr/sbin/pkgutil", "--check-signature", str(package)])
    validate_upstream_signature(signature)
    (out / "upstream-signature.txt").write_text(signature)
    run(["/usr/sbin/pkgutil", "--expand-full", str(package), str(out / "expanded")], timeout=300)
    source = out / "expanded/Python_Framework.pkg/Payload"
    upstream_requirement = developer_id_requirement(pin["upstream_team"])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", upstream_requirement, str(source)])
    license_file = out / "expanded/Resources/License.rtf"
    require(sha(license_file) == pin["package_license_sha256"], "Unexpected upstream license")
    framework = out / "Python.framework"
    inputs = copy_selected(source, framework)
    resources = framework / "Versions/3.14/Resources"
    install_notice_snapshot(notices, resources)
    shutil.copyfile(license_file, resources / "Python-Package-License.rtf")
    (resources / "ShadowSyncRuntimeChanges.txt").write_text(
        "CPython 3.14.10, Python Software Foundation package.\n"
        "ShadowSync changes: select the reviewed non-GUI runtime; omit development, "
        "test and package-installer components; thin Mach-O objects to arm64; relocate "
        "internal library references; normalize permissions; compile checked-hash bytecode "
        "with the exact relocated interpreter and neutral filenames; preserve Python source "
        "and bytecode in a deterministic stored ZIP; re-sign modified code.\n"
        "This is not a system Python installation. The Python license and upstream "
        "package license remain included. Exact source-bound third-party notices "
        "are included in ThirdPartyNotices/; their manifest is sealed with this framework.\n")
    transformations = []
    for relative, row in sorted(inputs.items()):
        if row["kind"] != "file":
            continue
        path = framework / relative
        with path.open("rb") as stream:
            is_macho = stream.read(4) in MACHO_MAGIC
        if not is_macho:
            continue
        architectures = run(["/usr/bin/lipo", "-archs", str(path)]).strip().split()
        require(set(architectures) == {"arm64", "x86_64"}, "Unexpected upstream architecture set")
        temporary = path.with_name(path.name + ".arm64-staging")
        require(not os.path.lexists(temporary), "Unexpected thinning scratch")
        run(["/usr/bin/lipo", str(path), "-thin", "arm64", "-output", str(temporary)])
        temporary.chmod(path.stat().st_mode & 0o777)
        os.replace(temporary, path)
        changes = []
        for dependency in dependencies(path):
            replacement = dependency_replacement(dependency, path, framework)
            if replacement != dependency:
                changes.extend(["-change", dependency, replacement])
        ids = [line.strip() for line in run(["/usr/bin/otool", "-D", str(path)]).splitlines()
               if line.startswith(LEGACY)]
        require(len(ids) <= 1, "Unexpected install names")
        if ids:
            changes.extend(["-id", "@rpath/Python.framework/" + ids[0][len(LEGACY):]])
        if changes:
            run(["/usr/bin/install_name_tool", *changes, str(path)])
        run(["/usr/bin/codesign", "--force", *sign, str(path)])
        transformations.append({"path": relative, "upstream_sha256": row["sha256"],
                                "original_architectures": architectures, "load_command_changes": changes})
    # The earlier full prototype also contained config-3.14-darwin/python.o;
    # that development object is outside this selected runtime recipe.
    require(len(transformations) == 85, "Unexpected Mach-O inventory")
    nested = resources / "Python.app"
    run(["/usr/bin/codesign", "--force", *sign, "--identifier",
         "com.kleinperkins.shadow-sync.policy-helper", str(nested)])
    # A fully sealed intermediate is required before executing the exact bundled
    # compiler. No signing/library-validation exception or host compiler fallback.
    run(["/usr/bin/codesign", "--force", *sign, "--identifier",
         "com.kleinperkins.shadow-sync.python-runtime", str(framework)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(framework)])
    archive_receipt = compact_stdlib(framework, out, pin)
    layout_path = resources / "ShadowSyncRuntimeLayout.json"
    # The layout is sealed by the enclosing framework signature. It deliberately
    # contains node topology, not circular hashes of its own signature or the
    # framework executable. Code/resource authenticity uses codesign validation;
    # the external receipt binds every final file hash after all signing finishes.
    layout = {name: {key: value for key, value in row.items() if key in {"kind", "mode", "target"}}
              for name, row in inventory(framework).items()}
    layout[layout_path.relative_to(framework).as_posix()] = {"kind": "file", "mode": 0o644}
    layout["Versions/3.14/_CodeSignature"] = {"kind": "directory", "mode": 0o755}
    layout["Versions/3.14/_CodeSignature/CodeResources"] = {"kind": "file", "mode": 0o644}
    layout_path.write_text(json.dumps({"schema": "shadow-sync-policy-runtime-layout/v1",
        "source": pin, "entries": dict(sorted(layout.items()))}, sort_keys=True, indent=2) + "\n")
    layout_path.chmod(0o644)
    run(["/usr/bin/codesign", "--force", *sign, "--identifier",
         "com.kleinperkins.shadow-sync.python-runtime", str(framework)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(framework)])
    final = inventory(framework)
    require({name: {key: value for key, value in row.items() if key in {"kind", "mode", "target"}}
             for name, row in final.items()} == layout, "Signed layout differs from sealed layout")
    for transform in transformations:
        path = framework / transform["path"]
        require(run(["/usr/bin/lipo", "-archs", str(path)]).strip() == "arm64", "Architecture drift")
        linked = dependencies(path)
        require(all(item.startswith(("@loader_path/", "@rpath/Python.framework/", "/usr/lib/", "/System/Library/"))
                    for item in linked), "Unrelocated library dependency")
        metadata = run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)])
        if args.allow_ad_hoc_fixture:
            require("Signature=adhoc" in metadata and "TeamIdentifier=not set" in metadata,
                    "Fixture identity changed")
        else:
            require("runtime" in metadata, "Missing hardened runtime")
        entitlements = run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)])
        require("<key>" not in entitlements, "Unexpected runtime entitlements")
        if args.publisher_team:
            requirement = developer_id_requirement(args.publisher_team)
            run(["/usr/bin/codesign", "--verify", "--strict", "-R", requirement, str(path)])
            require("Timestamp=" in metadata, "Missing signing timestamp")
    require(sha(package) == pin["package_sha256"], "Package changed during build")
    receipt = {"schema": "shadow-sync-policy-runtime-build/v1", "source": pin,
               "builder_sha256": sha(Path(__file__)), "source_pin_sha256": sha(PIN_PATH),
               "signature_mode": "ad-hoc-fixture" if args.allow_ad_hoc_fixture else "Developer-ID",
               "publisher_team": args.publisher_team, "architecture": "arm64",
               "hardened_runtime_qualified": False,
               "input_entries": inputs, "transformations": transformations, "output_entries": final,
               "layout_sha256": sha(layout_path), "notarized": False,
               "installed": False, "third_party_notice_qualification": "source-bound-content-verified",
               "notices_manifest_sha256": pin["notices_manifest_sha256"],
               "stdlib_archive": archive_receipt}
    (out / "runtime-build.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"framework": str(framework), "mach_o_count": len(transformations),
        "entries": len(final), "architecture": "arm64", "signature_mode": receipt["signature_mode"],
        "receipt_sha256": sha(out / "runtime-build.json"), "installed": False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--signing-identity", required=True)
    parser.add_argument("--publisher-team")
    parser.add_argument("--allow-ad-hoc-fixture", action="store_true")
    args = parser.parse_args()
    try:
        build(args)
    except (BuildRefused, OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"Runtime build refused: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
