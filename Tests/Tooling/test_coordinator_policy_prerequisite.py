"""Source obligations for the real coordinator prerequisite; no native proof."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('coordinator_policy_source', ROOT / 'scripts/verify-signed-fixture-source.py')
source = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source)


def verify(publisher, resources):
    production = source.selected(publisher, False, False)
    capsule = source.body(production, 'struct PolicyResourcesSource')
    source.require('private init(publisher: LifecyclePublisher, installation: InstallationIdentity)' in capsule,
                   'closed-capsule')
    capture = source.body(capsule, 'fileprivate static func capture(')
    source.require('publisher.installationIdentity()' in capture and 'try source.revalidate()' in capture,
                   'source-bound-capture')
    current = source.body(capsule, 'func revalidate()')
    for required in ('publisher.validationProfile == .production', 'account == publisher.account',
                     'account == (try EffectiveAccount.current())', 'getuid() == account.uid',
                     'try installation.revalidate()', 'try publisher.revalidate()'):
        source.require(required in current, 'account-source-binding')
    match = source.body(capsule, 'func requireInstallation(')
    source.require('guard expected == installation else' in match and 'try revalidate()' in match,
                   'exact-installation')
    source.require('try CoordinatorPolicyPrerequisite.capture(PolicyResourcesSource.capture(self))'
                   in source.body(production, 'func policyPrerequisite()'), 'publisher-entrypoint')
    prerequisite = source.body(production, 'final class CoordinatorPolicyPrerequisite')
    load = source.body(prerequisite, 'fileprivate static func capture(')
    before, after = load.split('let policy = try RetainedPolicy(account: source.account, contract: contract)')
    source.require('PublisherPolicyResources.coordinator(source: source)' in before
                   and 'QualifiedAWAContract.decode(resources.contract)' in before
                   and 'try resources.revalidate(); try source.revalidate()' in before
                   and 'try resources.revalidate(); try source.revalidate()' in after
                   and 'try result.revalidate(for: source.installation)' in after, 'handoff-order')
    revalidate = source.body(prerequisite, 'func revalidate(for installation:')
    source.require(revalidate.count('try source.requireInstallation(installation)') == 2
                   and revalidate.count('try resources.revalidate()') == 2
                   and 'try policy.revalidate()' in revalidate and 'policy.account == source.account' in revalidate
                   and 'try revalidation.revalidate {' in revalidate,
                   'retained-handoff-revalidation')
    source.require('private let revalidation = RevalidationState()' in prerequisite,
                   'retained-revalidation-state')
    state = source.body(prerequisite, 'final class RevalidationState')
    source.require('private let mutex = NSLock()' in state
                   and 'private var inFlight = false' in state
                   and 'private var refused = false' in state, 'private-state-lock')
    validation = source.body(state, 'func revalidate(_ validation:')
    source.require('try claim()' in validation and 'try validation()' in validation
                   and 'try commit()' in validation and 'refuse()' in validation
                   and 'throw PublisherPolicyError.unavailable' in validation,
                   'state-claim-validation-commit')
    source.require(validation.index('try claim()') < validation.index('try validation()')
                   < validation.index('try commit()') < validation.index('refuse()')
                   and 'mutex.lock()' not in validation, 'validation-outside-lock')
    for signature, required in (
            ('private func claim()', ('guard !refused && !inFlight else', 'refused = true', 'inFlight = true')),
            ('private func commit()', ('guard !refused && inFlight else', 'inFlight = false')),
            ('private func refuse()', ('refused = true', 'inFlight = false'))):
        body = source.body(state, signature)
        source.require('mutex.lock(); defer { mutex.unlock() }' in body
                       and all(value in body for value in required), 'linearized-refusal-and-commit')
        source.require(all(value not in body for value in ('try validation()', 'try source.',
                       'try resources.', 'try policy.', 'PublisherCodeVerifier.', 'HostPolicySnapshot.')),
                       'no-authority-work-under-state-lock')
    first_source = revalidate.index('try source.requireInstallation(installation)')
    first_resource = revalidate.index('try resources.revalidate()')
    policy_check = revalidate.index('try policy.revalidate()')
    last_resource = revalidate.rindex('try resources.revalidate()')
    last_source = revalidate.rindex('try source.requireInstallation(installation)')
    source.require(first_source < first_resource < policy_check < last_resource < last_source, 'revalidation-order')
    binding = source.body(prerequisite, 'struct RetainedPolicy')
    source.require('HostPolicySnapshot.load(account: account, contract: contract)' in binding
                   and 'identity = try snapshot.identityCommitment()' in binding
                   and 'try snapshot.identityCommitment() == identity' in binding, 'retained-policy-identity')
    resource = source.selected(resources, False, False)
    factory = source.body(resource, 'static func coordinator(')
    source.require('let location = try source.resourceLocation()' in factory
                   and 'let app = location.app' in factory and 'let owner = location.owner' in factory
                   and 'guard publisher == location.publisher else' in factory
                   and 'release == source.installation.candidate.release' in factory, 'exact-resource-source')
    for required in ('Resources/awa-contract.json', 'Resources/PolicyAdapter.py', 'Resources/policy-runtime-source.json',
                     'Resources/release-contract.json', '_CodeSignature/CodeResources',
                     'PolicyRuntimeLayout.decode', 'PolicyRuntimeTree.capture', 'PublisherCodeVerifier.sealed(file, relativePath: path, code: appCode)',
                     'PublisherCodeVerifier.sealed(manifest, relativePath:',
                     '(adapter, "Resources/PolicyAdapter.py")', '(contract, "Resources/awa-contract.json")',
                     '(runtimeSource, "Resources/policy-runtime-source.json")',
                     '(releaseContract, "Resources/release-contract.json")',
                     'PublisherCodeVerifier.verifiedStatic', 'for file in before.machOFiles',
                     'guard let interpreterIdentity', 'QualifiedAWAContract.decode(contract.bytes)',
                     'result.coordinatorSource = source', 'try result.revalidate(); try source.revalidate()'):
        source.require(required in factory, 'sealed-resource-roster')
    revalidate = source.body(resource[resource.index('final class PublisherPolicyResources'):], 'func revalidate()')
    source.require(revalidate.count('try coordinatorSource?.revalidate()') == 2, 'resource-retains-source')
    for testing, signed in ((True, False), (True, True)):
        test_publisher = source.selected(publisher, testing, signed)
        test_resources = source.selected(resources, testing, signed)
        for region, signature in ((source.body(test_publisher, 'struct PolicyResourcesSource'), 'fileprivate static func capture('),
                                  (source.body(test_publisher, 'struct PolicyResourcesSource'), 'func revalidate()'),
                                  (source.body(test_publisher, 'final class CoordinatorPolicyPrerequisite'), 'fileprivate static func capture('),
                                  (test_resources, 'static func coordinator(')):
            source.require(source.compact(source.body(region, signature)) == 'throwPublisherPolicyError.unavailable',
                           'testing-production-refusal')


class CoordinatorPolicyPrerequisiteTests(unittest.TestCase):
    def setUp(self):
        self.publisher = (ROOT / 'Sources/ShadowSyncCore/LifecyclePublisher.swift').read_text()
        self.resources = (ROOT / 'Sources/ShadowSyncCore/PublisherPolicyResources.swift').read_text()

    def test_closed_production_handoff_and_test_build_exclusion(self):
        verify(self.publisher, self.resources)

    def test_wrong_publisher_candidate_or_account_cannot_weaken_binding(self):
        for old, new in [('guard expected == installation else', 'guard true else'),
                         ('account == (try EffectiveAccount.current())', 'true'),
                         ('getuid() == account.uid', 'true'),
                         ('try installation.revalidate()', '')]:
            with self.subTest(binding=old), self.assertRaises(ValueError):
                verify(self.publisher.replace(old, new), self.resources)
        for old, new in [('guard publisher == location.publisher else', 'guard true else'),
                         ('release == source.installation.candidate.release', 'true'),
                         ('let app = location.app', 'let app = "/fixture/other.app"')]:
            with self.subTest(binding=old), self.assertRaises(ValueError):
                verify(self.publisher, self.resources.replace(old, new))

    def test_resource_omission_and_substitution_checks_are_required(self):
        for old in ['result.coordinatorSource = source', 'for file in before.machOFiles',
                    'try coordinatorSource?.revalidate()', 'QualifiedAWAContract.decode(contract.bytes)',
                    'Resources/awa-contract.json', 'Resources/policy-runtime-source.json',
                    'PublisherCodeVerifier.sealed(manifest, relativePath:',
                    '(contract, "Resources/awa-contract.json")']:
            with self.subTest(resource=old), self.assertRaises(ValueError):
                verify(self.publisher, self.resources.replace(old, 'omitted'))

    def test_each_side_of_handoff_and_sticky_revocation_are_required(self):
        for old in ['try CoordinatorPolicyPrerequisite.capture(PolicyResourcesSource.capture(self))',
                    'try resources.revalidate(); try source.revalidate()',
                    'try source.requireInstallation(installation)', 'try policy.revalidate()',
                    'try snapshot.identityCommitment() == identity', 'refused = true',
                    'guard !refused && !inFlight else', 'guard !refused && inFlight else',
                    'try revalidation.revalidate {', 'try commit()', 'refuse()']:
            with self.subTest(boundary=old), self.assertRaises(ValueError):
                verify(self.publisher.replace(old, 'omitted'), self.resources)

    def test_state_lock_and_out_of_lock_commit_obligations(self):
        for old in ('private let mutex = NSLock()', 'mutex.lock(); defer { mutex.unlock() }',
                    'private let revalidation = RevalidationState()', 'try claim()', 'inFlight = true'):
            with self.subTest(state=old), self.assertRaises(ValueError):
                verify(self.publisher.replace(old, 'omitted'), self.resources)
        held = self.publisher.replace('try validation()', 'mutex.lock(); try validation()', 1)
        with self.assertRaises(ValueError): verify(held, self.resources)

    def test_actual_state_fixtures_include_overlap_and_restored_input(self):
        fixtures = (ROOT / 'Sources/ShadowSyncCore/HostPolicySnapshotSelfTests.swift').read_text()
        overlap = source.body(fixtures, 'try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T18-')
        self.assertIn('let state = CoordinatorPolicyPrerequisite.RevalidationState()', overlap)
        self.assertEqual(overlap.count('try state.revalidate'), 4)
        self.assertIn('"outer-validation-finished"', overlap)
        self.assertIn('&& effects == 1', overlap)
        restored = source.body(fixtures, 'try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T19-')
        self.assertIn('let state = CoordinatorPolicyPrerequisite.RevalidationState()', restored)
        self.assertIn('try fixture.restore()', restored)
        self.assertIn('try restored.revalidate()', restored)
        self.assertIn('validations == 2 && effects == 1', restored)
        self.assertNotIn('CoordinatorPolicyPrerequisite.capture', overlap + restored)

    def test_policy_load_cannot_precede_publisher_resource_validation(self):
        before = 'let resources = try PublisherPolicyResources.coordinator(source: source)'
        policy = 'let policy = try RetainedPolicy(account: source.account, contract: contract)'
        # Explicitly move the existing statement rather than add a marker.
        changed = self.publisher.replace('        ' + policy + '\n', '')
        changed = changed.replace(before, policy + '\n        ' + before)
        with self.assertRaises(ValueError): verify(changed, self.resources)

    def test_canonical_app_path_and_readonly_cli_stay_separate(self):
        body = source.body(self.resources, 'static func production(account:')
        self.assertIn('let app = account.homeDirectory + "/Applications/ShadowSync.app"', body)
        self.assertLess(body.index('Bundle.main.bundleURL.path.utf8.elementsEqual(app.utf8)'),
                        body.index('let info = try resource('))
        self.assertIn('PublisherCodeVerifier.runningApplication(path: app)', body)
        main = (ROOT / 'Sources/ShadowSyncCore/LifecycleCoordinatorMain.swift').read_text()
        self.assertNotIn('policyPrerequisite', main)
        self.assertNotIn('HostPolicySnapshot', main)

    def test_non_authoritative_configuration_helper_cannot_create_prerequisite(self):
        helper = source.body(self.publisher, 'struct RetainedPolicy')
        self.assertNotIn('CoordinatorPolicyPrerequisite(', helper)
        self.assertNotIn('PolicyResourcesSource(', helper)
        self.assertNotIn('InstallationIdentity(', helper)
        self.assertIn('private init(source: LifecyclePublisher.PolicyResourcesSource,', self.publisher)
        self.assertNotIn('testing(', source.body(self.publisher, 'final class CoordinatorPolicyPrerequisite'))


if __name__ == '__main__':
    unittest.main()
