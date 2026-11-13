#!/usr/bin/env python3
"""Offline structural checks for the separate signed-source preflight component.

These checks do not compile Swift, authenticate a publisher, or qualify a signed
installation route. Binary exclusion and signed/native qualification are separate.
"""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def require(value, reason):
    if not value:
        raise ValueError(reason)


def selected(source, testing, signed):
    """Select only the closed build conditions used by the checked entry files."""
    active, stack, output = True, [], []
    values = {'SHADOW_SYNC_TESTING': testing, 'SHADOW_SYNC_SIGNED_FIXTURE': signed, 'ARM64': True}
    def condition(expression):
        expression = expression.replace('arch(arm64)', 'ARM64')
        tokens = re.findall(r'[A-Za-z_0-9]+|&&|\|\||!|\(|\)', expression)
        require(''.join(tokens) == re.sub(r'\s+', '', expression), 'unknown-build-condition')
        require(all(t in values or t in ('&&', '||', '!', '(', ')') for t in tokens), 'unknown-build-condition')
        translated = ' '.join(str(values[t]) if t in values else {'&&': 'and', '||': 'or', '!': 'not'}.get(t, t) for t in tokens)
        return bool(eval(translated, {'__builtins__': {}}, {}))
    for line in source.splitlines():
        directive = line.strip()
        if directive.startswith('#if '):
            current = condition(directive[4:]); stack.append((active, current)); active = active and current
        elif directive == '#else':
            require(bool(stack), 'unmatched-else')
            parent, current = stack[-1]; stack[-1] = (parent, not current); active = parent and not current
        elif directive == '#endif':
            require(bool(stack), 'unmatched-endif'); active = stack.pop()[0]
        elif active:
            output.append(line)
    require(not stack, 'unterminated-build-condition')
    return '\n'.join(output)


