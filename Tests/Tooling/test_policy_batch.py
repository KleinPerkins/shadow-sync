"""Bounded policy batches retain complete, ordered, digest-bound decisions."""
import unittest
from unittest.mock import patch

import test_policy_adapter as support

adapter = support.adapter
encoded = support.encoded


class PolicyBatchTests(unittest.TestCase):
    def setUp(self):
        self.fixture = support.PolicyAdapterTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.request = {'schema': 'shadow-sync-policy-batch-request/v1', 'nonce': 'c' * 32,
                        'binding_sha256': self.fixture.request['binding_sha256'],
                        'candidates': [str(self.fixture.home / 'first'), str(self.fixture.home / 'second')]}

    def run_batch(self, request=None):
        return adapter.classify_batch(encoded(self.request if request is None else request),
                                      encoded(self.fixture.contract), home=str(self.fixture.home),
                                      uid=self.fixture.uid, temporary_parent=str(self.fixture.temporary))

    def test_complete_ordered_batch_is_redacted_and_digest_bound(self):
        result = self.run_batch()
        self.assertEqual(result['schema'], 'shadow-sync-policy-batch-response/v1')
        self.assertEqual(result['nonce'], self.request['nonce'])
        self.assertEqual(result['binding_sha256'], self.request['binding_sha256'])
        self.assertEqual(result['results'], [
            {'index': i, 'matched': False, 'kind': 'none', 'policy_valid': True} for i in range(2)])
        for path in self.request['candidates']: self.assertNotIn(path, encoded(result).decode())
        self.assertEqual(list(self.fixture.temporary.iterdir()), [])

    def test_all_candidates_validate_before_any_configuration_read(self):
        for candidates in ([], [self.request['candidates'][0]] * 2,
                           self.request['candidates'] + ['/invalid/../target'],
                           [None], [True], 'not-a-list',
                           [str(self.fixture.home / str(i)) for i in range(65)]):
            request = dict(self.request, candidates=candidates)
            with self.subTest(candidates=candidates), patch.object(adapter, 'read_owned_absolute') as read:
                with self.assertRaises(adapter.Refusal): self.run_batch(request)
                read.assert_not_called()

    def test_closed_request_and_size_limits(self):
        for key, value in (('unknown', True), ('schema', 'future/v2'), ('nonce', True),
                           ('binding_sha256', 'a' * 63)):
            with self.subTest(key=key), self.assertRaises(adapter.Refusal):
                self.run_batch(dict(self.request, **{key: value}))
        with self.assertRaises(adapter.Refusal):
            adapter.classify_batch(b' ' * (262144 + 1), encoded(self.fixture.contract),
                                   home=str(self.fixture.home), uid=self.fixture.uid,
                                   temporary_parent=str(self.fixture.temporary))

    def test_snapshot_drift_never_returns_partial_allow_results(self):
        real = adapter.classify
        calls = []
        def drift(*args, **kwargs):
            result = real(*args, **kwargs); calls.append(result)
            if len(calls) == 1:
                self.fixture.policy.write_bytes(self.fixture.policy.read_bytes() + b'\n')
            return result
        with patch.object(adapter, 'classify', side_effect=drift), self.assertRaises(adapter.Refusal):
            self.run_batch()
        self.assertEqual(len(calls), 1)
        self.assertEqual(list(self.fixture.temporary.iterdir()), [])

    def test_inconsistent_or_incomplete_internal_response_refuses(self):
        real = adapter.classify
        for change in ({'policy_sha256': '0' * 64}, {'nonce': 'd' * 32},
                       {'matched': 'false'}, {'kind': 'unknown'}, {'extra': True}):
            count = 0
            def changed(*args, **kwargs):
                nonlocal count
                result = real(*args, **kwargs); count += 1
                if count == 2: result.update(change)
                return result
            with self.subTest(change=change), patch.object(adapter, 'classify', side_effect=changed):
                with self.assertRaises(adapter.Refusal): self.run_batch()

    def test_maximum_batch_keeps_one_result_per_index(self):
        self.request['candidates'] = [str(self.fixture.home / ('candidate-' + str(i))) for i in range(64)]
        result = self.run_batch()
        self.assertEqual([r['index'] for r in result['results']], list(range(64)))
        self.assertEqual(list(self.fixture.temporary.iterdir()), [])

    def test_dispatch_preserves_single_request_and_rejects_unknown_schemas(self):
        kwargs = {'home': str(self.fixture.home), 'uid': self.fixture.uid,
                  'temporary_parent': str(self.fixture.temporary)}
        single = adapter.dispatch(encoded(self.fixture.request), encoded(self.fixture.contract), **kwargs)
        self.assertEqual(single['schema'], adapter.RESPONSE_SCHEMA)
        batch = adapter.dispatch(encoded(self.request), encoded(self.fixture.contract), **kwargs)
        self.assertEqual(batch, self.run_batch())
        with self.assertRaises(adapter.Refusal):
            adapter.dispatch(encoded(dict(self.request, schema='unknown')), encoded(self.fixture.contract), **kwargs)


if __name__ == '__main__':
    unittest.main()
