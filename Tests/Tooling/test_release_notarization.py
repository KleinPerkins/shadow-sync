"""Notarization control/failure paths; synthetic payloads, no Apple credentials."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_notarization', ROOT / 'scripts/notarize-release-bundle.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
REAL_HANDOFF = module.handoff


class ReleaseNotarizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-notarization-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); self.root.chmod(0o700)
        self.source = self.root / 'assembly'; self.source.mkdir(mode=0o700)
        self.app = self.source / 'ShadowSync.app'
        (self.app / 'Contents').mkdir(parents=True)
        (self.app / 'Contents/binary').write_bytes(b'signed fixture')
        self.before = {'output_entries': module.assembly.tree(self.app), 'publisher_team': 'A' * 10,
                       'version': '0.10.0', 'build': '15'}
        self.args = SimpleNamespace(assembly=str(self.source), output=str(self.root / 'output'),
            keychain=str(self.root / 'fixture.keychain-db'), notary_profile='fixture',
            signing_identity='1' * 40, source_revision='2' * 40, source_sha256='3' * 64, resume=False)
        self.calls = []; self.submissions = {}; self.wait_status = 'Accepted'; self.fail_stage = None
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(module, 'handoff', return_value=(self.before, '4' * 64)).start()
        mock.patch.object(module, 'credentials', return_value=['--keychain-profile', 'fixture']).start()
        mock.patch.object(module.assembly, 'verify_code').start()
        mock.patch.object(module, 'command', side_effect=self.command).start()
        mock.patch.object(module.sys, 'platform', 'darwin').start()

    def command(self, stage, *args, **kwargs):
        self.calls.append((stage, args))
        if stage == self.fail_stage: raise module.Refusal(stage)
        out = ''
        if stage == 'copy-signed-app': shutil.copytree(args[-2], args[-1], symlinks=True)
        elif stage in ('archive-app', 'create-disk-image'): Path(args[-1]).write_bytes(stage.encode())
        elif stage == 'disk-image-code-directory':
            return subprocess.CompletedProcess(args, 0, '', 'CDHash=' + 'f' * 40 + '\n')
        elif stage == 'notary-submit':
            path = Path(args[3]); identifier = '00000000-0000-0000-0000-' + str(len(self.submissions) + 1).zfill(12)
            self.submissions[identifier] = (path.name, module.sha(path))
            out = json.dumps({'id': identifier})
        elif stage == 'notary-wait': out = json.dumps({'id': args[3], 'status': self.wait_status})
        elif stage == 'notary-log':
            identifier = args[3]; filename, digest = self.submissions[identifier]
            Path(args[-1]).write_text(json.dumps({'jobId': identifier, 'sha256': digest, 'archiveFilename': filename,
                'status': self.wait_status, 'statusCode': 0 if self.wait_status == 'Accepted' else 4000, 'issues': None}))
        elif stage == 'staple-app':
            ticket = Path(args[-1]) / module.TICKET
            ticket.write_bytes(b'notary-ticket'); ticket.chmod(0o644)
        elif stage == 'staple-disk-image':
            with Path(args[-1]).open('ab') as stream: stream.write(b'stapled-ticket')
        return subprocess.CompletedProcess(args, 0, out, '')

    def producer_fixture(self):
        import test_release_assembly as producer_tests
        fixture = producer_tests.ReleaseAssemblyTests()
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        producer_tests.module.assemble(fixture.args)
        self.args.assembly = fixture.args.output
        self.args.source_revision = fixture.args.source_revision
        self.args.source_sha256 = fixture.args.source_sha256
        mock.patch.object(module.assembly, 'verify_source').start()
        return Path(self.args.assembly)

    def test_handoff_binds_the_real_assembler_receipt_and_inventory(self):
        root = self.producer_fixture()
        receipt, digest = REAL_HANDOFF(self.args)
        self.assertEqual(digest, module.sha(root / 'release-assembly.json'))
        self.assertEqual(receipt['output_entries'], module.assembly.tree(root / 'ShadowSync.app'))
        (root / 'ShadowSync.app/Contents/MacOS/ShadowSync').write_bytes(b'substituted binary')
        with self.assertRaisesRegex(module.Refusal, 'assembly-bytes'): REAL_HANDOFF(self.args)

    def test_handoff_rejects_wrong_source_producer_and_claimed_milestones(self):
        root = self.producer_fixture(); path = root / 'release-assembly.json'
        original = json.loads(path.read_text())
        for key, value in [('revision', '0' * 40), ('source_sha256', '0' * 64),
                           ('assembler_sha256', '0' * 64), ('publisher_team', 'B' * 10),
                           ('architecture', 'x86_64'), ('notarized', True), ('installed', True)]:
            path.write_text(json.dumps(dict(original, **{key: value})))
            with self.assertRaisesRegex(module.Refusal, 'assembly-binding'): REAL_HANDOFF(self.args)
        path.write_text(json.dumps(original))
        mock.patch.object(module.assembly, 'verify_code', side_effect=module.Refusal('publisher-signature')).start()
        with self.assertRaisesRegex(module.Refusal, 'publisher-signature'): REAL_HANDOFF(self.args)
        self.assertFalse(Path(self.args.output).exists())

    def test_package_preserves_source_and_records_separate_milestones(self):
        before = module.assembly.tree(self.app)
        result = module.package(self.args)
        self.assertEqual(module.assembly.tree(self.app), before)
        self.assertEqual(len(self.submissions), 2)
        self.assertTrue(all(result[k] for k in ('notarized', 'stapled', 'gatekeeper')))
        self.assertTrue(all(result[k] is False for k in ('published', 'installed', 'product_accepted')))
        self.assertEqual(result['artifact']['name'], 'ShadowSync-0.10.0-build15-macos-arm64.dmg')
        self.assertEqual(result['artifact']['sha256'], module.sha(Path(self.args.output) / result['artifact']['name']))
        stages = [s for s, _ in self.calls]
        self.assertLess(stages.index('validate-app-ticket'), stages.index('create-disk-image'))
        self.assertLess(stages.index('validate-disk-image-ticket'), stages.index('gatekeeper-disk-image'))

    def test_existing_output_needs_explicit_resume_and_never_resubmits(self):
        result = module.package(self.args)
        with self.assertRaises(module.Refusal): module.package(self.args)
        self.args.resume = True
        self.assertEqual(module.package(self.args), result)
        self.assertEqual(len(self.submissions), 2)

    def test_wait_failure_retains_id_and_resumes_that_submission(self):
        self.fail_stage = 'notary-wait'
        with self.assertRaises(module.Refusal): module.package(self.args)
        self.assertEqual(len(self.submissions), 1)
        self.assertTrue((Path(self.args.output) / 'app-submitted.json').is_file())
        self.fail_stage = None; self.args.resume = True
        module.package(self.args)
        self.assertEqual(len(self.submissions), 2)

    def test_unrecorded_upload_id_is_not_automatically_retried(self):
        self.fail_stage = 'notary-submit'
        with self.assertRaises(module.Refusal): module.package(self.args)
        self.fail_stage = None; self.args.resume = True
        with self.assertRaisesRegex(module.Refusal, 'notary-submission-id-unrecorded'): module.package(self.args)
        self.assertEqual(len([x for x in self.calls if x[0] == 'notary-submit']), 1)

    def test_notary_rejection_never_staples_or_completes(self):
        self.wait_status = 'Invalid'
        with self.assertRaisesRegex(module.Refusal, 'notary-not-cleanly-accepted'): module.package(self.args)
        self.assertTrue((Path(self.args.output) / 'app-notary-log.json').exists())
        self.assertFalse((Path(self.args.output) / 'release-package.json').exists())
        self.assertNotIn('staple-app', [s for s, _ in self.calls])

    def test_failed_staple_signature_gatekeeper_or_image_never_completes(self):
        for stage in ('staple-app', 'validate-app-ticket', 'gatekeeper-app', 'sign-disk-image',
                      'verify-disk-image-signature', 'staple-disk-image', 'validate-disk-image-ticket',
                      'gatekeeper-disk-image', 'verify-final-image'):
            self.args.output = str(self.root / stage); self.fail_stage = stage
            with self.assertRaises(module.Refusal): module.package(self.args)
            self.assertFalse((Path(self.args.output) / 'release-package.json').exists())

    def test_post_staple_failures_resume_without_resubmission(self):
        for stage in ('validate-app-ticket', 'gatekeeper-app', 'validate-disk-image-ticket',
                      'gatekeeper-disk-image', 'verify-final-image'):
            start = len(self.submissions)
            self.args.output = str(self.root / ('retry-' + stage)); self.args.resume = False; self.fail_stage = stage
            with self.assertRaises(module.Refusal): module.package(self.args)
            self.fail_stage = None; self.args.resume = True
            result = module.package(self.args)
            self.assertTrue(result['notarized'])
            self.assertEqual(len(self.submissions) - start, 2)
            image = Path(self.args.output) / 'submission.dmg'
            self.assertEqual(module.sha(image), module.read_record(Path(self.args.output) / 'image-signed.json')['sha256'])

    def test_concurrent_resume_refuses_before_second_submission(self):
        original = self.command; attempted = []
        def simultaneous(stage, *args, **kwargs):
            if stage == 'notary-submit' and not attempted:
                attempted.append(True)
                retry = SimpleNamespace(**vars(self.args)); retry.resume = True
                with self.assertRaisesRegex(module.Refusal, 'attempt-busy'): module.package(retry)
            return original(stage, *args, **kwargs)
        with mock.patch.object(module, 'command', side_effect=simultaneous): module.package(self.args)
        self.assertEqual(attempted, [True]); self.assertEqual(len(self.submissions), 2)

    def test_copied_app_root_mode_drift_refuses_resume(self):
        self.fail_stage = 'notary-wait'
        with self.assertRaises(module.Refusal): module.package(self.args)
        self.args.resume = True; self.fail_stage = None
        app = Path(self.args.output) / 'payload/ShadowSync.app'
        for mode in (0o700, 0o777):
            app.chmod(mode)
            with self.assertRaisesRegex(module.Refusal, 'payload-root-mode'): module.package(self.args)
        self.assertEqual(len(self.submissions), 1)

    def test_changed_submission_bytes_refuse_on_resume(self):
        self.fail_stage = 'notary-wait'
        with self.assertRaises(module.Refusal): module.package(self.args)
        (Path(self.args.output) / 'submission.zip').write_bytes(b'changed')
        self.fail_stage = None; self.args.resume = True
        with self.assertRaisesRegex(module.Refusal, 'app-archive-binding'): module.package(self.args)
        self.assertEqual(len(self.submissions), 1)

    def test_stapler_cannot_change_signed_payload_or_add_other_nodes(self):
        before = module.assembly.tree(self.app)
        ticket = self.app / module.TICKET; ticket.write_bytes(b'ticket'); ticket.chmod(0o644)
        self.assertIn(module.TICKET, module.ticket_inventory(self.app, before))
        extra = self.app / 'Contents/extra'; extra.write_bytes(b'no')
        with self.assertRaises(module.Refusal): module.ticket_inventory(self.app, before)
        extra.unlink()
        (self.app / 'Contents/binary').write_bytes(b'changed')
        with self.assertRaises(module.Refusal): module.ticket_inventory(self.app, before)

    def test_ticket_modes_links_and_zero_bytes_refuse(self):
        before = module.assembly.tree(self.app); ticket = self.app / module.TICKET
        ticket.write_bytes(b'ticket'); ticket.chmod(0o755)
        with self.assertRaises(module.Refusal): module.ticket_inventory(self.app, before)
        ticket.chmod(0o644); ticket.write_bytes(b'')
        with self.assertRaises(module.Refusal): module.ticket_inventory(self.app, before)
        ticket.unlink(); ticket.symlink_to('binary')
        with self.assertRaises(module.Refusal): module.ticket_inventory(self.app, before)

    def test_completed_artifact_tamper_refuses(self):
        result = module.package(self.args)
        (Path(self.args.output) / result['artifact']['name']).write_bytes(b'changed')
        self.args.resume = True
        with self.assertRaisesRegex(module.Refusal, 'completed-artifact-binding'): module.package(self.args)

    def test_resume_cannot_adopt_other_source_or_extra_payload(self):
        module.package(self.args); self.args.resume = True; self.args.source_revision = '5' * 40
        with self.assertRaisesRegex(module.Refusal, 'resume-binding'): module.package(self.args)
        self.args.source_revision = '2' * 40
        (Path(self.args.output) / 'payload/extra').write_bytes(b'private data')
        with self.assertRaisesRegex(module.Refusal, 'payload-layout'): module.package(self.args)

    def test_resume_revalidates_accepted_log_and_milestone_fields(self):
        module.package(self.args); self.args.resume = True
        root = Path(self.args.output); path = root / 'release-package.json'
        receipt = json.loads(path.read_text()); receipt['installed'] = True; path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(module.Refusal, 'completed-artifact-binding'): module.package(self.args)
        receipt['installed'] = False; path.write_text(json.dumps(receipt))
        path = root / 'app-notary-log.json'; log = json.loads(path.read_text())
        log['issues'] = [{'severity': 'warning'}]; path.write_text(json.dumps(log))
        with self.assertRaisesRegex(module.Refusal, 'accepted-log-binding'): module.package(self.args)

    def test_mismatched_apple_log_digest_never_qualifies(self):
        self.fail_stage = 'notary-wait'
        with self.assertRaises(module.Refusal): module.package(self.args)
        root = Path(self.args.output); submission = module.read_record(root / 'app-submitted.json')
        (root / 'app-notary-log.json').write_text(json.dumps(dict(jobId=submission['id'], sha256='0' * 64,
            archiveFilename='submission.zip', status='Accepted', statusCode=0, issues=None)))
        self.fail_stage = None; self.args.resume = True
        with self.assertRaisesRegex(module.Refusal, 'notary-not-cleanly-accepted'): module.package(self.args)
        self.assertFalse((root / 'release-package.json').exists())


if __name__ == '__main__': unittest.main()
