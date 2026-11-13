from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import unittest
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('ci_crash', ROOT / 'scripts/ci_crash_diagnostic.py')
crash = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(crash)


class CrashDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.uuid = '12345678-1234-1234-1234-123456789abc'
        self.exe = Path('/private/tmp/shadow-sync-ci.fixture/tests/ShadowSyncSelfTest')
        self.report = {'pid': 42, 'procName': 'ShadowSyncSelfTest', 'procPath': str(self.exe),
            'machine': 'must-not-export', 'faultingThread': 0,
            'procLaunch': datetime.now(timezone.utc).isoformat(),
            'captureTime': datetime.now(timezone.utc).isoformat(),
            'usedImages': [{'uuid': self.uuid, 'name': 'ShadowSyncSelfTest', 'path': str(self.exe)}],
            'threads': [{'frames': [{'imageIndex': 0, 'imageOffset': 123,
                'symbol': 'publicFixture()'}, {'imageIndex': 0, 'imageOffset': 456,
                'symbol': '/private/fixture-path'}], 'registers': 'must-not-export'}]}

    def project(self, report=None):
        return crash.project(json.dumps({'bug_type': '309'})+'\n'+json.dumps(report or self.report),
            pid=42, executable=self.exe, binary_uuid=self.uuid, started=1, finished=crash.time.time()+1)

    def test_projection_retains_frames_without_paths_or_machine_fields(self):
        value = self.project(); encoded = json.dumps(value)
        self.assertEqual(len(value['frames']), 2)
        self.assertEqual(value['frames'][0]['symbol'], 'publicFixture()')
        self.assertNotIn('symbol', value['frames'][1])
        for forbidden in ('must-not-export', '/private', 'registers', 'procPath'):
            self.assertNotIn(forbidden, encoded)

    def test_foreign_pid_path_name_or_uuid_refuses(self):
        for key, value in [('pid',43),('procName','Other'),('procPath','/other')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.project(dict(self.report, **{key:value}))
        self.report['usedImages'][0]['uuid'] = '87654321-1234-1234-1234-123456789abc'
        with self.assertRaises(ValueError): self.project()

    def test_invalid_frame_and_empty_trace_refuse(self):
        for frames in ([],[{'imageIndex': -1,'imageOffset':1}], [{'imageIndex':0,'imageOffset':-1}]):
            self.report['threads'][0]['frames']=frames
            with self.subTest(frames=frames),self.assertRaises(ValueError):self.project()

    def test_capture_reads_only_matching_fixture_report_and_keeps_failure(self):
        hosted={'GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
                'RUNNER_OS':'macOS','GITHUB_REPOSITORY':'KleinPerkins/shadow-sync'}
        with tempfile.TemporaryDirectory(prefix='shadow-sync-crash-test-') as name:
            root=Path(name).resolve(); reports=root/'Library/Logs/DiagnosticReports'
            reports.mkdir(parents=True); evidence=root/'evidence'; evidence.mkdir()
            (reports/'ShadowSyncSelfTest-0-malformed.ips').write_text('[]\n[]')
            (reports/'ShadowSyncSelfTest-fixture.ips').write_text(
                json.dumps({'bug_type':'309'})+'\n'+json.dumps(self.report))
            result={'exit':-11,'pid':42,'original_reaped':True,'passed':False}
            with patch.dict(crash.os.environ,hosted,clear=True), \
                    patch.object(crash.pwd,'getpwuid',return_value=SimpleNamespace(pw_name='runner',pw_dir=str(root))), \
                    patch.object(crash.subprocess,'run',return_value=SimpleNamespace(stdout='UUID: '+self.uuid+' (arm64) fixture')):
                crash.capture(result,executable=self.exe,evidence=evidence,started=0,source_sha256='a'*64)
            value=json.loads((evidence/'hosted-crash.json').read_text())
            self.assertEqual(value['status'],'captured'); self.assertFalse(result['passed'])
            self.assertNotIn(str(root),json.dumps(value))

    def test_stale_future_and_unzoned_capture_times_refuse(self):
        for key in ('procLaunch', 'captureTime'):
            for value in ('1970-01-01T00:00:00+00:00','2099-01-01T00:00:00+00:00','2026-01-01T00:00:00'):
                with self.subTest(key=key,value=value),self.assertRaises(ValueError):
                    self.project(dict(self.report,**{key:value}))

    def test_diagnostic_write_failure_preserves_original_failure(self):
        hosted={'GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
                'RUNNER_OS':'macOS','GITHUB_REPOSITORY':'KleinPerkins/shadow-sync'}
        result={'exit':-11,'pid':42,'original_reaped':True,'passed':False}
        with patch.dict(crash.os.environ,hosted,clear=True), \
                patch.object(crash.pwd,'getpwuid',return_value=SimpleNamespace(pw_name='runner',pw_dir='/nonexistent-fixture-home')), \
                patch.object(crash.subprocess,'run',side_effect=OSError('fixture unavailable')), \
                patch.object(crash.Path,'open',side_effect=OSError('fixture evidence unavailable')):
            crash.capture(result,executable=self.exe,evidence=Path('/unopened'),started=0,source_sha256='a'*64)
        self.assertEqual(result,{'exit':-11,'pid':42,'original_reaped':True,'passed':False})

    def test_local_execution_and_noncrashes_never_read_host_reports(self):
        hosted={'GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
                'RUNNER_OS':'macOS','GITHUB_REPOSITORY':'KleinPerkins/shadow-sync'}
        cases=[({},-11),({**hosted,'RUNNER_ENVIRONMENT':'self-hosted'},-11),
               ({**hosted,'GITHUB_REPOSITORY':'fixture-owner/other'},-11),(hosted,0),(hosted,1)]
        for env,code in cases:
            with self.subTest(env=env,code=code),patch.dict(crash.os.environ,env,clear=True), \
                    patch.object(crash.pwd,'getpwuid',side_effect=AssertionError('host read')):
                crash.capture({'exit':code,'pid':42,'original_reaped':True},executable=self.exe,
                    evidence=Path('/unopened'),started=0,source_sha256='a'*64)


if __name__ == '__main__':unittest.main()
