"""Exact ordinary policy negatives, adapted from the reviewed Sterling baseline."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('ordinary_merge_policy', ROOT / 'scripts/auto-merge.py')
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)

class AutoMergeTests(unittest.TestCase):
    def setUp(self):
        self.run={'event':'pull_request','conclusion':'success','head_repository':{'full_name':merge.REPO},'head_sha':'a'*40}
        self.pr={'state':'open','draft':False,'number':7,'base':{'ref':'main','repo':{'full_name':merge.REPO}},'head':{'repo':{'full_name':merge.REPO},'sha':'a'*40,'ref':'feature'},'author_association':'OWNER'}
    def test_ordinary_verified_head_eligible(self):
        self.assertTrue(merge.eligible(self.pr,self.run,['Sources/ShadowSyncCore/ReportModel.swift']))
    def test_release_and_draft_prs_require_human(self):
        for field,value in [('draft',True),('state','closed')]:
            pr=copy.deepcopy(self.pr);pr[field]=value;self.assertFalse(merge.eligible(pr,self.run,['README.md']))
        self.pr['head']['ref']='release-please--branches--main'
        self.assertFalse(merge.eligible(self.pr,self.run,['CHANGELOG.md']))
    def test_forks_and_head_races_are_rejected(self):
        self.pr['head']['sha']='b'*40;self.assertFalse(merge.eligible(self.pr,self.run,['README.md']))
        self.pr['head']['sha']='a'*40;self.pr['head']['repo']['full_name']='someone/fork'
        self.assertFalse(merge.eligible(self.pr,self.run,['README.md']))
    def test_privileged_paths_are_manual(self):
        for path in ('.github/workflows/release.yml','scripts/release.py','Configuration/signing.entitlements','Sources/ShadowSyncApp/AppUpdater.swift','AGENTS.md','Makefile','.gitleaks.toml','Package.resolved','VERSION'):
            with self.subTest(path=path):self.assertFalse(merge.eligible(self.pr,self.run,[path]))
    def test_dependabot_and_untrusted_authors_cannot_use_ordinary_policy(self):
        self.pr['author_association']='NONE';self.pr['user']={'login':'unknown'}
        self.assertFalse(merge.eligible(self.pr,self.run,['README.md']))
        self.pr['user']['login']='dependabot[bot]'
        self.assertFalse(merge.eligible(self.pr,self.run,['README.md']))
    def test_failed_ci_and_empty_file_lists_never_approve(self):
        self.assertFalse(merge.eligible(self.pr,self.run,[]))
        self.run['conclusion']='failure';self.assertFalse(merge.eligible(self.pr,self.run,['README.md']))


if __name__ == "__main__":
    unittest.main()
