"""Offline source and fixture controls; no Swift/runtime execution is implied."""
import ast
import hashlib
import io
import json
from pathlib import Path
import textwrap
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SESSION = ROOT / 'Sources/ShadowSyncCore/PolicyCatalogSession.swift'
FIXTURE = ROOT / 'Sources/ShadowSyncCore/HostPolicySnapshotSelfTests.swift'
OLD_PARENTS = 'let parents = Set(shelves.map { Data((projectionRoot + "/" + $0.joined(separator: "/")).utf8) })'
ROOT_PARENTS = 'let parents = Set([Data(projectionRoot.utf8)]\n            + shelves.map { Data((projectionRoot + "/" + $0.joined(separator: "/")).utf8) })'
PREFETCH_BASE_SHA256 = 'b44be752e9ae36433621c7cc79b3182cd1b177dcfa9c8c66cced60c533710a8b'


def prefetch(text):
    start = text.index('    static func prefetchCatalogMetadata(')
    return text[start:text.index('\n    // The sole caller', start)]


def verify_prefetch(text):
    value = prefetch(text)
    if value.count(ROOT_PARENTS) != 1:
        raise ValueError('exact UTF8 root parent absent')
    original = value.replace(ROOT_PARENTS, OLD_PARENTS)
    if hashlib.sha256(original.encode()).hexdigest() != PREFETCH_BASE_SHA256:
        raise ValueError('prefetch ordering, roster, bounds or byte semantics changed')


def adapter(mode, candidates):
    # Exercise the fixture's actual request/response discriminator. Its source
    # stays inside a pure selected mode: no child, filesystem or clock action.
    text = FIXTURE.read_text()
    begin = text.index('            import json,sys,time', text.index('private final class SessionFixture'))
    end = text.index('            """', begin)
    code = textwrap.dedent(text[begin:end])
    replacements = {'\\(mode)': mode, '\\(fixture.path)': '/fixture/home',
                    '\\(snapshot.binding.policy.sha256)': 'a' * 64,
                    '\\(snapshot.binding.module.sha256)': 'b' * 64}
    for old, new in replacements.items():
        code = code.replace(old, new)
    if '\\(' in code:
        raise ValueError('unbound fixture interpolation')
    namespace = {}
    exec(compile(ast.parse(code), '<root-shelf-fixture-adapter>', 'exec'), namespace)
    request = {'candidates': candidates, 'nonce': 'fixture-nonce', 'binding_sha256': 'c' * 64}
    output = io.StringIO()
    with mock.patch('sys.stdin', io.StringIO(json.dumps(request))), mock.patch('sys.stdout', output):
        result = namespace['run_sealed']({})
    if result != 0:
        raise ValueError('fixture adapter did not complete')
    return json.loads(output.getvalue())['results']


class RootShelfPrefetchTests(unittest.TestCase):
    def test_exact_root_parent_is_the_only_prefetch_semantic_delta(self):
        verify_prefetch(SESSION.read_text())

    def test_original_omission_and_order_bound_byte_mutants_refuse(self):
        text = SESSION.read_text()
        mutations = [text.replace(ROOT_PARENTS, OLD_PARENTS),
                     text.replace('var result = required', 'var result = required.reversed()'),
                     text.replace('result.count < 64', 'result.count < 65'),
                     text.replace('cached.count + result.count < 4096', 'cached.count + result.count < 4097'),
                     text.replace('Data(projectionRoot.utf8)', 'Data(projectionRoot.precomposedStringWithCanonicalMapping.utf8)'),
                     text.replace('"refs/remotes/origin/HEAD"', '"HEAD"')]
        for mutation in mutations:
            self.assertNotEqual(mutation, text)
            with self.assertRaises(ValueError):
                verify_prefetch(mutation)

    def test_real_fixture_adapter_discriminates_child_only_and_invalid_optional_batches(self):
        for child in ('root-empty', 'root-guarded'):
            candidate = '/fixture/home/workspace/' + child
            marker = candidate + '/.git'
            metadata = [marker + '/' + suffix for suffix in
                        ('config', 'refs', 'refs/remotes', 'refs/remotes/origin', 'refs/remotes/origin/HEAD')]
            complete = [candidate, marker] + metadata
            self.assertEqual(adapter('root-shelf-prefetch', [candidate]), [])
            for missing in [marker] + metadata:
                self.assertEqual(adapter('root-shelf-prefetch', [p for p in complete if p != missing]), [])
            rows = adapter('root-shelf-prefetch', complete)
            self.assertEqual([row['index'] for row in rows], list(range(len(complete))))
            self.assertTrue(all(row['policy_valid'] for row in rows))
            protected = [row for row in rows if row['matched']]
            self.assertEqual(protected, [rows[2]] if child == 'root-guarded' else [])
            if child == 'root-empty':
                invalid = adapter('root-shelf-prefetch-invalid', complete)
                self.assertEqual(invalid[2]['kind'], 'invalid_candidate')
                self.assertTrue(invalid[2]['matched'])
                self.assertTrue(all(row['kind'] == 'none' for row in invalid[:2]))

    def test_registered_native_fixture_retains_original_controls_and_adds_root_cuts(self):
        text = FIXTURE.read_text()
        # These are retained source obligations, not native pass receipts.
        for required in ('prefetched(partial) == partial + [roster[1]]',
                         'prefetched(full) == full', 'audit.invocations.count <= 2',
                         'protectedCatalog.catalog.counters.filesOpened == 0',
                         'expand(partial) == partial + [marker]',
                         'expand([child], cached: nearFull) == [child, marker]',
                         'rootAudit.invocations.count == 3',
                         'rootCatalog.catalog.counters.filesOpened == catalog.catalog.counters.filesOpened',
                         'rootGuarded.section == .protected',
                         '!rootCatalog.catalog.candidates.contains(where: { $0.displayLabel == "root-empty" })',
                         'expand([rootChild]) == [rootChild, rootMarker] + rootMetadata',
                         'expand(rootReserved) == rootReserved',
                         'expand(rootPartial) == rootPartial + [rootMarker]',
                         'expand([rootChild], cached: nearFull) == [rootChild, rootMarker]',
                         'root prefetch consumed mandatory cache slot',
                         'cached root marker suppressed uncached fixed metadata',
                         'projection + "/.hidden"', 'projection + "-other/root-ready"',
                         'projection + "/root-ready/nested"',
                         'root prefetch normalized candidate bytes',
                         'root prefetch normalized projection bytes',
                         'root parent accepted canonically equivalent wrong bytes',
                         'cached root marker bypassed current authority',
                         'root drift refusal retained prefetched decisions',
                         'invalid optional root metadata retained a partial batch decision',
                         'probe.count == 2 && probeAudit.invocations.count == 1'):
            self.assertIn(required, text)
        for case in ('POLICY-SESSION-T01-snapshot-helper-and-catalog-composition',
                     'POLICY-SESSION-T60-lexical-shelf-child-prefetch-preserves-admission-bounds'):
            self.assertIn('RuntimeFixtureSession.withCase("' + case + '")', text)
            self.assertIn('onPass("' + case + '")', text)
        session = SESSION.read_text()
        self.assertLess(session.index('let admitted = try decisions.map'),
                        session.index('for (candidate, disposition) in zip(requested, admitted)'))
        self.assertIn('throw PolicyHelperError.unavailable', session[session.index('let admitted = try decisions.map'):])
        self.assertIn('decisionsByPath.removeAll(keepingCapacity: true)\n            decisionDeadline = nil', session)
