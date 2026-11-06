"""The executable catalog and both guardian admission surfaces must agree."""
import ast
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GuardianRegistrationTests(unittest.TestCase):
    def test_closed_rosters_match_compiled_catalog_and_executor(self):
        catalog = (ROOT / 'Tests/ShadowSyncSelfTests/CISuites.swift').read_text()
        compiled = re.findall(r'caseIDs\.filter \{ \[([^\]]+)\]\.contains', catalog)
        self.assertEqual(len(compiled), 1)
        names = re.findall(r'"([a-z0-9-]+)"', compiled[0])
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(set(names), set(re.findall(r'Entry\(id: "([a-z0-9-]+)"', catalog)))
        guardian = (ROOT / 'Sources/ShadowSyncCore/RuntimeSuiteGuardian.swift').read_text()
        for target in ('suite', r'arguments\[2\]'):
            prefix = r'guard\s+' if target == 'suite' else ''
            rows = re.findall(prefix + r'\[([^\[\]]+)\]\.contains\(' + target + r'\)', guardian)
            self.assertEqual(len(rows), 1)
            values = re.findall(r'"([a-z0-9-]+)"', rows[0])
            self.assertEqual(len(values), len(set(values)))
            self.assertEqual(set(values), set(names))
        executor = ast.parse((ROOT / 'scripts/runtime_guardian_executor.py').read_text())
        clauses = [node for node in ast.walk(executor) if isinstance(node, ast.Compare)
                   and isinstance(node.left, ast.Name) and node.left.id == 'suite'
                   and len(node.ops) == 1 and isinstance(node.ops[0], ast.NotIn)
                   and isinstance(node.comparators[0], ast.Set)]
        # The other closed set is the smaller fault-probe selector contract.
        values = [ast.literal_eval(node.comparators[0]) for node in clauses]
        self.assertEqual(sum(value == set(names) for value in values), 1)
        self.assertTrue(all(value <= set(names) for value in values))


if __name__ == '__main__':
    unittest.main()
