"""Closed projection contract tests use neutral data and no filesystem discovery."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('projection_adapter', ROOT / 'Resources/PolicyAdapter.py')
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


def fixture_projection(policy):
    dispatcher = b'#!/bin/sh\nexit 0\n'
    return {
        'schema': 'shadow-sync-host-policy-projection/v1',
        'source_inputs': {
            'worktree_policy': dict(policy),
            'host_overlay': {'path': 'owner/overlay.json', 'sha256': '1' * 64},
            'hook_dispatcher': {'path': 'owner/dispatcher', 'sha256': adapter.digest(dispatcher)},
        },
        'governed_root': {'components': ['workspace'], 'display_label': '~/workspace',
                          'repository_id': 'fixture-owner/root'},
        'shelves': [['products'], ['tools'], ['reference']],
        'path_policy': {'excluded': ['excluded'], 'read_only': ['reference/*'],
                        'artifacts': ['generated'], 'writable': ['.']},
        'permanent_no_touch_repository_ids': ['fixture-owner/protected'],
        'managed_locations': [{'kind': 'codex', 'components': ['manager', 'worktrees'],
                               'minimum_depth': 2}],
        'hooks': {'foreign_markers': ['fixture-hook'],
                  'dispatcher_base64': base64.b64encode(dispatcher).decode(),
                  'dispatcher_sha256': adapter.digest(dispatcher)},
        'awa_evidence': None,
    }


class HostProjectionTests(unittest.TestCase):
    def setUp(self):
        self.policy = {'path': 'policy.yml', 'sha256': 'a' * 64}
        self.value = fixture_projection(self.policy)

    def decode(self, value=None):
        raw = json.dumps(self.value if value is None else value).encode()
        return adapter.validate_host_projection(raw, self.policy)

    def test_complete_neutral_projection(self):
        self.assertEqual(self.decode(), self.value)

    def test_each_object_is_closed(self):
        paths = [(), ('source_inputs',), ('source_inputs', 'worktree_policy'),
                 ('governed_root',), ('path_policy',), ('hooks',)]
        for path in paths:
            for mutation in ('extra', 'missing'):
                value = copy.deepcopy(self.value); obj = value
                for key in path: obj = obj[key]
                if mutation == 'extra': obj['unknown'] = True
                else: del obj[next(iter(obj))]
                with self.subTest(path=path, mutation=mutation), self.assertRaises(adapter.Refusal):
                    self.decode(value)

    def test_duplicate_keys_and_newer_schema_refuse(self):
        with self.assertRaises(adapter.Refusal):
            adapter.validate_host_projection(b'{"schema":1,"schema":2}', self.policy)
        self.value['schema'] = 'shadow-sync-host-policy-projection/v2'
        with self.assertRaises(adapter.Refusal): self.decode()

    def test_source_policy_digest_and_dispatcher_bytes_are_bound(self):
        variants = [lambda v: v['source_inputs']['worktree_policy'].update(sha256='b' * 64),
                    lambda v: v['hooks'].update(dispatcher_base64=base64.b64encode(b'other').decode()),
                    lambda v: v['source_inputs']['hook_dispatcher'].update(sha256='c' * 64),
                    lambda v: v['hooks'].update(dispatcher_base64='not base64')]
        for mutate in variants:
            value = copy.deepcopy(self.value); mutate(value)
            with self.subTest(value=value), self.assertRaises(adapter.Refusal): self.decode(value)

    def test_root_paths_labels_and_ids_cannot_inject_or_escape(self):
        variants = [('components', []), ('components', ['..']), ('components', ['a/b']),
                    ('components', ['a\\b']), ('components', ['a\n']), ('components', ['~']),
                    ('display_label', '/private/other'), ('repository_id', 'invalid'),
                    ('repository_id', 'OWNER/REPO')]
        for key, value in variants:
            obj = copy.deepcopy(self.value); obj['governed_root'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(adapter.Refusal): self.decode(obj)

    def test_shelves_must_be_unique_disjoint_relative_directories(self):
        for shelves in ([], [['.hidden']], [['products'], ['products']], [['products'], ['products', 'nested']],
                        [['..']], [['a', 'b', 'c', 'd']], [['a']] * 33):
            self.value['shelves'] = shelves
            with self.subTest(shelves=shelves), self.assertRaises(adapter.Refusal): self.decode()

    def test_path_patterns_are_bounded_and_writable_cannot_override_restrictions(self):
        for pattern in ('../x', '/x', 'a//b', 'a/?', '**', 'a/*/b', 'a/[x]', ''):
            value = copy.deepcopy(self.value); value['path_policy']['excluded'] = [pattern]
            with self.subTest(pattern=pattern), self.assertRaises(adapter.Refusal): self.decode(value)
        for writable in (['reference/item'], ['generated'], ['excluded/child'], ['*']):
            value = copy.deepcopy(self.value); value['path_policy']['writable'] = writable
            with self.subTest(writable=writable), self.assertRaises(adapter.Refusal): self.decode(value)
        value = copy.deepcopy(self.value)
        value['path_policy'].update(excluded=['.'], read_only=['.'], writable=['.'])
        with self.assertRaises(adapter.Refusal): self.decode(value)

    def test_managed_namespaces_require_unique_kinds_paths_and_real_integer_depth(self):
        original = self.value['managed_locations'][0]
        for override in ({'kind': 'unknown'}, {'minimum_depth': True}, {'minimum_depth': 0},
                         {'minimum_depth': 17}, {'components': ['workspace']}, {'extra': True}):
            value = copy.deepcopy(self.value); value['managed_locations'][0].update(override)
            with self.subTest(override=override), self.assertRaises(adapter.Refusal): self.decode(value)
        for second in (dict(original), dict(original, kind='awa'),
                       dict(original, kind='awa', components=['manager'])):
            value = copy.deepcopy(self.value); value['managed_locations'].append(second)
            with self.subTest(second=second), self.assertRaises(adapter.Refusal): self.decode(value)

    def test_optional_awa_evidence_is_explicit_closed_and_relative(self):
        self.value['awa_evidence'] = {'adapter_path': 'owner/adapter', 'root_records_path': 'owner/records',
                                      'lease_components': ['.awa', 'lease.json']}
        self.assertEqual(self.decode(), self.value)
        for key, replacement in (('adapter_path', '../adapter'), ('root_records_path', '/records'),
                                  ('lease_components', ['..']), ('unknown', True)):
            value = copy.deepcopy(self.value); value['awa_evidence'][key] = replacement
            with self.subTest(key=key), self.assertRaises(adapter.Refusal): self.decode(value)

    def test_lists_ids_and_hook_markers_are_typed_bounded_and_unique(self):
        for ids in (['BAD/ID'], ['x/y', 'x/y'], [True], 'x/y'):
            value = copy.deepcopy(self.value); value['permanent_no_touch_repository_ids'] = ids
            with self.subTest(ids=ids), self.assertRaises(adapter.Refusal): self.decode(value)
        for markers in ([], ['a/b'], ['hook', 'hook'], [1], ['../hook']):
            value = copy.deepcopy(self.value); value['hooks']['foreign_markers'] = markers
            with self.subTest(markers=markers), self.assertRaises(adapter.Refusal): self.decode(value)


if __name__ == '__main__':
    unittest.main()
