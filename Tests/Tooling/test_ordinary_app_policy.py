"""Exclusive ordinary policy negatives; owner identity never bypasses protected files."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import github_automation as github
spec = importlib.util.spec_from_file_location('ordinary_merge_policy', ROOT / 'scripts/auto-merge.py')
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)


class AutoMergeTests(unittest.TestCase):
    def setUp(self):
        identity = {'full_name': github.REPO, 'id': github.REPOSITORY_ID}
        self.run = {'event': 'pull_request', 'conclusion': 'success', 'path': github.CI_PATH,
                    'head_repository': identity, 'head_sha': 'a'*40}
        self.pr = {'state': 'open', 'draft': False, 'number': 7,
                   'base': {'ref': 'main', 'sha': 'b'*40, 'repo': identity},
                   'head': {'repo': identity, 'sha': 'a'*40, 'ref': 'feature'},
                   'user': {'login': github.OWNER_LOGIN, 'id': github.OWNER_ID, 'type': 'User'}}

    def eligible(self, files=None, pr=None):
        return merge.eligible(pr or self.pr, self.run,
                              ['Sources/ShadowSyncCore/ReportModel.swift'] if files is None else files,
                              base_sha='b'*40)

    def test_ordinary_verified_head_eligible(self):
        self.assertTrue(self.eligible())

    def test_release_and_draft_prs_require_human(self):
        for field, value in [('draft', True), ('state', 'closed')]:
            pr = copy.deepcopy(self.pr); pr[field] = value; self.assertFalse(self.eligible(pr=pr))
        for branch in ('release-please--branches--main', 'dependabot/example'):
            self.pr['head']['ref'] = branch
            self.assertFalse(self.eligible())

    def test_forks_and_head_races_are_rejected(self):
        self.pr['head']['sha'] = 'c'*40; self.assertFalse(self.eligible())
        self.pr['head']['sha'] = 'a'*40; self.pr['base']['sha'] = 'c'*40
        self.assertFalse(self.eligible())
        self.pr['base']['sha'] = 'b'*40; self.pr['head']['repo']['full_name'] = 'fixture-owner/fork'
        self.assertFalse(self.eligible())

    def test_privileged_paths_are_manual(self):
        for path in ('.github/workflows/release.yml', 'scripts/release.py', 'Configuration/signing.entitlements',
                     'Sources/ShadowSyncApp/AppUpdater.swift', 'AGENTS.md', 'Makefile', '.gitleaks.toml',
                     'Package.resolved', 'VERSION', 'delivery/access.py', 'docs/adr/decision.md'):
            with self.subTest(path=path): self.assertFalse(self.eligible([path]))

    def test_dependabot_and_untrusted_authors_cannot_use_ordinary_policy(self):
        for association in ('OWNER', 'MEMBER', 'COLLABORATOR'):
            self.pr['author_association'] = association
            for user in ({'login': 'fixture-owner', 'id': 10, 'type': 'User'},
                         {'login': 'dependabot[bot]', 'id': github.DEPENDABOT_ID, 'type': 'Bot'}):
                self.pr['user'] = user; self.assertFalse(self.eligible())

    def test_failed_ci_and_empty_file_lists_never_approve(self):
        self.assertFalse(self.eligible([]))
        self.run['conclusion'] = 'failure'; self.assertFalse(self.eligible())


if __name__ == '__main__':
    unittest.main()
