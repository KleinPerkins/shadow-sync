#!/usr/bin/env python3
"""Closed build-time compiler, executed by the exact relocated bundled Python.

Never used by the installed application. All source members stay in the signed
archive; neutral code filenames and checked hashes make bytecode reproducible.
The parent confines writes to a new private output and forbids child processes.
"""
import hashlib
import importlib.util
import json
import marshal
from pathlib import Path, PurePosixPath
import py_compile
import re
import sys
import types

PREFIX = "/shadow-sync-runtime/lib/python3.14/"
MAGIC = bytes.fromhex("2b0e0d0a")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def member_name(name):
    return (isinstance(name, str) and 0 < len(name) <= 512
            and re.fullmatch(r"[A-Za-z0-9_.\-/]+\.py", name) is not None
            and not name.startswith("/") and "//" not in name
            and all(p not in {".", ".."} for p in name.split("/")))


def verify_filenames(code, filename):
    require(isinstance(code, types.CodeType) and code.co_filename == filename,
            "Unbound bytecode filename")
    for value in code.co_consts:
        if isinstance(value, types.CodeType):
            verify_filenames(value, filename)


def compile_members(root, output, members):
    require(isinstance(members, dict) and 1 <= len(members) <= 1024,
            "Invalid member inventory")
    result = {}
    for name, expected in sorted(members.items()):
        require(member_name(name) and re.fullmatch(r"[0-9a-f]{64}", expected) is not None,
                "Invalid source member")
        source = root / name
        require(source.resolve(strict=True) == source and source.is_file()
                and source.stat().st_nlink == 1, "Redirected source member")
        data = source.read_bytes()
        require(hashlib.sha256(data).hexdigest() == expected, "Source bytes differ")
        target = output / (name + "c")
        target.parent.mkdir(parents=True, exist_ok=True)
        require(not target.exists() and not target.is_symlink(), "Bytecode already exists")
        filename = PREFIX + name
        py_compile.compile(str(source), cfile=str(target), dfile=filename, doraise=True,
                           optimize=0, invalidation_mode=py_compile.PycInvalidationMode.CHECKED_HASH)
        compiled = target.read_bytes()
        require(compiled[:4] == MAGIC and compiled[4:8] == b"\x03\0\0\0"
                and compiled[8:16] == importlib.util.source_hash(data), "Invalid bytecode header")
        verify_filenames(marshal.loads(compiled[16:]), filename)
        require(source.read_bytes() == data, "Source changed during compilation")
        result[name] = {"source_sha256": expected, "bytecode_sha256": hashlib.sha256(compiled).hexdigest(),
                        "source_hash": compiled[8:16].hex(), "bytecode_bytes": len(compiled)}
    return result


def main():
    require(sys.version_info[:3] == (3, 14, 10) and importlib.util.MAGIC_NUMBER == MAGIC,
            "Wrong compiler version")
    require(sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode,
            "Compiler isolation flags missing")
    require(len(sys.argv) == 4, "Unexpected compiler arguments")
    framework, root, output = map(Path, sys.argv[1:])
    require(all(p.is_absolute() and p.resolve(strict=True) == p for p in [framework, root, output]),
            "Noncanonical compiler roots")
    require(root == framework / "Versions/3.14/lib/python3.14"
            and Path(sys.executable).resolve(strict=True) == framework / "Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
            and not any(output.iterdir()), "Compiler root binding differs")
    require(all(Path(p).is_absolute() and Path(p).resolve().is_relative_to(framework) for p in sys.path),
            "External import path")
    raw = sys.stdin.buffer.read(262145)
    require(len(raw) <= 262144, "Oversize compiler inventory")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate source member")
            result[key] = value
        return result
    result = compile_members(root, output, json.loads(raw, object_pairs_hook=unique))
    for name, module in list(sys.modules.items()):
        path = getattr(module, "__file__", None)
        if path is not None and name != "__main__" and not path.startswith("<"):
            require(Path(path).resolve().is_relative_to(framework), "External compiler module")
    print(json.dumps({"schema": "shadow-sync-runtime-bytecode/v1", "version": "3.14.10",
                      "magic": MAGIC.hex(), "members": result}, sort_keys=True))


if __name__ == "__main__":
    main()