def body(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1; position = opening + 1
    while depth and position < len(text):
        depth += (text[position] == '{') - (text[position] == '}'); position += 1
    require(depth == 0, 'unbalanced-function')
    return text[opening + 1:position - 1]


def compact(text):
    """Normalize the inspected closed Swift statements, not a Swift parser."""
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*', '', text))


def verify_signed_host_side_effects(raw):
    """Check the actual activation sink and retained real lifecycle source.

    These bounded structural obligations do not prove native reachability,
    broker isolation or AppKit drain timing. Native no-extra-child controls are
    mandatory even when all of these source/mutation checks pass.
    """
    delegate = selected(raw, True, True)
    initializer = body(delegate, 'init(executablePath: String, signedFixture entry:')
    for statement in ('signedFixtureLifecycle = true', 'testingHostChrome = false',
                      'logOpener = { _ in false }', 'stateLocationResolver = { entry.paths.state }'):
        require(compact(statement) in compact(initializer), 'fixture-host-initializer')
    require(re.findall(r'signedFixtureLifecycle\s*=\s*(true|false)', delegate) == ['false', 'true'],
            'fixture-host-mode-reassigned')
    activation = body(delegate, 'private func requestApplicationActivation(')
    fence = 'guard !signedFixtureLifecycle else { finishForeground(request, outcome: .denied) return }'
    require(compact(activation).startswith(compact(fence)), 'fixture-brokered-activation')
    require(activation.count('NSWorkspace.shared.openApplication(') == 1
            and activation.index('guard !signedFixtureLifecycle') < activation.index('testingActivationAcceptedOverride')
            < activation.index('NSWorkspace.shared.openApplication('), 'fixture-activation-sink')
    require(delegate.count('NSWorkspace.shared.openApplication(') == 1
            and delegate.count('NSWorkspace.shared.open(') == 1
            and 'logOpener = { NSWorkspace.shared.open($0) }' in body(delegate, 'init(executablePath: String)'),
            'fixture-extra-workspace-open')
    # Track the startup -> contention -> foreground call path that reaches the
    # guarded function. A marker in an unused helper is insufficient.
    calls = (
        ('func applicationDidFinishLaunching(', 'try installationInitialized?()'),
        ('func applicationDidFinishLaunching(', 'loadRecoveryPresentation()'),
        ('private func loadRecoveryPresentation(', 'requestOperationContention('),
        ('private func requestOperationContention(', 'applyOperationContentionEffects(effects)'),
        ('private func applyOperationContentionEffects(', 'scheduleOperationContentionRevalidation('),
        ('private func scheduleOperationContentionRevalidation(', 'performOperationContentionRevalidation('),
        ('private func performOperationContentionRevalidation(', 'operationContention.observe(observation, token: token)'),
        ('private func applyOperationContentionEffects(', 'presentOperationContention(token: token)'),
        ('private func presentOperationContention(', 'foreground(controller)'),
        ('private func foreground(_ controller: NSWindowController)', 'requestApplicationActivation(for: request)'),
        ('private func terminateAfterConfirmedQuit(', 'try installationApplicationDrained?()'),
    )
    for signature, call in calls:
        require(call in body(delegate, signature), 'fixture-real-host-call-path:' + call)
    startup = body(delegate, 'func applicationDidFinishLaunching(')
    require('if !signedFixtureLifecycle { NSApp.disableRelaunchOnLogin() }' in startup
            and 'if signedFixtureLifecycle {' in startup
            and 'shortcutAvailable = true; shortcutCollisionPresentation = .none' in startup
            and 'configureGlobalShortcut(item)' in startup, 'fixture-global-host-effects')
    for testing, signed in ((False, False), (False, True), (True, False)):
        ordinary = selected(raw, testing, signed)
        require('signedFixtureLifecycle' not in ordinary
                and 'NSWorkspace.shared.openApplication(' in body(ordinary, 'private func requestApplicationActivation('),
                'ordinary-activation-changed')


def verify(root):
    core = Path(root) / 'Sources/ShadowSyncCore'
    files = {name: (core / name).read_text() for name in (
        'SignedInstallationFixtureContext.swift', 'InstallationValidationProfile.swift',
        'LifecycleCoordinatorMain.swift', 'RuntimeSuiteGuardian.swift', 'LifecyclePublisher.swift',
        'SignedInstallationFixtureParentChannel.swift', 'CommandCustodian.swift',
        'CustodyInheritedCommand.swift', 'RetainedCleanupRegistry.swift', 'CustodyResources.swift',
        'SignedInstallationFixtureHostChannel.swift', 'SignedInstallationFixtureAdapterChannel.swift',
        'SignedInstallationFixtureService.swift', 'SignedInstallationFixtureEntrypoint.swift', 'SignedInstallationFixtureCase.swift',
        'InstalledHostStartup.swift', 'InstallationPrecommitSession.swift', 'InstallationBootstrap.swift',
        'InstallationLifecycle.swift', 'InstallationStorageFixtures.swift', 'QualifiedCommandGraph.swift')}
    app = Path(root) / 'Sources/ShadowSyncApp'
    files.update({name: (app / name).read_text() for name in ('main.swift', 'AppDelegate.swift', 'SignedInstallationFixtureApp.swift')})
    markers = json.loads((Path(root) / 'Tests/Fixtures/signed-installation-source-markers.json').read_text())
    require(markers['schema'] == 'shadow-sync-signed-installation-source-markers/v1'
            and markers['qualification'] == 'connected-startup-stop-source-only'
            and len(set(markers['markers'])) == len(markers['markers']) > 0, 'marker-contract')
    for testing, signed in ((False, False), (False, True), (True, False)):
        product = '\n'.join(selected(body, testing, signed) for body in files.values())
        require(not any(marker in product for marker in markers['markers']), 'fixture-route-in-ordinary-build')
    signed_sources = {name: selected(body, True, True) for name, body in files.items()}
    require('SignedInstallationFixtureSourceEntrypoint.dispatch(arguments)' in signed_sources['LifecycleCoordinatorMain.swift'], 'missing-reachable-dispatch')
    entry = signed_sources['SignedInstallationFixtureContext.swift']
    for call in ('requireInheritedManifest()', 'Request.consume()', 'guardian.execute',
                 'RuntimeFixtureSession.withCase', 'SignedInstallationFixtureContext.capture(',
                 'LifecyclePublisher.current(validationProfile: profile)', 'publisher.installationIdentity()',
                 'PublisherCodeVerifier.runningCode(', 'PublisherCodeVerifier.sealed(',
                 'guardian.claimSignedSourceContext(registry: registry, caseID: request.caseID)', 'profile: context.profile'):
        require(call in entry, 'missing-source-preflight-boundary:' + call)
    for forbidden in ('InstallationIdentity.testing(', 'testingConsume(', 'NoCommands(', 'normal-started',
                      'ProcessInfo.processInfo.environment', 'NSApplication', 'allowTesting'):
        require(forbidden not in entry, 'unqualified-fixture-shortcut:' + forbidden)
    require('fileprivate init(pin: RootPin' in entry and 'final class ReleaseProfile' in entry,
            'constructible-release-profile')
    control = (core / 'InstallationControlRecord.swift').read_text()
    require('profile: InstallationValidationProfile = .production' in control
            and 'init(wire: PolicyWireValue) throws { try self.init(wire: wire, profile: .production) }' in control
            and 'try profile.validateCandidate(self)' in control
            and 'Self(wire: InstallationWire.decode(data), profile: profile)' in control,
            'ordinary-control-decode-not-production')
    publisher = signed_sources['LifecyclePublisher.swift']
    require('static func current() throws -> LifecyclePublisher { try captureCurrent(validationProfile: .production) }' in publisher,
            'ordinary-publisher-not-production')
    layout = (core / 'PublisherBundleLayout.swift').read_text()
    require('validationProfile.additionalBundleResources' in layout
            and 'try validationProfile.validate(release)' in layout, 'unbound-bundle-layout')
    artifact = (core / 'ReleaseIdentity.swift').read_text()
    require('if installationProfile != nil, publisherLayout == nil' in artifact,
            'fixture-layout-can-be-omitted')
    profile_body = body(entry, 'func validate(_ release: ReleaseIdentity)')
    state_body = body(entry, 'func validateStateDescriptor(_ fd: Int32) throws {\n            // Descriptor metadata only')
    control_body = body(control, 'func validate(profile: InstallationValidationProfile = .production) throws {\n        try state.validate()')
    require('revalidate()' not in profile_body and 'sealed.' not in profile_body
            and 'guardian.' not in state_body and 'sealed.' not in state_body
            and 'profile.revalidate()' not in control_body, 'source-read-under-record-validation')
    command = (core / 'InstallationCommandBinding.swift').read_text()
    catalog = (core / 'CustodyCatalog.swift').read_text()
    require('let validationProfile: InstallationValidationProfile' in command
            and 'validationProfile: InstallationValidationProfile = .production' in command
            and 'try control.validate(profile: validationProfile)' in command
            and 'profile: validationProfile)' in command
            and 'validationProfile: owner.validationProfile)' in catalog
            and 'pending.control.encode(profile: owner.validationProfile)' in catalog
            and 'current.validateReceiptChain(chain, profile: owner.validationProfile)' in catalog,
            'lost-staged-validation-profile')
    session = signed_sources['InstallationPrecommitSession.swift']
    expected_commit = (core / 'InstallationHostCommit.swift').read_text()
    commit_delivery = (core / 'InstallationCommitDelivery.swift').read_text()
    for value, validation in ((expected_commit, 'try record.validate(profile: validationProfile)'),
                              (commit_delivery, 'committed.validate(profile: validationProfile)')):
        require('validationProfile: InstallationValidationProfile = .production' in value
                and validation in value, 'commit-construction-profile')
    ready = body(session, 'final class ReadyObservation')
    require('private let validationProfile: InstallationValidationProfile' in ready
            and 'self.validationProfile = session.validationProfile' in ready
            and 'transcriptDigest: transcriptDigest, validationProfile: validationProfile)' in ready,
            'ready-observation-profile')
    require('validationProfile = context.validationProfile' in session
            and 'self.validationProfile = journal.owner.validationProfile' in catalog
            and 'transcriptDigest: digest, validationProfile: validationProfile)' in session
            and 'committed: delivery.control, deadline: deadline, validationProfile: validationProfile)' in session,
            'commit-route-profile')
    channel = signed_sources['SignedInstallationFixtureParentChannel.swift']
    helper = signed_sources['CustodyInheritedCommand.swift']
    resources = signed_sources['CustodyResources.swift']
    for call in ('CommandCustodian.dispatchSignedInstallation(arguments)',):
        require(call in signed_sources['LifecycleCoordinatorMain.swift'], 'missing-signed-helper-dispatch')
    require('CustodianLoop(inherited: CustodyInheritedCommand.signedInstallation()).run()'
            in signed_sources['CommandCustodian.swift'], 'missing-signed-helper-loop')
    for call in ('PublisherCodeVerifier.livePeer(', 'PublisherCodeVerifier.runningCode(',
                 'InstallationPrecommitTransport.requireQuiet(socket)', 'getppid() == peer.pid'):
        require(call in channel, 'missing-parent-channel-boundary:' + call)
    require('suspendedChild' not in channel and 'ProcessInfo.processInfo.environment' not in channel,
            'parent-channel-pid-or-environment-authority')
    require('SignedInstallationFixtureParentChannel.Inherited.consume()' in helper
            and 'SignedInstallationFixtureContext.captureInherited(parent)' in helper
            and 'CustodyRecordBinding.digest(raw) == parent.requestDigest' in helper
            and 'originalDescriptors: original.subtracting([211,212])' in helper
            and 'validationProfile: helper.validationProfile' in helper, 'unbound-inherited-context')
    require('signedParentChannel?.retiredSuccessfully' in resources
            and 'signedParentChannel?.retire()' in resources
            and 'pipeSources + childOwnedSources { source.closeNow() }' in resources
            and 'profile.makeParentChannel(requestDigest: sealedRequest.sha256)' in resources,
            'unowned-parent-channel')
    require(resources.index('posix_spawn_file_actions_addfchdir') < resources.index('for (target, source) in childOwnedSources'),
            'bootstrap-mapping-clobbers-original-source')
    route = signed_sources['SignedInstallationFixtureEntrypoint.swift']
    sequence = ('InstallationBootstrap.signedFixture(', 'bootstrap.reserve(', 'bootstrap.prepareExclusive()',
        'bootstrap.transferToStagedAdmission()', 'bootstrap.continueStagedJournal()', 'bootstrap.openStagedReadiness()',
        'bootstrap.bootstrapCandidate()', 'bootstrap.kickstartCandidate()', 'bootstrap.confirmCandidateReady()',
        'bootstrap.commitCandidateReadiness()', 'scenario.run(')
    positions = [route.index(call) for call in sequence]
    require(positions == sorted(positions), 'disconnected-installation-order')
    scenarios = signed_sources['SignedInstallationFixtureCase.swift']
    for actual in ('InstallationStartupFixtures.authenticatedStartupAndStop(',
                   'InstallationStartupFixtures.authenticatedStopRetirementCut(',
                   'InstallationCoordinationCleanupFixtures.authenticatedPositive(',
                   'InstallationTerminalFixtures.authenticatedPositive('):
        require(actual in scenarios, 'missing-connected-case:' + actual)
    registration = json.loads((Path(root) / 'config/signed-installation-fixtures.json').read_text())
    ids = re.findall(r'case [A-Za-z0-9]+ = "(signed-installation/[^"\n]+)"', scenarios)
    require(ids == [row['id'] for row in registration['cases'][1:]]
            and len(ids) == len(set(ids)) and registration['unavailable_requirements'], 'case-discovery-mismatch')
    require('SignedInstallationFixtureEntrypoint.dispatch(arguments)' in signed_sources['LifecycleCoordinatorMain.swift'], 'missing-positive-callroot')
    bootstrap = signed_sources['InstallationBootstrap.swift']
    for call in ('parents = try .signedFixture(signedContext)', 'initializer = try .signedFixture(signedContext)',
                 'InstallationTransactionOwner.consumeSignedFixture(', 'launchAgent: signedService, host: signedService'):
        require(call in bootstrap, 'disconnected-real-owner:' + call)
    service = signed_sources['SignedInstallationFixtureService.swift']
    for call in ('RuntimeFixtureSpawn.spawn(', 'anchor = spawned', 'PublisherCodeVerifier.suspendedChild(spawned.processID',
                 'spawned.transfer(', 'child = owned', 'owned.resume(before: context.deadline)',
                 'child.identity.isCurrent(', 'streams.drained()', 'anchor.testingRuntimeRetired'):
        require(call in service, 'unowned-service-host:' + call)
    require('fixtureLoadedOutput' not in service and 'adoptingSpawnedChild' not in service, 'synthetic-service-owner')
    adapter = signed_sources['SignedInstallationFixtureAdapterChannel.swift']
    for call in ('service.enroll(self)', 'service.work', 'service.perform(operation, binding: binding)',
                 'PublisherCodeVerifier.livePeer(', 'request.budget.work'):
        require(call in adapter or call in entry, 'disconnected-adapter:' + call)
    require('spawn(' not in adapter and 'ProcessInfo.processInfo.environment' not in adapter, 'unclosed-adapter-graph')
    require('inherited.signedAdapter?.appendTargetMapping(&actions)' in signed_sources['CommandCustodian.swift']
        and 'signedAdapterChannel?.joinAndRetire' in resources, 'adapter-custody-not-connected')
    app_driver = signed_sources['SignedInstallationFixtureApp.swift']
    require(app_driver.index('InstalledHostStartup.enterSignedFixture(') < app_driver.index('NSApplication.shared')
        < app_driver.index('ShadowSyncAppDelegate(') < app_driver.index('application.run()'), 'appkit-before-commit')
    for call in ('entry.startup.didInitialize(', 'entry.startup.applicationDrained(', 'delegate.requestLifecycleExit()'):
        require(call in app_driver, 'missing-real-app-lifecycle:' + call)
    require('applicationDidFinishLaunching(' not in app_driver and 'testingHostChrome = false' in signed_sources['AppDelegate.swift'],
        'manual-appkit-startup')
    delegate = signed_sources['AppDelegate.swift']
    verify_signed_host_side_effects(files['AppDelegate.swift'])
    login_item = body(delegate, 'private func configureOpenAtLoginItem(')
    login_action = body(delegate, '@objc private func toggleOpenAtLogin(')
    require(login_item.index('if signedFixtureLifecycle') < login_item.index('SMAppService.mainApp.status')
            and 'item.isEnabled = false' in login_item and 'return' in login_item
            and login_action.index('guard !signedFixtureLifecycle else { return }') < login_action.index('SMAppService.mainApp.status'),
            'fixture-login-side-effects')
    host = signed_sources['InstallationPrecommitSession.swift']
    require('retained.hostParent === parent' in host and 'try parent.validate(control)' in host
        and 'try validationProfile.inspectBundle(paths.app)' in host, 'unbound-host-context')
    require('return try open(lifecycle: lifecycle, opening: opening, paths: paths,' in host,
        'signed-host-skips-original-opener')
    startup = signed_sources['InstalledHostStartup.swift']
    committed_entry = body(startup, 'public static func enterSignedFixture(')
    require(committed_entry.index('let admission = try precommit.run()')
            < committed_entry.index('let retained = try admission.take()')
            < committed_entry.index('fixture.loadCommittedHostPolicy()')
            < committed_entry.index('startup.signedFixturePolicy = policy'), 'policy-before-consumed-commit')
    require('HostPolicySnapshot.load(account: isolated, contract: policyContract)' in entry
            and 'PublisherCodeVerifier.sealed(policyContractFile, relativePath: "Resources/awa-contract.json", code: code)' in entry
            and 'try policyContractFile.revalidate()' in entry
            and 'try signedFixturePolicy?.revalidate()' in body(startup, 'public func validateBeforeApplication()'),
            'unbound-isolated-policy')
    require('creator-after-coordinator-reap' in entry and 'retainingExternalRoot: pin' in entry
        and 'try retainedRoot.revalidate()' in signed_sources['InstallationStorageFixtures.swift'], 'unowned-root-disposal')
    # Reservation mechanisms are checked at the actual mutation entry points;
    # these are source obligations, not proof of concurrent native execution.
    for filename in ('InstallationParentPreparation.swift', 'FreshStateInitialization.swift'):
        value = (core / filename).read_text()
        turn = body(value, 'private func serialized<')
        require('mutex.unlock()' in turn and turn.index('mutex.unlock()') < turn.index('try action(')
            and 'metadataGeneration' in turn, 'verifier-under-owner-lock:' + filename)
    recovery = body(catalog, 'private func validateStartupRecovery(')
    require(recovery.index('mutex.unlock()') < recovery.index('try owner.validateReadinessOwner()')
        and 'metadataGeneration == generation' in recovery, 'startup-recovery-lock-interval')
    return ['ordinary-build-exclusion', 'reachable-source-preflight', 'production-decode-default', 'full-publisher-layout',
            'pure-record-profile-validation', 'retained-staged-profile', 'retained-commit-profile', 'authenticated-helper-channel', 'connected-startup-stop-route', 'owned-service-handoff', 'real-appkit-entry', 'signed-host-side-effect-fences', 'committed-isolated-policy', 'external-root-disposal', 'owner-lock-reservations']


if __name__ == '__main__':
    for name in verify(ROOT):
        print('PASS signed-fixture-source/' + name)
    print('Structural source checks only; installation execution and native qualification remain unavailable.')
