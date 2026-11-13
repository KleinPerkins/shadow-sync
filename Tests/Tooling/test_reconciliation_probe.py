"""Offline contracts for the fixed reconciliation route and closed observation."""
import importlib.util
import hashlib
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'Sources/ShadowSyncCore'


def load_inventory():
    spec = importlib.util.spec_from_file_location('reconciliation_inventory', ROOT / 'scripts/runtime-suite-inventory.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def closed_enums(source):
    values = {}
    for name in ('Stage', 'Boundary', 'Failure'):
        body = re.search(r'enum ' + name + r': String \{(.*?)\n    }', source, re.S)[1]
        # Only literal case declarations, never dynamic values or user input.
        items = []
        for line in body.splitlines():
            match = re.fullmatch(r'\s*case ([\w, ]+)\s*', line)
            if match:
                items += [part.strip() for part in match[1].split(',')]
        if items:
            values[name] = set(items)
    # Part is deliberately a single-line enum.
    match = re.search(r'enum Part: String \{ case ([\w, ]+) }', source)
    values['Part'] = set(match[1].split(', '))
    for name in ('Origin', 'Edge'):
        match = re.search(r'enum ' + name + r': String \{ case ([\w, ]+) }', source)
        values[name] = set(match[1].split(', '))
    return values


def parse_records(lines, enums, bootstrap):
    """Closed test parser: reject leaks, unknown fields, truncation and excess."""
    if not 1 <= len(lines) <= 128:
        raise ValueError('record count')
    pattern = re.compile(r'M6 STAGED RECONCILIATION DIAGNOSTIC part=(\w+) stage=(\w+) bootstrap=(\w+) boundary=(\w+) origin=(\w+) edge=(\w+) error=(\w+)\n')
    result = []
    one_shots = set()
    for line in lines:
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError('record grammar')
        row = dict(zip(('Part', 'Stage', 'Bootstrap', 'Boundary', 'Origin', 'Edge', 'Failure'), match.groups()))
        for field, value in row.items():
            if value not in (bootstrap | {'none'} if field == 'Bootstrap' else enums[field]):
                raise ValueError('unknown closed value')
        if row['Edge'] != 'entered':
            if row['Edge'] in one_shots:
                raise ValueError('duplicate terminal')
            one_shots.add(row['Edge'])
        result.append(row)
    if len({'firstSetupFailure', 'firstBodyFailure', 'firstExclusionFailure'} & one_shots) > 1:
        raise ValueError('two initiating failures')
    if {'returned', 'outerFailure'} <= one_shots:
        raise ValueError('two outer outcomes')
    if result[-1]['Edge'] not in {'returned', 'outerFailure'}:
        raise ValueError('missing outer outcome')
    return result


CANCELLATION_FIELDS = ('sampled phase protocol reason flags helper status issued originalWork originalTerm '
    'originalKill originalReceipt work term kill receipt operation cap archiveStarted archiveCompleted '
    'retired finalization expired publication firstPoint firstFamily firstSystem').split()


def parse_cancellation_records(lines):
    """Diagnostic grammar only; this value sample never proves custody or success."""
    if len(lines) != 1 or len(lines[0]) > 4096:
        raise ValueError('record count or bound')
    pattern = 'M6 CANCEL OBSERVATION v1' + ''.join(' ' + k + r'=([0-9]+)' for k in CANCELLATION_FIELDS) + r'\n'
    match = re.fullmatch(pattern, lines[0])
    if not match:
        raise ValueError('closed grammar')
    row = dict(zip(CANCELLATION_FIELDS, map(int, match.groups())))
    bounds = {'phase': 4, 'protocol': 4, 'reason': 12, 'helper': 3, 'status': 2**32-1,
              'finalization': 4, 'expired': 5, 'publication': 3, 'firstPoint': 14,
              'firstSystem': 2**32-1}
    if any(v > bounds.get(k, 2**64-1) for k, v in row.items()):
        raise ValueError('scalar range')
    if row['flags'] & ~0x3f1ffff or row['firstFamily'] not in (*range(14), 255):
        raise ValueError('closed flags or error family')
    return row


class ReconciliationProbeTests(unittest.TestCase):
    def test_closed_record_parser_rejects_private_or_unbounded_evidence(self):
        source = (CORE / 'InstallationReconciliationDiagnostic.swift').read_text()
        enums = closed_enums(source)
        completion = (CORE / 'InstallationStagedCompletionFixtures.swift').read_text()
        body = re.search(r'enum CompletionPhase: String \{(.*?)\n    }', completion, re.S)[1]
        bootstrap = set(re.findall(r'\b\w+\b', body)) - {'case'}
        def row(edge='entered', **fields):
            value = dict(part='unpublishedKickstart', stage='retirementToken', bootstrap='none',
                         boundary='bodyEntered', origin='body', edge=edge, error='none')
            value.update(fields)
            return 'M6 STAGED RECONCILIATION DIAGNOSTIC ' + ' '.join(k+'='+v for k,v in value.items()) + '\n'
        progress = row()
        first = row('firstBodyFailure', boundary='bodyFailed', error='fenced')
        ready = row('readinessFailure', boundary='readinessCloseFailed', origin='cleanup', error='busy')
        prepare = row('preparationFailure', boundary='preparationCleanupFailed', origin='cleanup', error='assertion')
        outer = row('outerFailure', boundary='rootCleanupFailed', origin='cleanup', error='conflict')
        result = parse_records([progress] * 124 + [first, ready, prepare, outer], enums, bootstrap)
        self.assertEqual(len(result), 128)
        self.assertEqual(result[-4]['Failure'], 'fenced')
        self.assertEqual(result[-1]['Failure'], 'conflict')
        exclusion = row('firstExclusionFailure', part='afterAnchor', boundary='exclusion',
                        origin='cleanup', error='assertion')
        self.assertEqual(parse_records([progress] * 124 + [exclusion, prepare, outer],
                                      enums, bootstrap)[-3]['Boundary'], 'exclusion')
        bad = ([progress] * 125 + [first, ready, prepare, outer], [first, first, outer],
               [first, row('firstSetupFailure'), outer], [first, exclusion, outer],
               [row('firstSetupFailure'), exclusion, outer], [first],
               [row('returned', origin='returned'), outer],
               [outer.replace('part=unpublishedKickstart', 'part=/private/fixture')],
               [outer.replace('error=conflict', 'error=errorDescription')],
               [outer.rstrip('\n')], [outer.replace('\n', ' pid=42\n')],
               [outer.replace('stage=retirementToken', 'stage=unknownStage')])
        for lines in bad:
            with self.subTest(lines=lines[-1:]), self.assertRaises(ValueError):
                parse_records(lines, enums, bootstrap)

    def test_probe_is_bounded_opt_in_errno_preserving_and_ownership_free(self):
        source = (CORE / 'InstallationReconciliationDiagnostic.swift').read_text()
        self.assertTrue(source.startswith('#if SHADOW_SYNC_TESTING\n') and source.rstrip().endswith('#endif'))
        self.assertIn('records < (terminal ? 128 : 124)', source)
        self.assertEqual(source.count('SHADOW_SYNC_TEST_M6_DIAGNOSTICS'), 1)
        self.assertEqual(source.count('fputs('), 1)
        self.assertEqual(source.count('fflush('), 1)
        for body in re.split(r'\n    (?:private )?func ', source)[1:]:
            self.assertIn('let savedDiagnosticErrno = errno', body)
            self.assertIn('defer { errno = savedDiagnosticErrno }', body)
        self.assertNotRegex(source, r'\b(?:NSLock|NSCondition|DispatchQueue|FileManager|URL|open|write|read|sleep|getpid|validate|revalidate)\s*\(')
        self.assertNotRegex(source, r'(?:var|let)\s+\w+\s*:\s*(?:Error|.*(?:Owner|Lease|Registry|Journal|Endpoint))\??')
        line = next(line for line in source.splitlines() if '"M6 STAGED RECONCILIATION DIAGNOSTIC part=' in line)
        self.assertEqual(re.findall(r'\\\((\w+)(?:\?\.)?', line),
                         ['part', 'stage', 'bootstrap', 'boundary', 'origin', 'edge', 'failure'])
        self.assertNotIn('String(describing:', source)
        self.assertIn('fputs(record.line, stderr)', source)
        self.assertIn('capturedRecords!.append(record)', source)
        self.assertNotIn('@escaping', source)
        self.assertIn('private var capturedRecords: [Record]?', source)

    def test_cleanup_observation_keeps_original_failure_precedence(self):
        journal = (CORE / 'InstallationStagedJournalFixtures.swift').read_text()
        journal = journal[journal.index('    private static func diagnosticFixture('):journal.index('    private static func record(')]
        self.assertEqual(journal.count('try journal.closeReadiness(deadline: .init(seconds: 3))'), 2)
        self.assertEqual(journal.count('observation?(.readinessCloseFailed, .init(error))\n                    throw error'), 1)
        self.assertIn('observation?(.readinessCloseReturned, .none)\n                throw error', journal)
        self.assertLess(journal.index('observation?(.bodyFailed'), journal.index('try journal.closeReadiness'))
        self.assertNotIn('try?', journal)
        prepared = (CORE / 'InstallationExclusivePreparationFixtures.swift').read_text()
        prepared = prepared[prepared.index('    static func withPreparedIntent('):prepared.index('    static func stagedIntentReleaseAndSubstitution(')]
        self.assertIn('observation?(.preparationCleanupFailed, .init(error))\n                throw error', prepared)
        self.assertLess(prepared.index('try registry.testingDispose()'), prepared.index('if let failure'))
        self.assertIn('MonotonicDeadline(seconds: 8)', prepared)
        storage = (CORE / 'InstallationStorageFixtures.swift').read_text()
        storage = storage[storage.index('    static func fixture('):storage.index('    static func initial(')]
        self.assertLess(storage.index('observation?(.rootCaught'), storage.index('try custody.finish'))
        self.assertIn('observation?(.rootCleanupFailed, .init(error))', storage)
        self.assertLess(storage.index('try custody.finish(deadline: .init(seconds: 3))'), storage.index('if let failure'))
        self.assertIn('observation?(.rootRethrow, .init(failure))\n            throw failure', storage)
        for source in (journal, prepared, storage):
            self.assertNotIn('try?', source)

    def test_fixed_suite_rejects_missing_reordered_substituted_or_selected_bodies(self):
        inventory = load_inventory()
        with tempfile.TemporaryDirectory(prefix='shadow-sync-reconciliation-source-') as tmp:
            root = Path(tmp)
            names = ['Tests/ShadowSyncSelfTests/CISuites.swift', 'Sources/ShadowSyncApp/M5Harness.swift', 'scripts/verify-m5.sh']
            names += [str(p.relative_to(ROOT)) for p in CORE.glob('*SelfTests.swift')]
            for name in names:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((ROOT / name).read_bytes())
            path = root / 'Sources/ShadowSyncCore/M6SelfTests.swift'
            original = path.read_text()
            start = original.index('    public static func runStagedReconciliation(')
            end = original.index('    public static func runAll(', start)
            focused = original[start:end]
            lines = [line for line in focused.splitlines(True) if '        try run(' in line]
            self.assertEqual(len(lines), 8)
            rows = {row['id']: row for row in inventory.inspect(root)['suites']}
            expected = re.findall(r'try run\("([^"]+)"', focused)
            self.assertEqual(rows['m6-staged-reconciliation']['cases'], expected)
            self.assertEqual(rows['m6-staged-reconciliation']['entrypoint'], 'M6SelfTestRunner.runStagedReconciliation')
            self.assertEqual(len(rows['m6']['cases']), 730 + 12)  # Original full suite plus fresh-driver cases.
            self.assertEqual(len(rows['m6-custody-capture']['cases']), 4)
            variants = [focused.replace(line, '') for line in lines]
            variants += [focused.replace(lines[0]+lines[1], lines[1]+lines[0]),
                         focused.replace(lines[1], lines[1]+lines[1]),
                         focused.replace('retiredStarts()', 'unclaimedAndAbsentStop()'),
                         focused.replace('record: (String) -> Void', 'selector: String, record: (String) -> Void'),
                         focused.replace('try RuntimeFixtureSession.withCase(name) { try body() }', 'try body()')]
            for changed in variants:
                path.write_text(original[:start]+changed+original[end:])
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    inventory.inspect(root)
            path.write_text(original)
            inventory.inspect(root)
            observer = root / 'Sources/ShadowSyncCore/ReconciliationDiagnosticSelfTests.swift'
            original = observer.read_text()
            for old, new in (
                    ('try cappedExclusionUnwind()', ''),
                    ('try fourReservations()', ''),
                    ('try setupAndDisabled()', ''),
                    ('try RuntimeFixtureSession.withCase(', 'try bypass('),
                    ('record: (String) -> Void', 'selector: String, record: (String) -> Void')):
                observer.write_text(original.replace(old, new, 1))
                with self.subTest(omitted=old), self.assertRaises(ValueError):
                    inventory.inspect(root)
            observer.write_text(original)
            inventory.inspect(root)


    def test_resumed_deadline_labels_cover_closed_modes_and_all_waits(self):
        source = (CORE / 'InstallationStagedReconciliationFixtures.swift').read_text()
        failure = source[source.index('    private struct ResumedDeadline {'):
                         source.index('    private static func until(')]
        self.assertEqual(re.findall(r'case (\w+)(?: = "([^"]+)")?',
                                   failure.split('        enum Wait:')[0]),
                         [('completed', ''), ('mutationFailure', 'lifecycle-mutation-failure'),
                          ('mutationCancel', 'lifecycle-mutation-cancel'),
                          ('postflightTimeout', 'lifecycle-postflight-timeout')])
        self.assertIn('case cancellationReady, commandFinished, commandRetirement', failure)
        self.assertIn('case observationHelpers, observationRetirement', failure)
        self.assertIn(r'mode=\(mode.rawValue) wait=\(wait.rawValue) error=deadline', failure)
        self.assertNotRegex(failure, r'\b(?:snapshot|validate|Owner|Registry|Journal|URL|ProcessInfo|open|read|write)\b')
        resumed = source[source.index('    static func resumedOutcomes()'):
                         source.index('    static func semanticStates()')]
        self.assertIn('for failureMode in [ResumedDeadline.Mode.completed, .mutationFailure, .mutationCancel, .postflightTimeout]', resumed)
        for wait, predicate in (
                ('cancellationReady', 'String(decoding: handle.snapshot().stderr'),
                ('commandFinished', 'handle.snapshot().phase == .finished'),
                ('commandRetirement', '(try? token.validate()) != nil')):
            self.assertIn('try until(failure: .init(mode: failureMode, wait: .' + wait + ')) { ' + predicate, resumed)
        observe = source[source.index('    private static func observe('):
                         source.index('    static func unclaimedAndAbsentStop()')]
        for wait, predicate in (
                ('observationHelpers', 'registry.testingCount == 0 && registry.testingOriginalHelpersReaped'),
                ('observationRetirement', '(try? token.validate()) != nil')):
            self.assertIn('try until(failure: resumedMode.map { ResumedDeadline(mode: $0, wait: .' + wait + ') }) {\n            ' + predicate, observe)
        self.assertIn('mode: "installation-loaded", resumedMode: failureMode)', resumed)

    def test_resumed_deadline_decorations_preserve_every_original_fixture_byte(self):
        # Strip only exact reviewed additions, requiring each to remain present.
        # The unchanged digest pins every prior operation, predicate, cleanup,
        # assertion and fixed budget after those additions are projected out.
        source = (CORE / 'InstallationStagedReconciliationFixtures.swift').read_text()
        recovery_owner_capture = '''                    guard let originalSession = journal.testingSession, let endpoint = journal.testingEndpoint else {
                        throw H.Failure(message: "missing recovery readiness owners")
                    }
                    let endpointImage = try endpoint.image
'''
        recovery_retirement_assertions = '''                    // The original queue must be joined even if its invocation
                    // deadline has not fired. A later close cannot race recovery
                    // postflight; joining never removes the named socket fence.
                    try H.check(journal.testingSession == nil && !originalSession.start(),
                                "start recovery did not join original readiness session")
                    try endpoint.requireServiceClosed()
                    try H.check(journal.testingEndpoint === endpoint && (try endpoint.image) == endpointImage,
                                "start recovery retired the named readiness fence")
'''
        for addition in (recovery_owner_capture, recovery_retirement_assertions):
            self.assertEqual(source.count(addition), 1)
            source = source.replace(addition, '', 1)
        source = source.replace('                if failureMode == .mutationCancel { try registry.testingArmCancellationObservation(command!) }\n', '', 1)
        observed = '''                do {
                    try until(failure: .init(mode: failureMode, wait: .commandFinished)) { handle.snapshot().phase == .finished }
                } catch {
                    handle.testingTakeCancellationObservation()?.emit()
                    throw error
                }'''
        source = source.replace(observed, '                try until(failure: .init(mode: failureMode, wait: .commandFinished)) { handle.snapshot().phase == .finished }', 1)
        start = source.index('    // Failure attribution carries closed values only,')
        end = source.index('    private static func until(', start)
        source = source[:start] + source[end:]
        source = source.replace('until(failure: ResumedDeadline? = nil, _ predicate:', 'until(_ predicate:', 1)
        source = source.replace('guard !deadline.hasExpired else {\n                throw H.Failure(message: failure?.message ?? "staged recovery retirement deadline")\n            }',
                                'guard !deadline.hasExpired else { throw H.Failure(message: "staged recovery retirement deadline") }', 1)
        source = source.replace(',\n                                resumedMode: ResumedDeadline.Mode? = nil) throws -> T {', ') throws -> T {', 1)
        for wait, predicate in (
                ('observationHelpers', 'registry.testingCount == 0 && registry.testingOriginalHelpersReaped'),
                ('observationRetirement', '(try? token.validate()) != nil')):
            source = source.replace('try until(failure: resumedMode.map { ResumedDeadline(mode: $0, wait: .' + wait + ') }) {\n            ' + predicate + '\n        }',
                                    'try until { ' + predicate + ' }', 1)
        source = source.replace('for failureMode in [ResumedDeadline.Mode.completed, .mutationFailure, .mutationCancel, .postflightTimeout] {\n            let mode = failureMode.rawValue',
                                'for mode in ["completed", "lifecycle-mutation-failure", "lifecycle-mutation-cancel", "lifecycle-postflight-timeout"] {', 1)
        for wait in ('cancellationReady', 'commandFinished', 'commandRetirement'):
            source = source.replace('try until(failure: .init(mode: failureMode, wait: .' + wait + ')) {', 'try until {', 1)
        source = source.replace(', resumedMode: failureMode)', ')', 1)
        self.assertEqual(hashlib.sha256(source.encode()).hexdigest(),
                         '1f83d419da97a94449dad2014d1e5659e5fccd8fcc0e9c123093e9881d39ae72')


    def test_cancellation_output_closed_fields_and_refusals(self):
        registry = (CORE / 'RetainedCleanupRegistry.swift').read_text()
        emitter = registry[registry.index('        func emit() {', registry.index('struct TestCancellationObservation')):
                           registry.index('    private var testingCancellationCommand:')]
        self.assertEqual(re.findall(r' (\w+)=\\\(', emitter), CANCELLATION_FIELDS)
        line = 'M6 CANCEL OBSERVATION v1' + ''.join(' ' + k + '=0' for k in CANCELLATION_FIELDS) + '\n'
        self.assertEqual(set(parse_cancellation_records([line])), set(CANCELLATION_FIELDS))
        for bad in ([], [line, line], [line.rstrip()], [line.replace(' phase=0', ' phase=5')],
                    [line.replace(' helper=0', ' helper=4')], [line.replace(' firstPoint=0', ' firstPoint=15')],
                    [line.replace(' firstFamily=0', ' firstFamily=14')], [line.replace(' flags=0', ' flags=131072')],
                    [line.replace(' status=0', ' status=4294967296')], [line.replace(' sampled=0', ' sampled=-1')],
                    [line.replace(' sampled=0', ' sampled=18446744073709551616')],
                    [line.rstrip() + ' pid=42\n'], [line.replace(' phase=0', ' path=/fixture/private')],
                    [line.replace(' phase=0', ' error=arbitrary')], ['x'*4097]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                parse_cancellation_records(bad)

    def test_cancellation_sample_has_only_scalars_and_original_object_arm(self):
        registry = (CORE / 'RetainedCleanupRegistry.swift').read_text()
        sample = registry[registry.index('    struct TestCancellationObservation: Sendable {'):
                          registry.index('        init(budget: CustodyBudget)', registry.index('    struct TestCancellationObservation'))]
        for line in sample.splitlines()[1:]:
            self.assertRegex(line.strip(), r'^(?:var|let) [\w,: =0-9]+UInt64[\w,: =0-9]*$')
        arm = registry[registry.index('    func testingArmCancellationObservation('):registry.index('    final class StagedTickSchedulingProbe')]
        self.assertIn('testingCancellationCommand = ObjectIdentifier(command)', arm)
        self.assertNotIn('queue.sync', arm)
        self.assertIn('testingCancellationCommand == ObjectIdentifier(command)', registry)
        fixture = (CORE / 'InstallationStagedReconciliationFixtures.swift').read_text()
        self.assertEqual(fixture.count('testingArmCancellationObservation(command!)'), 1)
        self.assertIn('if failureMode == .mutationCancel { try registry.testingArmCancellationObservation(command!) }', fixture)
        self.assertEqual(fixture.count('testingTakeCancellationObservation()?.emit()'), 1)
        self.assertIn('catch {\n                    handle.testingTakeCancellationObservation()?.emit()\n                    throw error', fixture)

    def test_cancellation_timeout_reads_published_cell_without_queue_or_authority(self):
        registry = (CORE / 'RetainedCleanupRegistry.swift').read_text()
        take = registry[registry.index('        func takeCancellationObservation()'):registry.index('        private var waitBarriers:')]
        self.assertIn('cancellationObservationTaken = true', take)
        self.assertIn('value.testingCancellationObservation', take)
        self.assertNotRegex(take, r'queue|poll|validate|resources|owner|wait\(|open\(|read\(')
        snapshot = registry[registry.index('        func cancellationSnapshot()'):registry.index('        var stagedTickSchedulingProbe:')]
        self.assertNotRegex(snapshot, r'queue\.sync|\.poll\(|\.validate\(|\.revalidate\(|\b(?:open|lstat|stat|read|write|waitpid)\(')
        self.assertIn('guard testingCancellationObservation?.firstPoint == 0 else { return }', snapshot)
        delivery = registry[registry.index('        // This following turn retains no Entry,'):registry.index('    private func finish(')]
        self.assertNotRegex(delivery[delivery.index('        queue.async {'):], r'\bentry\b')
        self.assertIn('if var sample = publicationSample', delivery)

    def test_cancellation_marker_roster_is_strict_superset(self):
        roster = json.loads((ROOT / 'Tests/Fixtures/production-test-markers.json').read_text())
        self.assertEqual(len(roster['markers']), len(set(roster['markers'])))
        self.assertIn('M6 CANCEL OBSERVATION v1', roster['markers'])
        package = (ROOT / 'scripts/ci-suite.py').read_text()
        self.assertIn("missing = [value for value in markers['markers'] if value.encode() not in raw]", package)
        self.assertIn('build.require(not missing,', package)


if __name__ == '__main__':
    unittest.main()
