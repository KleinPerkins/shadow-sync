import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('guardian_protocol',
    Path(__file__).resolve().parents[2] / 'scripts/guardian_protocol.py')
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class GuardianProtocolTests(unittest.TestCase):
    def parser(self):
        return MOD.GuardianProtocol('m4', ['one', 'two'], 'a' * 32, 'b' * 64, 'c' * 64, 'd' * 64)

    def records(self, failed=False):
        common = dict(schema=MOD.GuardianProtocol.SCHEMA, suite='m4', nonce='a' * 32)
        counts = dict(spawned=1, reaped=1, failed_spawns=0, reservations=0, children=0, callbacks=0)
        records = [dict(event='ready', expected_cases=2, probe='none', source_sha256='b' * 64,
                        executable_sha256='c' * 64, app_sha256='d' * 64),
                   dict(event='case_start', case='one')]
        if failed:
            records += [dict(event='cancelled', reason='callerLost'),
                        dict(event='case_failed', case='one', **counts),
                        dict(event='terminal', outcome='failed', reason='callerLost', expected_cases=2,
                             begun_cases=1, passed_cases=0, **counts)]
        else:
            records += [dict(event='case_pass', case='one', **counts),
                        dict(event='case_start', case='two'),
                        dict(event='case_pass', case='two', **counts),
                        dict(event='terminal', outcome='passed', reason='none', expected_cases=2,
                             begun_cases=2, passed_cases=2, **dict(counts, spawned=2, reaped=2))]
        return [dict(common, sequence=i, **record) for i, record in enumerate(records)]

    def encoded(self, records):
        return b''.join(json.dumps(r).encode() + b'\n' for r in records)

    def reject(self, records):
        parser = self.parser()
        with self.assertRaises(MOD.InvalidGuardianReceipt):
            parser.feed(self.encoded(records)); parser.finish(0)

    def test_complete_original_reap_required(self):
        for code in [None, True, 1, -15]:
            with self.subTest(code=code):
                parser = self.parser(); parser.feed(self.encoded(self.records()))
                with self.assertRaises(MOD.InvalidGuardianReceipt): parser.finish(code)
        parser = self.parser(); parser.feed(self.encoded(self.records()))
        self.assertTrue(parser.finish(0))

    def test_arbitrary_read_fragmentation(self):
        raw = self.encoded(self.records())
        for width in [1, 17, 1024, len(raw)]:
            parser = self.parser()
            for i in range(0, len(raw), width): parser.feed(raw[i:i + width])
            self.assertTrue(parser.finish(0))

    def test_actual_failed_cleanup_is_not_success(self):
        parser = self.parser(); parser.feed(self.encoded(self.records(failed=True)))
        self.assertFalse(parser.finish(1))

    def test_incomplete_prefixes_are_red(self):
        records = self.records()
        for count in range(len(records)):
            with self.subTest(count=count): self.reject(records[:count])

    def test_exact_binding(self):
        for key, wrong in [('source_sha256', 'f' * 64), ('app_sha256', 'f' * 64),
                           ('executable_sha256', 'f' * 64), ('expected_cases', 0),
                           ('schema', 'unknown'), ('suite', 'm6'), ('nonce', 'f' * 32)]:
            records = self.records(); records[0][key] = wrong
            with self.subTest(key=key): self.reject(records)

    def test_sequence_and_closed_fields(self):
        for index in range(len(self.records())):
            for key, value in [('sequence', -1), ('unknown', 1), ('sequence', True)]:
                records = self.records(); records[index][key] = value
                with self.subTest(index=index, key=key, value=value): self.reject(records)

    def test_missing_duplicate_and_unknown_cases(self):
        for index, case in [(1, 'unknown'), (2, 'two'), (3, 'one'), (4, 'one')]:
            records = self.records(); records[index]['case'] = case; self.reject(records)
        records = self.records(); records.pop(3)
        for i, r in enumerate(records): r['sequence'] = i
        self.reject(records)

    def test_cancelled_case_cannot_pass_or_admit_next(self):
        records = self.records(failed=True); records[3]['event'] = 'case_pass'; self.reject(records)
        records = self.records(failed=True)
        records.insert(3, dict(records[1], case='two'))
        for i, r in enumerate(records): r['sequence'] = i
        self.reject(records)

    def test_every_custody_count_checked(self):
        for index in [2, 4, 5]:
            for key in MOD.GuardianProtocol.COUNTS:
                for bad in [-1, True, 1_000_001]:
                    records = self.records(); records[index][key] = bad
                    with self.subTest(index=index, key=key, bad=bad): self.reject(records)
            for key in ['children', 'callbacks', 'reservations']:
                records = self.records(); records[index][key] = 1; self.reject(records)
            records = self.records(); records[index]['reaped'] = 0; self.reject(records)

    def test_terminal_aggregation(self):
        for key in ['spawned', 'reaped', 'failed_spawns', 'expected_cases', 'begun_cases', 'passed_cases']:
            records = self.records(); records[-1][key] += 1; self.reject(records)
        records = self.records(); records.append(copy.deepcopy(records[-1])); self.reject(records)

    def test_empty_zero_test_cannot_succeed(self):
        with self.assertRaises(MOD.InvalidGuardianReceipt):
            MOD.GuardianProtocol('m4', [], 'a' * 32, 'b' * 64, 'c' * 64, 'd' * 64)
        records = self.records(); records[-1]['passed_cases'] = 0; self.reject(records)

    def test_limits_and_malformed_json(self):
        for raw in [b'x' * 2049, b'{}\n', b'null\n', b'{"x":1,"x":2}\n', b'\xff\n',
                    b'{"x":NaN}\n', b'[' * 1023 + b'0' + b']' * 1023 + b'\n']:
            parser = self.parser()
            with self.subTest(raw=raw[:30]), self.assertRaises(MOD.InvalidGuardianReceipt): parser.feed(raw)
            with self.assertRaises(MOD.InvalidGuardianReceipt): parser.feed(b'')
        parser = self.parser(); parser.total = 4_194_304
        with self.assertRaises(MOD.InvalidGuardianReceipt): parser.feed(b'\n')

    def test_partial_final_frame_and_wrong_reason(self):
        parser = self.parser(); parser.feed(self.encoded(self.records())[:-1])
        with self.assertRaises(MOD.InvalidGuardianReceipt): parser.finish(0)
        records = self.records(failed=True); records[-1]['reason'] = 'deadline'; self.reject(records)


if __name__ == '__main__': unittest.main()
