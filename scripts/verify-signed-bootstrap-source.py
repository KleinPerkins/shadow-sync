#!/usr/bin/env python3
"""Bounded offline checks of the selected Bootstrap command paths.

This follows the dual-flag source path, not Swift type checking or execution.
Signed/native qualification and process retirement remain separate gates.
"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'signed_bootstrap_selection', ROOT / 'scripts/verify-signed-fixture-source.py')
selection = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(selection)
body, compact, require, selected = selection.body, selection.compact, selection.require, selection.selected

FILES = ('InstallationBootstrap.swift', 'CommandCustodyContext.swift', 'CustodyCatalog.swift',
         'SecureState.swift', 'RetainedCleanupRegistry.swift', 'CustodyResources.swift',
         'CustodyInheritedCommand.swift', 'InstallationCommandBinding.swift',
         'LifecycleLaunchCommand.swift', 'SignedInstallationFixtureEntrypoint.swift')
ROUTES = {
    'start': 'private func startCandidate(kickstart: Bool)',
    'ready': 'func confirmCandidateReady()',
    'readiness-stop': 'func stopReadinessOnlyHost()',
    'committed-stop': 'func stopNormallyStartedHost()',
}


def read_sources(root):
    return {name: (Path(root) / 'Sources/ShadowSyncCore' / name).read_text() for name in FILES}


def exact(actual, expected, reason):
    require(compact(actual) == compact(expected), reason)


def contains(actual, statements, reason):
    require(all(compact(statement) in compact(actual) for statement in statements), reason)


def verify_sources(raw):
    # Match the selected closure, not a symbol in an inactive branch or comment.
    for testing, signed in ((False, False), (False, True), (True, False), (True, True)):
        bootstrap = selected(raw['InstallationBootstrap.swift'], testing, signed)
        unsigned = testing and not signed
        for name, signature in ROUTES.items():
            route = body(bootstrap, signature)
            context = body(route, 'try execution.makeContext')
            if name in ('start', 'ready'):
                expected = ('guard let fixtureRoot else { throw CustodyRecordError.fenced } '
                            'return try .testingStaged(admission, intent: intent, root: fixtureRoot, deadline: deadline)'
                            if unsigned else 'return try .borrowing(admission, intent: intent, deadline: deadline)')
            elif name == 'readiness-stop':
                expected = ('guard let fixtureRoot else { throw CustodyRecordError.fenced } '
                            'return try .testingStaged(stop, intent: observed, root: fixtureRoot)'
                            if unsigned else 'return try .borrowing(stop, intent: observed, deadline: deadline)')
            else:
                expected = ('guard let fixtureRoot else { throw CustodyRecordError.fenced } '
                            'return try .testingCommittedStop(capability, root: fixtureRoot)'
                            if unsigned else 'return try .borrowing(capability)')
            exact(context, expected, 'selected-context:' + name)
            command = body(route, 'try execution.makeCommand')
            if name == 'ready':
                expected = ('context in let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 10) '
                            '.clipped(to: deadline, kind: .launchctlRead, permittedWorkSeconds: 10) '
                            'return try context.prepare(.serviceStatus, budget: budget)')
            elif unsigned and name == 'committed-stop':
                expected = 'context in return try context.testingCommittedBootout()'
            else:
                operation = 'operation' if name == 'start' else '.bootout'
                expected = ('context in let budget = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10) '
                            '.clipped(to: deadline, kind: .launchctlMutation, permittedWorkSeconds: 10) '
                            'return try context.testingStagedLifecycle(' + operation + ', budget: budget)'
                            if unsigned else 'context in return try context.prepareLifecycle(' + operation + ', deadline: deadline)')
            exact(command, expected, 'selected-command:' + name)
            steps = ('try execution.makeContext', 'try execution.makeCommand',
                     'try execution.submit(to: registry)', '_ = handle.wait()',
                     'execution.closeContext()', 'execution.releaseCommandAliases()')
            positions = [route.index(step) for step in steps]
            require(positions == sorted(positions), 'selected-submission:' + name)

    signed = {name: selected(text, True, True) for name, text in raw.items()}
    bootstrap, context = signed['InstallationBootstrap.swift'], signed['CommandCustodyContext.swift']
    exact(body(bootstrap, 'func bootstrapCandidate()'), 'try startCandidate(kickstart: false)', 'bootstrap-callroot')
    exact(body(bootstrap, 'func kickstartCandidate()'), 'try startCandidate(kickstart: true)', 'kickstart-callroot')
    route = signed['SignedInstallationFixtureEntrypoint.swift']
    calls = ('InstallationBootstrap.signedFixture(', 'bootstrap.reserve(', 'bootstrap.prepareExclusive()',
             'bootstrap.transferToStagedAdmission()', 'bootstrap.continueStagedJournal()',
             'bootstrap.openStagedReadiness()', 'bootstrap.bootstrapCandidate()', 'bootstrap.kickstartCandidate()',
             'bootstrap.confirmCandidateReady()', 'bootstrap.commitCandidateReadiness()', 'scenario.run(')
    positions = [route.index(call) for call in calls]
    require(positions == sorted(positions), 'signed-entry-command-order')

    for typ, leases in (('InstallationStagedAdmission', 'retainStartLeases'),
                        ('InstallationStagedStopAdmission', 'retainStopLeases')):
        value = body(context, 'static func borrowing(_ admission: ' + typ + ',')
        exact(value, 'let permit = try intent.commandPermit(admission: admission, deadline: deadline) '
              'return try Self(leases: admission.' + leases + '(), helper: intent.commandHelper(), '
              'account: permit.observation.validationProfile.destinationAccount, '
              'location: permit.observation.validationProfile.stateLocation, installation: permit)',
              'borrowed-staged-helper:' + typ)
    exact(body(context, 'static func borrowing(_ stop: CustodyCatalogStore.InstallationCommittedStop)'),
          'let permit = try stop.commandPermit() '
          'return try Self(leases: stop.retainLeases(), helper: stop.commandHelper(), '
          'account: permit.observation.validationProfile.destinationAccount, '
          'location: permit.observation.validationProfile.stateLocation, installation: permit)',
          'borrowed-committed-helper')
    catalog, owner = signed['CustodyCatalog.swift'], signed['SecureState.swift']
    exact(body(catalog, 'fileprivate func commandHelper()'),
          'try owner.stagedCommandHelper(mode: stop == nil ? .installationStagedStart : .installationStagedStop)',
          'journal-original-helper')
    observation = body(catalog, 'final class InstallationStagedCommandObservation')
    exact(body(observation, 'func commandHelper()'), 'try session.commandHelper()', 'observation-original-helper')
    capability = body(catalog, 'final class InstallationCommittedStop {')
    exact(body(capability, 'func commandHelper()'), 'try observation.commandHelper()', 'committed-original-helper')
    exact(body(capability, 'func commandPermit()'), 'try observation.session.committedStopPermit(self)',
          'committed-original-permit')
    exact(body(owner, 'func stagedCommandHelper(mode:'),
          'guard mode.isInstallationStaged else { throw CustodyRecordError.fenced } '
          'try validateStagedBorrowing(mode: mode) '
          'guard let publisher else { throw CustodyRecordError.fenced } '
          'return try CustodyHelperExecutable.lifecycle(publisher)', 'owner-publisher-helper')
    contains(body(owner, 'static func consumeSignedFixture('),
             ('try context.revalidate()', 'publisher: context.publisher, fixtureRoot: nil'), 'signed-original-owner')
    helper = signed['RetainedCleanupRegistry.swift']
    contains(body(helper, 'static func lifecycle(_ publisher:'),
             ('let value = try publisher.custodianBootstrap()', 'release: publisher.releaseSHA256',
              'publisher: value.identity', 'lifecyclePublisher: publisher', 'try result.revalidate()'),
             'publisher-backed-helper')
    exact(body(helper, 'var validationProfile:'), 'lifecyclePublisher?.validationProfile ?? .production',
          'retained-helper-profile')
    contains(body(helper, 'var arguments:'),
             ('if case .signedFixture = validationProfile { return [path, "--shadow-sync-signed-installation-custodian"] }',),
             'signed-helper-entry')

    preparation = body(context, 'func prepareLifecycle(')
    contains(preparation, ('guard helper.isLifecycleCoordinator', 'try installation.observation.validateStagedOperation(',
                          'originalBudget.clipped(to: $0', 'installation?.boundCommittedBudget(invocationBudget',
                          '_ = try LifecycleLaunchAuthority(request: resources.request, helper: helper, account: account, installation: installation?.observation)',
                          'input: try installation?.sealedInput()'), 'qualified-lifecycle-preparation')
    authority = body(signed['LifecycleLaunchCommand.swift'], 'final class LifecycleLaunchAuthority')
    contains(authority, ('try installation.validateCommittedRequest(request)',
                         'QualifiedCommandGraph.forHelper(kind: .launchctlRead, helper: helper)',
                         'QualifiedCommandGraph.forHelper(kind: .launchctlMutation, helper: helper)',
                         'try helper.validationProfile.validate(release)'), 'qualified-helper-graphs')
    candidate = body(signed['LifecycleLaunchCommand.swift'], 'final class InstallationStagedCandidateAuthority')
    contains(candidate, ('transaction.sourceReleaseDigest == helper.releaseSHA256',
                         'candidate.release.releaseContractSHA256 == helper.releaseSHA256',
                         'try helper.validateInstallationPublisher(transaction)',
                         'try helper.validationProfile.inspectBundle(command.app)'), 'exact-candidate-publisher')

    # The selected committed route never calls testingCommittedStop's ordinary
    # fixture decoder. Its actual parent/child wire decodes retain the profile.
    for filename, expression, reason in (
        ('CustodyResources.swift', 'InstallationCommandBinding.decode(input!, validationProfile: scope.validationProfile)',
         'parent-sealed-profile'),
        ('CustodyInheritedCommand.swift', 'InstallationCommandBinding.decode(sealedInput, validationProfile: helper.validationProfile)',
         'child-sealed-profile')):
        calls = [line.strip() for line in signed[filename].splitlines()
                 if 'InstallationCommandBinding.decode(' in line and not line.strip().startswith('//')]
        require(len(calls) == 1 and compact(expression) in compact(calls[0]), reason)
    binding = signed['InstallationCommandBinding.swift']
    require('static func decode(_ bytes: Data, validationProfile: InstallationValidationProfile = .production)' in binding,
            'restrictive-command-decode-default')
    contains(body(binding, 'static func decode('),
             ('profile: validationProfile)', 'validationProfile: validationProfile)'), 'command-decode-profile')
    contains(body(catalog, 'func committedCandidateStop(admission'),
             ('deadline: ready.deadline', 'committedStopDeadline: ready.deadline.absoluteUptimeNanoseconds'),
             'original-committed-deadline')
    contains(body(catalog, 'fileprivate func committedStopPermit('),
             ('try withCommittedStop(capability)', 'try validateLocked(store, capability.deadline)',
              'return InstallationCommandPermit(staged: capability.observation)'), 'original-committed-permit')
    return ['four-build-selected-factories', 'reachable-bootstrap-commands', 'original-owner-helper-chain',
            'qualified-command-preparation', 'retained-sealed-decodes', 'original-stop-deadlines']


def verify(root):
    return verify_sources(read_sources(root))


if __name__ == '__main__':
    for name in verify(ROOT):
        print('PASS signed-bootstrap-source/' + name)
    print('Source selection only; compilation and signed/native execution remain unqualified.')
