#!/usr/bin/env python3
"""Read-only negative-control assessment. Never changes the failed raw receipt.

Only a separately reviewed, source-bound signed caller may supply these sealed
inputs. File hashes bind evidence; they do not authenticate a caller or qualify
native execution. No launch, poll, signal, repair or namespace disposal exists.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from guardian_protocol import GuardianProtocol

PREFIX = b'SIGNED_JOIN_CONTROL_V1 '
SCHEMA = 'shadow-sync-signed-join-control/v1'
SUFFIXES = ('fault-before-bind', 'fault-after-ack', 'fault-before-join', 'fault-after-refusal', 'h-expiry')
CASES = tuple('signed-installation/start-adapter-join/' + x for x in SUFFIXES)
KEYS = frozenset(('schema', 'case', 'nonce', 'source_sha256', 'executable_sha256', 'app_sha256',
    'request_sha256', 'transaction_digest', 'cut', 'reached_ns', 'deadlines', 'command', 'holds',
    'joins', 'product', 'fixture', 'cleanup', 'evidence'))
U64 = (1 << 64) - 1


class Refusal(ValueError):
    pass


def require(value, reason):
    if not value:
        raise Refusal(reason)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def decode(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            require(key not in value, 'duplicate-json-key')
            value[key] = item
        return value
    return json.loads(raw, object_pairs_hook=pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(Refusal('nonfinite-json')))


def uint(value):
    return type(value) is int and 0 <= value <= U64


def hex64(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None


def array(value, count, label):
    require(type(value) is list and len(value) == count, label)
    return value


def serialize_report(value):
    """Same sorted compact UTF-8 encoding as the source reporter; no truncation."""
    raw = PREFIX + encode(value) + b'\n'
    require(len(raw) <= 4096, 'report-size')
    return raw


def parse_report(stderr):
    require(type(stderr) is bytes and len(stderr) <= 4_194_304, 'stderr-size')
    # No unexpected diagnostic output is silently ignored for these closed controls.
    require(stderr.startswith(PREFIX) and stderr.endswith(b'\n') and stderr.count(b'\n') == 1
            and len(stderr) <= 4096, 'single-bounded-report')
    value = decode(stderr[len(PREFIX):-1])
    require(type(value) is dict and set(value) == KEYS and value['schema'] == SCHEMA, 'report-fields')
    require(serialize_report(value) == stderr, 'canonical-report')
    validate_report(value)
    return value


def validate_report(v):
    """All positions and allowed enum/mask bits are closed, row-specific predicates.

    deadlines=[C,H,work,TERM,KILL,receipt,effectiveReceipt,operation,cap].
    command=null or [requestDigest, identityMask=1023]: original context/root/
      controller/channel/request/handle/record/resource/ticket/helper equal.
    holds=[[entry,return,result,firstExplicitRelease] x2,emergency]; result=1
      signalled,2 timedOut, null only when no selected command (before bind).
    joins=[[purpose(0 registry,1 teardown),deadline,entry,result(0/1)]], <=32.
    product=[outcome(0 absent,1 ordinary,2 cleanup-only,3 uncertain,4 H),
      invocation(0 absent,1 success,2 expiry-refusal,3 typed-H),
      body(0 absent,1 success,3 typed-H),ledgerMask]. ledger bits: checkedClose,
      exactRemoval,issuance,seal,delivered; only 0/3/31 are eligible.
    fixture=[0 failed,cut]. cleanup=[rootFinishTime,127,entries,order,reservedIDs,
      outputEntries,outputReserved,disposal(0 none,1 exact uncertain)]. 127 proves
      root finish/work/service/readiness/endpoint/original helper/accounting.
    evidence=[three durable hashes or [],eventMask,31]. Events 0 none,3 before/
      afterRead,15 before/afterRead/checkedClose/removed, ordered source-side.
      31 means fixed durable comparison/token refusal/fence/aliases/no error;
      absent/ordinary cases have no negative durable/token assertions.
    """
    require(v['case'] in CASES, 'fixed-control')
    cut = CASES.index(v['case'])
    require(type(v['cut']) is int and v['cut'] == cut, 'cut-binding')
    require(type(v['nonce']) is str and re.fullmatch('[0-9a-f]{32}', v['nonce']), 'nonce')
    require(all(hex64(v[k]) for k in ('source_sha256', 'executable_sha256', 'app_sha256',
        'request_sha256', 'transaction_digest')), 'binding-digest')
    d = array(v['deadlines'], 9, 'deadlines')
    C, H = d[:2]
    require(uint(C) and uint(H) and C > 3_000_000_000 and H == C - 3_000_000_000, 'original-H-C')
    reached = v['reached_ns']
    require(uint(reached) and 0 < reached < C, 'reached-time')
    if cut == 0:
        require(d[2:] == [None] * 7 and v['command'] is None and reached < H, 'before-bind-no-command')
        cap = None
    else:
        require(all(uint(x) and x > 0 for x in d), 'deadline-types')
        work, term, kill, receipt, effective, operation, cap = d[2:]
        require(work <= term <= kill <= receipt < H and effective <= receipt and operation == C
                and cap == min(effective, operation), 'original-cap-tuple')
        command = array(v['command'], 2, 'command')
        require(hex64(command[0]) and type(command[1]) is int and command[1] == 1023, 'command-identities')
        require((reached < cap if cut == 1 else cap <= reached < (C if cut == 4 else H)), 'cut-time')
    hold = array(v['holds'], 3, 'holds')
    require(type(hold[2]) is int and hold[2] == (1 if cut == 4 else 0), 'sticky-emergency')
    for row in hold[:2]:
        entry, returned, result, release = array(row, 4, 'hold-row')
        require(uint(release) and reached <= release < C, 'explicit-owner-release')
        if cut == 0:
            require([entry, returned, result] == [None] * 3, 'before-bind-no-wait')
        else:
            require(uint(entry) and uint(returned) and 0 < entry < H and entry <= returned < C, 'actual-wait-times')
            require(type(result) is int and result == (2 if cut == 4 else 1), 'actual-wait-result')
            if cut == 4:
                require(H <= returned <= reached <= release, 'both-real-timeouts-before-release')
            else:
                require(entry <= reached <= release <= returned < H, 'signal-after-cut')
    joins = v['joins']
    require(type(joins) is list and len(joins) <= 32, 'bounded-joins')
    for row in joins:
        purpose, deadline, entry, result = array(row, 4, 'join-row')
        require(type(purpose) is int and purpose in (0, 1) and type(result) is int and result in (0, 1)
                and uint(deadline) and uint(entry) and 0 < entry < C, 'join-values')
        require(deadline == (cap if purpose == 0 else C), 'join-original-deadline')
        if purpose == 1:
            require(result == 1 and entry >= reached, 'actual-successful-teardown')
    registry = [row for row in joins if row[0] == 0]
    product, invocation, body, ledger = array(v['product'], 4, 'product')
    require(all(type(x) is int for x in v['product']), 'product-types')
    eligible = {0: [(0, 0, 0, 0)], 1: [(1, 1, 1, 31)], 2: [(2, 2, 1, 3), (3, 2, 1, 0)],
                3: [(3, 2, 1, 0)], 4: [(4, 3, 3, 3)]}
    require(tuple(v['product']) in eligible[cut], 'actual-product-outcome')
    require(v['fixture'] == [0, cut] and all(type(x) is int for x in v['fixture']), 'failed-subject')
    cleanup = array(v['cleanup'], 8, 'cleanup')
    finish, mask, entries, order, reservations, output_entries, output, disposal = cleanup
    require(all(uint(x) for x in cleanup) and reached <= finish < C and mask == 127
            and [entries, order, reservations, output_entries, output] == [0] * 5
            and disposal == (1 if product == 3 else 0), 'checked-root-cleanup')
    require(all(row[2] <= finish for row in joins) and all(row[3] <= finish for row in hold[:2]), 'cleanup-order')
    if cut == 0:
        require(not joins, 'before-bind-no-selected-join')
    else:
        require(len(registry) == 1 and joins[0][0] == 0 and any(row[0] == 1 for row in joins)
                and all(row[2] >= registry[0][2] for row in joins if row[0] == 1), 'one-registry-real-teardown')
        _, _, entered, succeeded = registry[0]
        require(succeeded == (0 if product == 3 else 1), 'measured-join-result')
        if cut == 1:
            require(reached <= entered < cap, 'ordinary-original-cap')
        else:
            require(entered >= cap, 'expired-original-cap')
            require((entered <= reached if cut == 3 else entered >= reached), 'cut-join-order')
        if cut == 4:
            require(entered >= max(row[1] for row in hold[:2]), 'H-completion-before-registry')
    hashes, events, mask = array(v['evidence'], 3, 'evidence')
    require(type(hashes) is list and len(hashes) == (3 if cut >= 2 else 0)
            and all(hex64(x) for x in hashes), 'durable-digests')
    require(type(events) is int and events == (3 if product == 3 else 15 if product in (2, 4) else 0)
            and type(mask) is int and mask == 31, 'event-proof-mask')
    return product


STREAMS = ('guardian', 'status', 'stdout', 'stderr')
ARTIFACTS = ('request', 'source_map', 'registration', 'package', 'executable', 'app', 'caller', *STREAMS)
CALLER_KEYS = frozenset(('schema', 'case', 'nonce', 'source_sha256', 'executable_sha256', 'app_sha256',
    'request_sha256', 'package_sha256', 'registration_sha256', 'caller_source_sha256', 'root_sha256',
    'transaction_digest', 'deadlines', 'command_digest', 'stderr_nonblocking_before_spawn', 'prepared_ns',
    'spawned_ns', 'report_received_ns', 'reaped_ns', 'finished_ns', 'exit', 'signal', 'errors', 'passed',
    'coordinator_reaped', 'eof', 'checked_closed', 'cleanup_pending', 'automatic_termination',
    'transport_failure', 'deadline_failure', 'interrupted', 'streams'))


def evaluate(raw, expected):
    """Assess immutable in-memory sealed inputs. Original caller schema is explicit.

    expected is independently pinned by the invoking reviewed caller contract:
    case, package_sha256, source_sha256, caller_source_sha256. This evaluator
    cannot establish that review or turn a synthetic caller into native evidence.
    """
    require(set(raw) == set(ARTIFACTS) and all(type(v) is bytes for v in raw.values()), 'artifact-roster')
    require(set(expected) == {'case', 'package_sha256', 'source_sha256', 'caller_source_sha256'}
            and expected['case'] in CASES and all(hex64(expected[k]) for k in expected if k != 'case'), 'expected-bindings')
    hashes = {k: digest(v) for k, v in raw.items()}
    base = dict(schema='shadow-sync-signed-negative-assessment/v1', assessment='failed', subject_passed=False,
        guardian_outcome=None, subject_exit=None, raw_sha256=hashes, case=expected['case'],
        source_sha256=expected['source_sha256'], package_sha256=expected['package_sha256'])
    try:
        caller = decode(raw['caller'])
        require(type(caller) is dict and set(caller) == CALLER_KEYS
                and caller['schema'] == 'shadow-sync-signed-negative-caller/v1', 'caller-schema')
        base['subject_exit'] = caller['exit'] if type(caller['exit']) is int else None
        require(caller['passed'] is False and type(caller['exit']) is int and caller['exit'] == 1
                and caller['signal'] is None and caller['errors'] == [], 'raw-failed-subject')
        require(caller['coordinator_reaped'] is True and caller['eof'] == list(STREAMS)
                and caller['checked_closed'] == list(STREAMS) and caller['cleanup_pending'] is False,
                'pending-caller-custody')
        require(all(caller[k] is False for k in ('automatic_termination', 'transport_failure', 'deadline_failure', 'interrupted')),
                'caller-failure')
        require(caller['stderr_nonblocking_before_spawn'] is True, 'pre-spawn-nonblocking')
        require(caller['streams'] == {k: hashes[k] for k in STREAMS}, 'raw-stream-bindings')
        require(all(caller[k] == expected[k] for k in expected), 'pinned-bindings')
        require(caller['package_sha256'] == hashes['package'] and caller['source_sha256'] == hashes['source_map']
                and caller['request_sha256'] == hashes['request'] and caller['registration_sha256'] == hashes['registration']
                and caller['executable_sha256'] == hashes['executable'] and caller['app_sha256'] == hashes['app'], 'artifact-bindings')
        source = decode(raw['source_map'])
        require(type(source) is dict and 0 < len(source) <= 8192
                and source['config/signed-installation-fixtures.json']['sha256'] == hashes['registration']
                and source['scripts/signed-fixture-negative-report.py']['sha256'] == digest(Path(__file__).read_bytes()), 'source-registration-evaluator')
        request = decode(raw['request'])
        require(set(request) == {'schema', 'case', 'root', 'nonce', 'deadline', 'source', 'executable', 'app',
            'bundle', 'release', 'appCDHash', 'helperCDHash', 'rootDisposition'} and request['schema'] == 'shadow-sync-signed-installation-request/v1', 'request-schema')
        require(request['rootDisposition'] == 'creator-after-coordinator-reap' and request['case'] == caller['case'] and request['nonce'] == caller['nonce']
                and digest(request['root'].encode()) == caller['root_sha256']
                and request['source'] == caller['source_sha256'] and request['executable'] == caller['executable_sha256']
                and request['app'] == caller['app_sha256'], 'original-request')
        package = decode(raw['package']); registration = decode(raw['registration'])
        require(package['schema'] == 'shadow-sync-signed-fixture-package/v1' and package['profile'] == 'signed-installation/v1'
                and package['build_mode'] == 'testing' and package['signature_mode'] == 'Developer-ID'
                and package['source_map_sha256'] == hashes['source_map'] and package['registration_sha256'] == hashes['registration']
                and package['app_sha256'] == hashes['app'] and package['bundle_sha256'] == request['bundle']
                and package['app_cdhash'] == request['appCDHash'] and package['helper_cdhash'] == request['helperCDHash']
                and package['release'] == request['release'], 'sealed-package')
        entry = package['entries']['Contents/Helpers/ShadowSyncLifecycleCoordinator']
        require(entry['kind'] == 'file' and entry['sha256'] == hashes['executable'] and entry['bytes'] == len(raw['executable']), 'sealed-coordinator')
        require(registration['schema'] == 'shadow-sync-signed-installation-fixtures/v1', 'registration')
        ids = [row['id'] for row in registration['cases']]
        require(len(ids) == len(set(ids)) and all(case in ids for case in CASES), 'registered-controls')
        rows = [row for row in registration['cases'] if row['id'] == caller['case']]
        require(rows == [dict(id=caller['case'], suite='signed-installation-adapter',
            argument='--verify-signed-installation-fixture', kind='installation-cut')], 'registered-negative-row')
        require(all(case not in {r['id'] for r in registration['unavailable_requirements']} for case in CASES), 'unavailable-control')
        require(raw['stdout'] == b'' and raw['status'] == b'', 'unexpected-output')
        report = parse_report(raw['stderr'])
        require(all(report[k] == caller[k] for k in ('case', 'nonce', 'source_sha256', 'executable_sha256',
            'app_sha256', 'request_sha256', 'transaction_digest', 'deadlines')), 'report-caller-bindings')
        require((report['command'][0] if report['command'] else None) == caller['command_digest'], 'original-command-digest')
        C = report['deadlines'][0]
        require(request['deadline'] == C, 'original-C')
        times = [caller[k] for k in ('prepared_ns', 'spawned_ns', 'report_received_ns', 'reaped_ns', 'finished_ns')]
        require(all(uint(x) and 0 < x < C for x in times) and times == sorted(times)
                and times[0] < times[1] <= report['reached_ns'] <= report['cleanup'][0] <= times[2], 'original-caller-times')
        guardian = GuardianProtocol('signed-installation-adapter', [caller['case']], caller['nonce'],
            caller['source_sha256'], caller['executable_sha256'], caller['app_sha256'])
        guardian.feed(raw['guardian'])
        base['guardian_outcome'] = guardian.terminal['outcome'] if guardian.terminal else None
        require(guardian.finish(caller['exit']) is False and guardian.cancelled == 'assertion'
                and guardian.begun == {caller['case']} and not guardian.passed
                and guardian.terminal['outcome'] == 'failed' and guardian.terminal['failed_spawns'] == 0, 'failed-guardian')
        base.update(assessment='qualified-negative', product_outcome=('no-selected-command', 'ordinary-in-budget',
            'expired-cleanup-only', 'expired-join-refused', 'two-H-body-failures')[report['product'][0]],
            cleanup_outcome='exact-expired-uncertain-disposal' if report['cleanup'][7] else 'original-root-finished',
            coverage_row=caller['case'], ordinary_positive=False, broader_pending_retirement=False)
    except (ValueError, KeyError, TypeError, IndexError, RecursionError) as error:
        base['reason'] = str(error)
        if str(error) in ('pending-caller-custody', 'missing or incomplete terminal'):
            base['assessment'] = 'pending'
    return base


def read_bound(row, limit=128 * 1024 * 1024):
    require(type(row) is dict and set(row) == {'path', 'sha256', 'size', 'mode'}, 'file-binding')
    path = Path(row['path'])
    require(path.is_absolute() and path.resolve(strict=True) == path, 'canonical-file')
    before = path.lstat()
    identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid == os.getuid()
            and 0 <= before.st_size <= limit and stat.S_IMODE(before.st_mode) == row['mode'], 'regular-owned-file')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        require(identity(os.fstat(fd)) == identity(before), 'file-replaced')
        chunks = []; total = 0
        while True:
            block = os.read(fd, min(65536, limit + 1 - total))
            if not block: break
            chunks.append(block); total += len(block)
            require(total <= limit, 'file-limit')
        data = b''.join(chunks)
        require(identity(os.fstat(fd)) == identity(before) == identity(path.lstat())
                and len(data) == row['size'] == before.st_size and digest(data) == row['sha256'], 'file-changed')
        return data
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True)
    parser.add_argument('--input-sha256', required=True)
    args = parser.parse_args()
    p = Path(args.input); info = p.lstat()
    envelope = decode(read_bound(dict(path=str(p), sha256=args.input_sha256, size=info.st_size, mode=stat.S_IMODE(info.st_mode)), 65536))
    require(set(envelope) == {'schema', 'expected', 'artifacts', 'source_root'}
            and envelope['schema'] == 'shadow-sync-signed-negative-input/v1', 'input-schema')
    require(set(envelope['artifacts']) == set(ARTIFACTS), 'artifact-roster')
    raw = {key: read_bound(row, 4_194_304 if key in STREAMS else 128 * 1024 * 1024)
           for key, row in envelope['artifacts'].items()}
    # Verify the complete original source map with exact mode/size/hash, no imports.
    root = Path(envelope['source_root']); rows = decode(raw['source_map'])
    require(root.is_absolute() and root.resolve(strict=True) == root and type(rows) is dict and 0 < len(rows) <= 8192, 'source-root')
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if not p.is_dir()}
    require(actual == set(rows), 'source-inventory')
    for relative, row in rows.items():
        require(not Path(relative).is_absolute() and '..' not in Path(relative).parts and set(row) == {'sha256', 'size', 'mode'}, 'source-path')
        read_bound(dict(path=str(root / relative), **row))
    result = evaluate(raw, envelope['expected'])
    # Output is a NEW assessment only; no file writing or original receipt editing.
    print(encode(result).decode())
    return 0 if result['assessment'] == 'qualified-negative' else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(json.dumps({'assessment': 'failed', 'subject_passed': False, 'reason': str(error)}))
        raise SystemExit(1)
