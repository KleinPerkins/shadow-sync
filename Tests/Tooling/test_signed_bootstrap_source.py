"""Offline adversarial checks of selected Bootstrap factories and retained profiles."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('signed_bootstrap_source',
    ROOT / 'scripts/verify-signed-bootstrap-source.py')
source = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source)


class SignedBootstrapSourceTests(unittest.TestCase):
    def setUp(self):
        self.raw = source.read_sources(ROOT)

    def refuses(self, filename, original, replacement, reason):
        values = dict(self.raw)
        self.assertEqual(values[filename].count(original), 1)
        values[filename] = values[filename].replace(original, replacement)
        with self.assertRaisesRegex(ValueError, reason):
            source.verify_sources(values)

    def test_selected_build_matrix_reaches_retained_command_paths(self):
        self.assertEqual(source.verify_sources(self.raw), [
            'four-build-selected-factories', 'reachable-bootstrap-commands', 'original-owner-helper-chain',
            'qualified-command-preparation', 'retained-sealed-decodes', 'original-stop-deadlines'])

    def test_each_of_seven_factory_branches_rejects_unsigned_selection_in_signed_build(self):
        filename = 'InstallationBootstrap.swift'
        fence = '#if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE'
        self.assertEqual(self.raw[filename].count(fence), 7)
        for route, signature in source.ROUTES.items():
            original = source.body(self.raw[filename], signature)
            count = original.count(fence)
            self.assertEqual(count, 1 if route == 'ready' else 2)
            for index in range(count):
                with self.subTest(route=route, branch=index):
                    pieces = original.split(fence)
                    replacement = pieces[0]
                    for offset, piece in enumerate(pieces[1:]):
                        replacement += ('#if SHADOW_SYNC_TESTING' if index == offset else fence) + piece
                    self.refuses(filename, original, replacement, 'selected-(context|command):' + route)

    def test_non_testing_builds_cannot_select_fixture_factories(self):
        filename = 'InstallationBootstrap.swift'
        original = source.body(self.raw[filename], source.ROUTES['start'])
        changed = original.replace('#if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE',
                                   '#if !SHADOW_SYNC_SIGNED_FIXTURE', 1)
        self.refuses(filename, original, changed, 'selected-context:start')

    def test_inactive_correct_factory_and_comment_cannot_mask_selected_bad_factory(self):
        filename = 'InstallationBootstrap.swift'
        original = source.body(self.raw[filename], source.ROUTES['committed-stop'])
        changed = original.replace('return try .borrowing(capability)',
                                  'return try .testingCommittedStop(capability, root: fixtureRoot!)')
        changed += '\n// return try .borrowing(capability)\n#if !SHADOW_SYNC_TESTING\nreturn try .borrowing(capability)\n#endif\n'
        self.refuses(filename, original, changed, 'selected-context:committed-stop')

    def test_borrowing_must_keep_actual_helper_and_profile_bound_destination(self):
        filename = 'CommandCustodyContext.swift'
        for signature, reason in (
            ('static func borrowing(_ admission: InstallationStagedAdmission,', 'borrowed-staged-helper'),
            ('static func borrowing(_ admission: InstallationStagedStopAdmission,', 'borrowed-staged-helper'),
            ('static func borrowing(_ stop: CustodyCatalogStore.InstallationCommittedStop)', 'borrowed-committed-helper'),
        ):
            original = source.body(self.raw[filename], signature)
            helper = 'helper: stop.commandHelper()' if 'CommittedStop' in signature else 'helper: intent.commandHelper()'
            for before, after in ((helper, 'helper: CustodyHelperExecutable.testingCustodian()'),
                                  ('permit.observation.validationProfile.destinationAccount', 'EffectiveAccount.current()'),
                                  ('permit.observation.validationProfile.stateLocation', 'StateLocation.production()')):
                with self.subTest(signature=signature, replaced=before):
                    self.assertEqual(original.count(before), 1)
                    self.refuses(filename, original, original.replace(before, after), reason)

    def test_owner_helper_cannot_be_synthetic_or_drop_its_publisher(self):
        filename = 'SecureState.swift'
        original = source.body(self.raw[filename], 'func stagedCommandHelper(mode:')
        self.refuses(filename, original, original.replace('CustodyHelperExecutable.lifecycle(publisher)',
            'CustodyHelperExecutable.testingCustodian()'), 'owner-publisher-helper')
        filename = 'RetainedCleanupRegistry.swift'
        original = source.body(self.raw[filename], 'static func lifecycle(_ publisher:')
        self.refuses(filename, original, original.replace('publisher: value.identity', 'publisher: nil'),
                     'publisher-backed-helper')
        self.refuses(filename, original, original.replace('lifecyclePublisher: publisher', 'lifecyclePublisher: nil'),
                     'publisher-backed-helper')

    def test_actual_parent_and_child_decodes_require_original_profile(self):
        for filename, expression, reason in (
            ('CustodyResources.swift', 'InstallationCommandBinding.decode(input!, validationProfile: scope.validationProfile)',
             'parent-sealed-profile'),
            ('CustodyInheritedCommand.swift', 'InstallationCommandBinding.decode(sealedInput, validationProfile: helper.validationProfile)',
             'child-sealed-profile'),
        ):
            for suffix in (')', ', validationProfile: .production)'):
                with self.subTest(filename=filename, replacement=suffix):
                    replacement = expression.split(', validationProfile:')[0] + suffix
                    self.refuses(filename, expression, replacement, reason)
        self.refuses('InstallationCommandBinding.swift',
            'static func decode(_ bytes: Data, validationProfile: InstallationValidationProfile = .production)',
            'static func decode(_ bytes: Data, validationProfile: InstallationValidationProfile)',
            'restrictive-command-decode-default')

    def test_qualified_preparation_and_original_stop_deadlines_cannot_be_bypassed(self):
        filename = 'CommandCustodyContext.swift'
        original = source.body(self.raw[filename], 'func prepareLifecycle(')
        for before in ('_ = try LifecycleLaunchAuthority(request: resources.request, helper: helper, account: account, installation: installation?.observation)',
                       'try originalBudget.clipped(to: $0, kind: .launchctlMutation, permittedWorkSeconds: 10)'):
            with self.subTest(statement=before):
                self.assertEqual(original.count(before), 1)
                self.refuses(filename, original, original.replace(before, 'originalBudget'),
                             'qualified-lifecycle-preparation')
        filename = 'InstallationBootstrap.swift'
        original = source.body(self.raw[filename], source.ROUTES['readiness-stop'])
        self.refuses(filename, original, original.replace(
            '.borrowing(stop, intent: observed, deadline: deadline)',
            '.borrowing(stop, intent: observed, deadline: .init(seconds: 3))'), 'selected-context:readiness-stop')
        filename = 'CustodyCatalog.swift'
        original = source.body(self.raw[filename], 'func committedCandidateStop(admission')
        self.refuses(filename, original, original.replace(
            'committedStopDeadline: ready.deadline.absoluteUptimeNanoseconds',
            'committedStopDeadline: MonotonicDeadline(seconds: 3).absoluteUptimeNanoseconds'),
            'original-committed-deadline')

    def test_real_entrypoint_and_journal_helper_links_cannot_be_disconnected(self):
        self.refuses('InstallationBootstrap.swift', 'try startCandidate(kickstart: false)',
                     'return', 'bootstrap-callroot')
        filename = 'CustodyCatalog.swift'
        original = source.body(self.raw[filename], 'fileprivate func commandHelper()')
        self.refuses(filename, original, 'try CustodyHelperExecutable.testingCustodian()', 'journal-original-helper')


if __name__ == '__main__':
    unittest.main()
