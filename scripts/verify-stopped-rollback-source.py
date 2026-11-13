#!/usr/bin/env python3
"""Offline integration obligations; these do not authenticate or execute Swift."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('rollback_selection', ROOT / 'scripts/verify-signed-fixture-source.py')
selection = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(selection)
body, compact, require, selected = selection.body, selection.compact, selection.require, selection.selected
FILES = ('CustodyCatalog.swift', 'InstallationLifecycle.swift', 'InstallationBootstrapFixtures.swift',
         'SignedInstallationFixtureCase.swift')


def read_sources(root):
    return {name: (Path(root) / 'Sources/ShadowSyncCore' / name).read_text() for name in FILES}


def contains(value, statements, reason):
    require(all(compact(statement) in compact(value) for statement in statements), reason)


def verify_sources(raw):
    catalog = raw['CustodyCatalog.swift']
    restoration = body(catalog, 'func restoreStoppedFreshInstallation(')
    contains(restoration, (
        'CustodyCatalogStore(stoppedRoot: intent.root, binding: current.state, directory: directory, '
        'guardFile: guardFile, receipts: receipts, validationProfile: owner.validationProfile)',
        'try current.validateReplacement(proposed.control, receipts: chain + [proposed.receipt.receipt], profile: owner.validationProfile)',
        'try current.validateReplacement(committed, receipts: chain, profile: owner.validationProfile)'), 'restoration-retained-profile')
    snapshots = body(catalog, 'private func validateStoppedPins(')
    contains(snapshots, ('InstallationControlRecord.decode(pins.controlPin.bytes, profile: owner.validationProfile)',
                        'pins.control.validateReceiptChain(pins.chain, profile: owner.validationProfile)'), 'restoration-pin-profile')
    gate = body(catalog, 'private func validateFreshRestorationMutation(')
    # The metadata reservation must survive the borrowed store guard, then be
    # released for actual registry/source callbacks and restored at postflight.
    sequence = ('let pins = stoppedPins()', 'mutex.unlock()',
                'try store.locked { try validateLocked(store, permit.deadline) }',
                'serializing = false', 'try validateStoppedPins(pins, deadline: permit.deadline)',
                'try permit.validateOwner()',
                'try repair.drain.retirement.revalidate(for: owner, registry: repair.drain.registry)',
                'try slots.revalidateFreshRestoration(permit, for: owner, deadline: permit.deadline)',
                'serializing = true')
    cursor = 0
    for statement in sequence:
        index = gate.find(statement, cursor)
        require(index >= 0, 'restoration-live-gate-order')
        cursor = index + len(statement)
    postflight = gate[gate.rindex('guard mutex.try()'):]
    contains(postflight, ('metadataGeneration == pins.generation', 'current == pins.control',
                         'controlPin.descriptor === pins.controlPin.node.descriptor',
                         'anchor.bytes == pins.controlPin.bytes', 'chain == pins.chain',
                         'catalogPin.bytes == pins.catalog.bytes',
                         'Set(receiptPins.keys) == Set(pins.receipts.keys)'), 'restoration-exact-postflight')
    require('try ' not in postflight, 'restoration-verifier-under-mutex')
    lifecycle = raw['InstallationLifecycle.swift']
    for testing, signed in ((False, False), (False, True), (True, False), (True, True)):
        selected_lifecycle = selected(lifecycle, testing, signed)
        restore = body(selected_lifecycle, 'func completeFreshRestoration(')
        if testing:
            contains(restore, ('try InstallationPaths.isolated(root: fixtureRoot) == observer.paths',
                               'RuntimeFixtureSession.installationRoot(fixtureRoot).retainNamedSocket(retirement)'),
                     'restoration-owned-guardian')
            if signed:
                contains(restore, ('if case let .signedFixture(profile) = observer.validationProfile',
                                   'fixtureRoot = try profile.location.anchorPath',
                                   'else { fixtureRoot = observer.testingExclusiveRoot }'), 'restoration-signed-root')
            else:
                require('fixtureRoot = observer.testingExclusiveRoot' in restore and '.signedFixture' not in restore,
                        'restoration-ordinary-root')
        else:
            require('RuntimeFixtureSession' not in restore, 'restoration-production-guardian')
    contains(body(lifecycle, 'private func restoreFreshPlist('),
             ('try permit.validateMutation(owner: owner, action: .restorePlist)',), 'restoration-plist-live-gate')
    tree = body(lifecycle, 'private final class InstallationCandidateRetirement')
    contains(tree, ('try permit.validateMutation(owner: owner, action: .restoreApplication)',), 'restoration-tree-live-gate')
    fixtures = raw['InstallationBootstrapFixtures.swift']
    snapshot = body(fixtures, 'private static func stored(_ location: StateLocation, bootstrap: B)')
    require(compact(snapshot) == compact('''
        guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
        let profile = journal.testingValidationProfile
        try profile.validateLocation(location)
        return try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath:
            location.path + "/custody/installation.json")), profile: profile)
    '''), 'restoration-fixture-retained-profile')
    ordinary = body(fixtures, 'private static func stored(_ location: StateLocation)')
    require('profile:' not in ordinary, 'restoration-ordinary-strict-decoder')
    helpers = fixtures[fixtures.index('static func authenticatedFreshStoppedRestoration('):
                       fixtures.index('/// Missing original stages must not be counted')]
    require('stored(location)' not in helpers and helpers.count('stored(location, bootstrap: bootstrap)') == 16,
            'restoration-fixture-snapshot-profile')
    contains(helpers, ('let artifact = try journal.testingValidationProfile.inspectBundle(application)',),
             'restoration-fixture-source-profile')
    require('.parentSyncFailure(Int(EIO))' in raw['SignedInstallationFixtureCase.swift']
            and '.parentSyncFailure(EIO)' not in raw['SignedInstallationFixtureCase.swift'], 'signed-errno-conversion')
    return ['retained-store-control-profile', 'retained-pins-live-gate', 'four-build-owned-guardian',
            'retained-fixture-snapshots', 'signed-errno-conversion']


if __name__ == '__main__':
    for check in verify_sources(read_sources(ROOT)):
        print('PASS stopped-rollback-source/' + check)
    print('Source obligations only; native and signed execution remain unqualified.')
