"""Closed native-fixture journal and read-only macOS process identity checks."""
import ctypes
import errno
import json
import os
import stat
import uuid

SCHEMA = 'shadow-sync-native-fixture/v1'
IDENTITY = {'processID', 'processGroupID', 'userID', 'startSeconds',
            'startMicroseconds', 'executablePath', 'generation'}
def require(ok, why):
    if not ok:
        raise ValueError(why)

def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key')
        result[key] = value
    return result

def consume(event, roles, executable, uid, seen, reaped, generations, physical):
    require(type(event) is dict and event.get('schema') == SCHEMA, 'event schema')
    kind = event.get('event')
    require(kind in {'spawn', 'reap'}, 'event type')
    keys = {'schema', 'event', 'role', 'identity'} | ({'status'} if kind == 'reap' else set())
    require(set(event) == keys, 'event fields')
    role = event['role']
    require(type(role) is str and role in roles, 'unexpected role')
    ident = event['identity']
    require(type(ident) is dict and set(ident) == IDENTITY, 'identity fields')
    for key in IDENTITY - {'executablePath', 'generation'}:
        require(type(ident[key]) is int, 'integer identity')
    require(ident['processID'] > 1 and ident['processGroupID'] == ident['processID']
            and ident['userID'] == uid and ident['startSeconds'] > 0
            and 0 <= ident['startMicroseconds'] < 1000000, 'identity values')
    require(ident['executablePath'] == executable, 'executable identity')
    generation = ident['generation']
    require(type(generation) is str and str(uuid.UUID(generation)) == generation, 'generation')
    if kind == 'spawn':
        key = (ident['processID'], ident['startSeconds'], ident['startMicroseconds'])
        require(role not in seen and generation not in generations and key not in physical, 'duplicate spawn')
        seen[role] = ident
        generations.add(generation)
        physical.add(key)
    else:
        require(role in seen and role not in reaped and ident == seen[role], 'unmatched reap')
        require(type(event['status']) is int and 0 <= event['status'] <= 65535, 'wait status')
        status = event['status']
        require(status & 0xff == 0 or (status >> 8 == 0 and 0 < status & 0x7f < 0x7f), 'nonterminal wait status')
        reaped.add(role)


def parse(raw, roles, executable, uid):
    require(type(raw) is bytes and len(raw) <= 32768, 'journal size')
    if not roles:
        require(raw == b'', 'unexpected helper records')
        return []
    require(raw.endswith(b'\n') and raw.count(b'\n') == 2 * len(roles), 'exact helper record count')
    seen, reaped, generations, physical = {}, set(), set(), set()
    for line in raw.splitlines():
        consume(json.loads(line, object_pairs_hook=unique), roles, executable, uid,
                seen, reaped, generations, physical)
    require(set(seen) == set(roles) == reaped, 'incomplete helper coverage')
    return list(seen.values())


def recovery_identities(raw, roles, executable, uid):
    """Validate a journal prefix for observation only; never substitutes for parse."""
    seen, reaped, generations, physical = {}, set(), set(), set()
    error = None
    try:
        require(type(raw) is bytes and len(raw) <= 32768, 'journal size')
        for line in raw.splitlines(keepends=True):
            require(line.endswith(b'\n'), 'incomplete journal frame')
            consume(json.loads(line, object_pairs_hook=unique), roles, executable, uid,
                    seen, reaped, generations, physical)
        require(set(seen) == set(roles) == reaped, 'incomplete helper coverage')
    except (ValueError, TypeError, KeyError) as failure:
        error = str(failure)
    return {'known_identities': list(seen.values()), 'journal_error': error}


def read(root):
    parent = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    fd = None
    def identity(info):
        return (info.st_dev, info.st_ino, info.st_uid, info.st_mode, info.st_nlink,
                info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    try:
        owner = os.fstat(parent)
        require(stat.S_ISDIR(owner.st_mode) and owner.st_uid == os.getuid()
                and stat.S_IMODE(owner.st_mode) == 0o700, 'unsafe journal directory')
        try:
            fd = os.open('native-fixture.jsonl', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                         | os.O_CLOEXEC, dir_fd=parent)
        except FileNotFoundError:
            return b''
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600
                and info.st_size <= 32768, 'unsafe journal file')
        data = os.read(fd, 32769)
        require(len(data) == info.st_size and identity(info) == identity(os.fstat(fd))
                == identity(os.stat('native-fixture.jsonl', dir_fd=parent, follow_symlinks=False)),
                'journal changed while reading')
        after = os.stat(root, follow_symlinks=False)
        require((owner.st_dev, owner.st_ino, owner.st_uid, owner.st_mode)
                == (after.st_dev, after.st_ino, after.st_uid, after.st_mode), 'journal root changed')
        return data
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)

class BSDInfo(ctypes.Structure):
    # macOS SDK sys/proc_info.h: full structure, not proc_pidpath absence.
    _fields_ = [(name, ctypes.c_uint32) for name in
                ('flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','reserved')]
    _fields_ += [('comm',ctypes.c_char*16),('name',ctypes.c_char*32)]
    _fields_ += [(name,ctypes.c_uint32) for name in ('nfiles','pgid','jobc','tdev','tpgid')]
    _fields_ += [('nice',ctypes.c_int32),('startSeconds',ctypes.c_uint64),('startMicroseconds',ctypes.c_uint64)]

def original_absent(identity):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    info = BSDInfo()
    ctypes.set_errno(0)
    size = library.proc_pidinfo(identity['processID'],3,0,ctypes.byref(info),ctypes.sizeof(info))
    if size == 0 and ctypes.get_errno() == errno.ESRCH:
        return True
    require(size == ctypes.sizeof(info) and info.pid == identity['processID']
            and info.startSeconds > 0 and info.startMicroseconds < 1000000,
            'process observation unavailable or malformed')
    # Same start identity, including a zombie, is still present.
    return (info.startSeconds,info.startMicroseconds) != (identity['startSeconds'],identity['startMicroseconds'])
