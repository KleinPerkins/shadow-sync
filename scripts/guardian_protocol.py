"""Bounded, closed parser for the testing-only runtime guardian receipt stream."""
import json


class InvalidGuardianReceipt(ValueError):
    pass


class GuardianProtocol:
    SCHEMA = 'shadow-sync-runtime-guardian/v1'
    COMMON = {'schema', 'suite', 'nonce', 'sequence', 'event'}
    COUNTS = {'spawned', 'reaped', 'failed_spawns', 'reservations', 'children', 'callbacks'}
    REASONS = {'callerLost', 'cancelled', 'deadline', 'transport', 'assertion'}

    def __init__(self, suite, cases, nonce, source_sha256, executable_sha256, app_sha256, probe=None):
        self.suite, self.expected, self.nonce = suite, frozenset(cases), nonce
        if not cases or len(self.expected) != len(cases):
            raise InvalidGuardianReceipt('empty or duplicate expected cases')
        self.hashes = dict(source_sha256=source_sha256, executable_sha256=executable_sha256,
                           app_sha256=app_sha256)
        self.probe = probe or 'none'
        self.buffer = bytearray()
        self.total = self.sequence = 0
        self.ready = False
        self.active = None
        self.begun, self.passed = set(), set()
        self.cancelled = None
        self.terminal = None
        self.counts = dict(spawned=0, reaped=0, failed_spawns=0)
        self.failed = False

    @staticmethod
    def _object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise InvalidGuardianReceipt('duplicate JSON key')
            result[key] = value
        return result

    @staticmethod
    def _check(condition, message):
        if not condition:
            raise InvalidGuardianReceipt(message)

    def feed(self, chunk):
        self._check(not self.failed, 'parser already failed')
        try:
            self.total += len(chunk)
            self._check(self.total <= 4_194_304, 'stream limit')
            # Process incrementally so a caller cannot allocate an unbounded
            # unterminated frame, even when read boundaries differ.
            for byte in chunk:
                self.buffer.append(byte)
                self._check(len(self.buffer) <= 2048, 'frame limit')
                if byte == 10:
                    raw = bytes(self.buffer[:-1]); self.buffer.clear()
                    value = json.loads(raw.decode('utf-8'), object_pairs_hook=self._object,
                                       parse_constant=lambda _: (_ for _ in ()).throw(
                                           InvalidGuardianReceipt('nonfinite JSON')))
                    self._accept(value)
        except (ValueError, TypeError, UnicodeError, KeyError, RecursionError) as error:
            self.failed = True
            raise InvalidGuardianReceipt(str(error)) from error

    def _accept(self, value):
        check = self._check
        check(isinstance(value, dict), 'frame must be object')
        check(value.get('schema') == self.SCHEMA and value.get('suite') == self.suite
              and value.get('nonce') == self.nonce, 'binding mismatch')
        check(type(value.get('sequence')) is int and value['sequence'] == self.sequence,
              'noncontiguous sequence')
        check(self.terminal is None, 'frame after terminal')
        event = value.get('event')
        fields = {
            'ready': {'expected_cases', 'probe', *self.hashes},
            'case_start': {'case'},
            'case_pass': {'case', *self.COUNTS},
            'case_failed': {'case', *self.COUNTS},
            'cancelled': {'reason'},
            'terminal': {'outcome', 'reason', 'expected_cases', 'begun_cases', 'passed_cases', *self.COUNTS},
        }
        check(event in fields and set(value) == self.COMMON | fields[event], 'unknown fields or event')
        if event == 'ready':
            check(not self.ready and self.sequence == 0, 'duplicate or late ready')
            check(type(value['expected_cases']) is int and value['expected_cases'] == len(self.expected)
                  and value['probe'] == self.probe
                  and all(value[k] == v for k, v in self.hashes.items()), 'wrong ready binding')
            self.ready = True
        else:
            check(self.ready, 'event before ready')
            if event == 'case_start':
                case = value['case']
                check(isinstance(case, str) and case in self.expected and case not in self.begun
                      and self.active is None and self.cancelled is None, 'invalid case admission')
                self.begun.add(case); self.active = case
            elif event == 'cancelled':
                check(self.cancelled is None and value['reason'] in self.REASONS, 'invalid cancellation')
                self.cancelled = value['reason']
            elif event in {'case_pass', 'case_failed'}:
                case = value['case']
                check(isinstance(case, str) and case == self.active, 'case completion without admission')
                self._cleanup(value)
                if event == 'case_pass':
                    check(self.cancelled is None, 'pass after cancellation')
                    self.passed.add(case)
                else:
                    check(self.cancelled is not None, 'failed case without cancellation')
                for key in self.counts:
                    self.counts[key] += value[key]
                self.active = None
            elif event == 'terminal':
                self._cleanup(value)
                check(self.active is None, 'terminal with active case')
                for key, count in [('expected_cases', len(self.expected)),
                                   ('begun_cases', len(self.begun)), ('passed_cases', len(self.passed)),
                                   *self.counts.items()]:
                    check(type(value[key]) is int and value[key] == count, 'terminal count mismatch')
                if value['outcome'] == 'passed':
                    check(value['reason'] == 'none' and self.cancelled is None
                          and self.passed == self.expected, 'incomplete success')
                else:
                    check(value['outcome'] == 'failed' and self.cancelled is not None
                          and value['reason'] == self.cancelled, 'invalid failure terminal')
                self.terminal = value
        self.sequence += 1

    def _cleanup(self, value):
        self._check(all(type(value[k]) is int and 0 <= value[k] <= 1_000_000 for k in self.COUNTS),
                    'invalid custody counts')
        self._check(value['reservations'] == value['children'] == value['callbacks'] == 0
                    and value['spawned'] == value['reaped'], 'unreaped custody')

    def finish(self, exit_code):
        self._check(not self.failed and not self.buffer and self.terminal is not None,
                    'missing or incomplete terminal')
        self._check(type(exit_code) is int, 'original guardian not reaped')
        self._check((self.terminal['outcome'] == 'passed' and exit_code == 0)
                    or (self.terminal['outcome'] == 'failed' and exit_code == 1),
                    'terminal/exit mismatch')
        return self.terminal['outcome'] == 'passed'
