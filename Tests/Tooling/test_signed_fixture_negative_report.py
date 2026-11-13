"""Synthetic sealed evidence only; no signed process/timing/cleanup is simulated as fact."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
SPEC = importlib.util.spec_from_file_location('signed_fixture_negative_report', ROOT / 'scripts/signed-fixture-negative-report.py')
negative = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(negative)


def report(cut, uncertain=False, maximum=False):
    C = negative.U64 if maximum else 40_000_000_000
    H = C - 3_000_000_000; cap = C - 4_000_000_000
    reached = cap - 1_000_000 if cut == 1 else cap + 1_000_000
    if cut == 0: reached = cap - 1_000_000
    if cut == 4: reached = H + 1_000_000
    release = reached + 1000; returned = release + 1000
    finish = C - 1_000_000
    product = (0, 1, 3 if uncertain else 2, 3, 4)[cut]
    inv, body, ledger = {0: (0, 0, 0), 1: (1, 1, 31), 2: (2, 1, 3), 3: (2, 1, 0), 4: (3, 3, 3)}[product]
    h = [None, None, None, release] if cut == 0 else [cap - 2_000_000, H + 1 if cut == 4 else returned, 2 if cut == 4 else 1, release]
    entry = reached - 100 if cut == 3 else reached + 3000
    joins = [] if cut == 0 else [[0, cap, entry, 0 if product == 3 else 1], [1, C, finish - 1000, 1]]
    if maximum and cut != 0: joins += [[1, C, finish - 1000, 1] for _ in range(30)]
    return dict(schema=negative.SCHEMA, case=negative.CASES[cut], nonce='1' * 32,
        source_sha256='2' * 64, executable_sha256='3' * 64, app_sha256='4' * 64,
        request_sha256='5' * 64, transaction_digest='6' * 64, cut=cut, reached_ns=reached,
        deadlines=[C, H] + ([None] * 7 if cut == 0 else [cap - 3000, cap - 2000, cap - 1000, cap, cap, C, cap]),
        command=None if cut == 0 else ['7' * 64, 1023], holds=[h.copy(), h.copy(), 1 if cut == 4 else 0], joins=joins,
        product=[product, inv, body, ledger], fixture=[0, cut], cleanup=[finish, 127, 0, 0, 0, 0, 0, 1 if product == 3 else 0],
        evidence=[['8' * 64, '9' * 64, 'a' * 64] if cut >= 2 else [], 3 if product == 3 else 15 if product in (2, 4) else 0, 31])


def evidence(cut, uncertain=False):
    v = report(cut, uncertain)
    encode, digest = negative.encode, negative.digest
    raw = {'executable': b'synthetic coordinator', 'app': b'synthetic app', 'source_map': b'{}'}
    for key in ('source_map', 'executable', 'app'):
        v[{'source_map': 'source_sha256', 'executable': 'executable_sha256', 'app': 'app_sha256'}[key]] = digest(raw[key])
    registration = json.loads((ROOT / 'config/signed-installation-fixtures.json').read_text())
    raw['registration'] = encode(registration)
    raw['source_map'] = encode({'config/signed-installation-fixtures.json': dict(sha256=digest(raw['registration']), size=len(raw['registration']), mode=420),
        'scripts/signed-fixture-negative-report.py': dict(sha256=digest(Path(negative.__file__).read_bytes()), size=Path(negative.__file__).stat().st_size, mode=493)})
    v['source_sha256'] = digest(raw['source_map'])
    release = dict(buildMode='testing', sourceInputSHA256=v['source_sha256'])
    request = dict(schema='shadow-sync-signed-installation-request/v1', case=v['case'], root='/fixture-owner/root',
        nonce=v['nonce'], deadline=v['deadlines'][0], source=v['source_sha256'], executable=v['executable_sha256'],
        app=v['app_sha256'], bundle='b' * 64, release=release, appCDHash='c' * 40, helperCDHash='d' * 40,
        rootDisposition='creator-after-coordinator-reap')
    raw['request'] = encode(request); v['request_sha256'] = digest(raw['request'])
    package = dict(schema='shadow-sync-signed-fixture-package/v1', profile='signed-installation/v1', build_mode='testing',
        signature_mode='Developer-ID', source_map_sha256=v['source_sha256'], registration_sha256=digest(raw['registration']),
        app_sha256=v['app_sha256'], bundle_sha256=request['bundle'], app_cdhash=request['appCDHash'],
        helper_cdhash=request['helperCDHash'], release=release,
        entries={'Contents/Helpers/ShadowSyncLifecycleCoordinator': dict(kind='file', sha256=v['executable_sha256'], bytes=len(raw['executable']))})
    raw['package'] = encode(package)
    counts = dict(spawned=2, reaped=2, failed_spawns=0, reservations=0, children=0, callbacks=0)
    frames = [dict(event='ready', expected_cases=1, probe='none', **{k:v[k] for k in ('source_sha256', 'executable_sha256', 'app_sha256')}),
        dict(event='case_start', case=v['case']), dict(event='cancelled', reason='assertion'),
        dict(event='case_failed', case=v['case'], **counts),
        dict(event='terminal', outcome='failed', reason='assertion', expected_cases=1, begun_cases=1, passed_cases=0, **counts)]
    raw['guardian'] = b''.join(encode(dict(schema=negative.GuardianProtocol.SCHEMA, suite='signed-installation-adapter',
        nonce=v['nonce'], sequence=i, **frame))+b'\n' for i,frame in enumerate(frames))
    raw['stdout'] = raw['status'] = b''; raw['stderr'] = negative.serialize_report(v)
    caller = {k:v[k] for k in ('case', 'nonce', 'source_sha256', 'executable_sha256', 'app_sha256',
        'request_sha256', 'transaction_digest', 'deadlines')}
    caller.update(schema='shadow-sync-signed-negative-caller/v1', package_sha256=digest(raw['package']),
        registration_sha256=digest(raw['registration']), caller_source_sha256='e' * 64, root_sha256=digest(request['root'].encode()),
        command_digest=v['command'][0] if v['command'] else None, stderr_nonblocking_before_spawn=True,
        prepared_ns=1, spawned_ns=2, report_received_ns=v['cleanup'][0]+1, reaped_ns=v['cleanup'][0]+2,
        finished_ns=v['cleanup'][0]+3, exit=1, signal=None, errors=[], passed=False, coordinator_reaped=True,
        eof=list(negative.STREAMS), checked_closed=list(negative.STREAMS), cleanup_pending=False,
        automatic_termination=False, transport_failure=False, deadline_failure=False, interrupted=False,
        streams={k:digest(raw[k]) for k in negative.STREAMS})
    raw['caller'] = encode(caller)
    expected = {k:caller[k] for k in ('case', 'package_sha256', 'source_sha256', 'caller_source_sha256')}
    return raw, expected


class SignedFixtureNegativeReportTests(unittest.TestCase):
    def test_six_allowed_measured_products_preserve_failed_raw_receipts(self):
        for cut, uncertain in [(0,False),(1,False),(2,False),(2,True),(3,True),(4,False)]:
            raw, expected = evidence(cut, uncertain); before = copy.deepcopy(raw)
            result = negative.evaluate(raw, expected)
            self.assertEqual(result['assessment'], 'qualified-negative', result)
            self.assertEqual(raw, before)
            self.assertFalse(result['subject_passed']); self.assertFalse(result['ordinary_positive'])
            self.assertFalse(result['broader_pending_retirement']); self.assertEqual(result['subject_exit'], 1)

    def test_actual_serializer_maximum_32_rows_and_uint64_fields_fit_4096(self):
        # Exact serializer shape/encoding; Swift serialization/native write are NOT executed here.
        sizes = []
        for cut in range(5):
            value = report(cut, maximum=True)
            raw = negative.serialize_report(value); sizes.append(len(raw))
            self.assertEqual(negative.parse_report(raw), value)
        self.assertLessEqual(max(sizes),4096)
        self.assertGreater(max(sizes),2500)

    def test_closed_fields_duplicate_nonfinite_overflow_and_extra_report_refuse(self):
        raw = negative.serialize_report(report(2))
        bad = [raw + raw, raw[:-1], b'noise\n'+raw, raw.replace(b'"cut":2',b'"cut":2,"cut":2'),
            raw.replace(b'"cut":2', b'"cut":NaN'), raw.replace(b'"cut":2',b'"cut":true')]
        v = report(2); v['extra'] = 1; bad.append(negative.serialize_report(v))
        for value in bad:
            with self.subTest(value=value[:40]), self.assertRaises(ValueError): negative.parse_report(value)
        value = report(2); value['reached_ns'] = 1<<64
        with self.assertRaises(ValueError): negative.parse_report(negative.serialize_report(value))
        value['evidence'][0] = ['a'*4096]
        with self.assertRaises(ValueError): negative.serialize_report(value)

    def test_cut_and_original_cap_mutations_refuse(self):
        for cut in range(5):
            mutations = [lambda v:v.update(cut=(cut+1)%5), lambda v:v['deadlines'].__setitem__(1,v['deadlines'][1]+1),
                lambda v:v['cleanup'].__setitem__(2,1), lambda v:v['fixture'].__setitem__(0,1),
                lambda v:v['holds'].__setitem__(2,1 if cut!=4 else 0), lambda v:v['evidence'].__setitem__(2,63)]
            if cut:
                mutations += [lambda v:v['deadlines'].__setitem__(8,v['deadlines'][8]+1),
                    lambda v:v['command'].__setitem__(1,2047), lambda v:v['joins'].append(v['joins'][0]),
                    lambda v:v['holds'][0].__setitem__(2,None)]
            for mutate in mutations:
                v=report(cut); mutate(v)
                with self.subTest(cut=cut), self.assertRaises(ValueError): negative.parse_report(negative.serialize_report(v))

    def test_after_ack_cancellation_cap_miss_or_disposal_never_qualifies(self):
        for mutate in [lambda v:v['product'].__setitem__(1,2), lambda v:v['cleanup'].__setitem__(7,1),
            lambda v:v['joins'][0].__setitem__(2,v['deadlines'][8]), lambda v:v['product'].__setitem__(3,3)]:
            v=report(1); mutate(v)
            with self.assertRaises(ValueError): negative.parse_report(negative.serialize_report(v))

    def test_both_H_actual_failure_results_and_no_early_owner_release_required(self):
        for latch in (0,1):
            for mutate in [lambda v:v['holds'][latch].__setitem__(1,v['deadlines'][1]-1),
                lambda v:v['holds'][latch].__setitem__(2,1),
                lambda v:v['holds'][latch].__setitem__(3,v['deadlines'][1]-1),
                lambda v:v['product'].__setitem__(1+latch,1), lambda v:v['cleanup'].__setitem__(7,1)]:
                v=report(4); mutate(v)
                with self.assertRaises(ValueError): negative.parse_report(negative.serialize_report(v))

    def test_measured_union_events_disposal_and_missing_real_join_refuse(self):
        for uncertain in (False,True):
            for mutate in [lambda v:v['joins'][0].__setitem__(3,1 if uncertain else 0),
                lambda v:v['cleanup'].__setitem__(7,0 if uncertain else 1),
                lambda v:v['evidence'].__setitem__(1,15 if uncertain else 3), lambda v:v.update(joins=[]),
                lambda v:v['joins'].reverse()]:
                v=report(2,uncertain); mutate(v)
                with self.assertRaises(ValueError): negative.parse_report(negative.serialize_report(v))

    def test_failed_exit_without_reached_report_and_wrong_bindings_never_qualifies(self):
        for field in ('nonce','source_sha256','executable_sha256','app_sha256','request_sha256','transaction_digest'):
            raw,expected=evidence(2); value=negative.decode(raw['stderr'][len(negative.PREFIX):-1]); value[field]='0'*(32 if field=='nonce' else 64)
            raw['stderr']=negative.serialize_report(value)
            caller=negative.decode(raw['caller']); caller['streams']['stderr']=negative.digest(raw['stderr']);raw['caller']=negative.encode(caller)
            self.assertEqual(negative.evaluate(raw,expected)['assessment'],'failed')
        for stderr in (b'',b'unrelated failure\n'):
            raw,expected=evidence(2);raw['stderr']=stderr
            self.assertEqual(negative.evaluate(raw,expected)['assessment'],'failed')

    def test_exit_pass_reap_eof_deadline_transport_and_preparation_mutations_refuse(self):
        for key,value in [('exit',0),('passed',True),('coordinator_reaped',False),('eof',[]),('checked_closed',[]),
            ('stderr_nonblocking_before_spawn',False),('errors',['unexpected']),('automatic_termination',True),
            ('transport_failure',True),('deadline_failure',True),('interrupted',True),('cleanup_pending',True),
            ('report_received_ns',40_000_000_000),('caller_source_sha256','0'*64),('root_sha256','0'*64)]:
            raw,expected=evidence(4);caller=negative.decode(raw['caller']);caller[key]=value;raw['caller']=negative.encode(caller)
            with self.subTest(key=key): self.assertIn(negative.evaluate(raw,expected)['assessment'],('failed','pending'))

    def test_guardian_skipped_replayed_wrong_reason_and_no_terminal_refuse(self):
        for mutate in [lambda f:f.pop(1),lambda f:f.insert(2,copy.deepcopy(f[1])),lambda f:f.pop(),
            lambda f:f[2].update(reason='deadline'),lambda f:f[3].update(event='case_pass'),
            lambda f:f[4].update(passed_cases=1),lambda f:f[4].update(children=1)]:
            raw,expected=evidence(3); frames=[negative.decode(x) for x in raw['guardian'].splitlines()];mutate(frames)
            raw['guardian']=b''.join(negative.encode(x)+b'\n' for x in frames)
            caller=negative.decode(raw['caller']);caller['streams']['guardian']=negative.digest(raw['guardian']);raw['caller']=negative.encode(caller)
            self.assertIn(negative.evaluate(raw,expected)['assessment'],('failed','pending'))

    def test_normal_positive_parser_still_rejects_negative_terminal_as_success(self):
        raw,_=evidence(1);caller=negative.decode(raw['caller'])
        parser=negative.GuardianProtocol('signed-installation-adapter',[caller['case']],caller['nonce'],
            caller['source_sha256'],caller['executable_sha256'],caller['app_sha256'])
        parser.feed(raw['guardian']);self.assertFalse(parser.finish(1))
        with self.assertRaises(ValueError): parser.finish(0)

    def test_read_only_file_seal_rejects_digest_mode_symlink_and_replacement(self):
        with tempfile.TemporaryDirectory(prefix='signed-negative-seal-') as temporary:
            root=Path(temporary).resolve();path=root/'evidence';path.write_bytes(b'evidence');path.chmod(0o600)
            row=dict(path=str(path),sha256=negative.digest(b'evidence'),size=8,mode=0o600)
            self.assertEqual(negative.read_bound(row),b'evidence')
            for changed in ({**row,'sha256':'0'*64},{**row,'mode':0o400},{**row,'size':9}):
                with self.assertRaises(ValueError):negative.read_bound(changed)
            alias=root/'alias';alias.symlink_to(path)
            with self.assertRaises(ValueError):negative.read_bound({**row,'path':str(alias)})
            path.write_bytes(b'changed!')
            with self.assertRaises(ValueError):negative.read_bound(row)


if __name__ == '__main__':
    unittest.main()
