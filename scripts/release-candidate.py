#!/usr/bin/env python3
"""Owner-local first MVP candidate automation; never installs or activates updates.

Public tags/drafts reserve version/build before Apple effects, with no assets.
Private retained attempt state and existing delivery own qualification publication.
Ambiguous effects never trigger automatic retries or allocation reuse.
"""
import argparse
import fcntl
import io
import tarfile
import base64
from contextlib import contextmanager, redirect_stdout, redirect_stderr
from functools import wraps
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import sys
from types import SimpleNamespace
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPO = 'KleinPerkins/shadow-sync'
REPO_ID = 1442961455
WORKFLOW = '.github/workflows/release-candidate.yml'
API = 'https://api.github.com/repos/' + REPO
APPLE = ('APPLE_CERTIFICATE', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_SIGNING_IDENTITY',
         'APPLE_ID', 'APPLE_PASSWORD', 'APPLE_TEAM_ID')


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


app_credentials = load('app-credential-readiness')
execution = load('release-credential-readiness')
assembly = load('assemble-release-bundle')
notary = load('notarize-release-bundle')
delivery = load('delivery')
load('github_automation')
controls = load('merge_controls')
require, Refusal, sha = execution.require, execution.Refusal, assembly.sha


def context(env):
    # This is an explicitly invoked owner command. Hosted or self-hosted Actions
    # cannot impersonate the original owner configuration/authentication context.
    require(not env.get('GITHUB_ACTIONS') and sys.platform == 'darwin' and os.getuid() != 0,
            'owner-local-context')
    revision = env.get('RELEASE_SOURCE_REVISION', '')
    require(re.fullmatch('[0-9a-f]{40}', revision) and revision != '0' * 40
            and re.fullmatch('[1-9][0-9]{0,19}', env.get('RELEASE_ATTEMPT_ID', '')), 'release-identity')
    return revision


def work_directory(env):
    context(env)
    path = Path(env['RELEASE_WORK_DIRECTORY'])
    delivery.outside_git(path)
    require(str(path).startswith('/private/tmp/') and path != Path('/private/tmp'), 'private-build-root')
    delivery.private_directory(path.parent)
    return path


def metadata():
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    require((version, build) == ('0.10.0', '15'), 'mvp-allocation-scope')
    return dict(version=version, build=build, tag='candidate-v' + version + '-build' + build)


def read(path):
    notary.regular(path, 8_388_608)
    return assembly.json_file(path)


def write(path, value):
    # Exclusive file creation and its directory entry must both be durable before
    # allocation, signing or publication can start. Keep the intent on any error.
    execution.write_json(path, value)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextmanager
def closed_environment(env):
    original = dict(os.environ)
    allowed = execution.child_environment(env)
    if 'SHADOW_SYNC_DELIVERY_NODE' in env:
        allowed['SHADOW_SYNC_DELIVERY_NODE'] = env['SHADOW_SYNC_DELIVERY_NODE']
    try:
        os.environ.clear()
        os.environ.update(allowed)
        yield
    finally:
        os.environ.clear()
        os.environ.update(original)


def isolated_stage(function):
    @wraps(function)
    def invoke(api, env):
        with closed_environment(env):
            return function(api, env)
    return invoke


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Refusal('unexpected-api-redirect')


class GitHub:
    def __init__(self, token, *, read_only=False):
        require(isinstance(token, str) and token and '\n' not in token, 'github-token')
        self.token = token
        self.read_only = read_only

    def request(self, path, *, method='GET', data=None, missing=False):
        require(path == '' or path.startswith('/') and not path.startswith('//'), 'api-path')
        require(not self.read_only or method == 'GET', 'owner-read-capability')
        require(method == 'GET' or (method == 'POST' and path in ('/git/refs', '/releases')), 'allocation-only-write')
        url = API + path
        body, content_type = None, 'application/json'
        if path == '/owner-principal':
            require(method == 'GET', 'principal-read-only')
            url = 'https://api.github.com/user'
        if data is not None:
            body = json.dumps(data, sort_keys=True).encode()
        request = urllib.request.Request(url, data=body, method=method, headers={
            'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2026-03-10', 'Content-Type': content_type})
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=180) as response:
                raw = response.read(8_388_609)
                require(len(raw) <= 8_388_608, 'api-response-size')
                require(response.geturl() == request.full_url, 'unexpected-api-redirect')
                return app_credentials.decode(raw)
        except urllib.error.HTTPError as error:
            if error.code == 404 and missing:
                return None
            raise Refusal('github-request-failed') from None
        except (urllib.error.URLError, TimeoutError):
            # No write retries: a timeout can mean that the effect succeeded.
            raise Refusal('github-request-ambiguous') from None

    def pages(self, path, key=None):
        rows = []
        for page in range(1, 101):
            value = self.request(path + ('&' if '?' in path else '?') + 'per_page=100&page=' + str(page))
            chunk = value[key] if key else value
            require(type(chunk) is list and len(chunk) <= 100, 'api-pagination')
            rows.extend(chunk)
            if len(chunk) < 100:
                return rows
        raise Refusal('api-pagination-limit')


def source(revision):
    return load('ci-shards').git_source_digest(ROOT, revision)


def immutable_enabled(env):
    # Explicit owner read capability, never the reviewer App or write client.
    client = GitHub(env.get('OWNER_GITHUB_READ_TOKEN', ''), read_only=True)
    principal = client.request('/owner-principal')
    repo = client.request('')
    require(principal.get('login') == 'KleinPerkins' and principal.get('id') == 49759187
            and principal.get('type') == 'User' and repo.get('id') == REPO_ID
            and repo.get('full_name') == REPO and repo.get('permissions', {}).get('admin') is True,
            'owner-read-principal')
    controls.verify_controls(repo, client.pages('/rules/branches/main'))
    require(client.request('/immutable-releases').get('enabled') is True, 'immutable-releases-required')
    # A closed tag-protection profile: creation remains possible, while update
    # and deletion have no bypass. Unknown conditions do not count as protection.
    protected_ids = []
    for item in client.pages('/rulesets?includes_parents=true'):
        row = client.request('/rulesets/' + str(item['id']))
        if (row.get('target') == 'tag' and row.get('enforcement') == 'active'
                and row.get('bypass_actors') == []
                and set(row.get('conditions', {})) == {'ref_name'}
                and row['conditions']['ref_name'].get('exclude') == []
                and any(name in ('~ALL', 'refs/tags/candidate-v*', 'refs/tags/' + metadata()['tag'])
                        for name in row['conditions']['ref_name'].get('include', []))
                and {'update', 'deletion'} <= {rule['type'] for rule in row.get('rules', [])}):
            require(type(row.get('id')) is int and row['id'] == item['id'], 'tag-ruleset-identity')
            protected_ids.append(row['id'])
    require(protected_ids, 'protected-candidate-tags-required')
    return dict(schema='shadow-sync-owner-release-controls/v1', repository_id=REPO_ID,
                owner_user_id=principal['id'], main_controls_verified=True, immutable_releases=True,
                protected_tag_ruleset_ids=sorted(protected_ids))


def admission(api, env, expected=None):
    revision = context(env)
    digest = source(revision)
    require(expected is None or expected == digest, 'source-changed')
    principal = api.request('/owner-principal')
    require(principal.get('login') == 'KleinPerkins' and principal.get('id') == 49759187
            and principal.get('type') == 'User', 'owner-allocation-principal')
    repo = api.request('')
    require(repo['id'] == REPO_ID and repo['full_name'] == REPO and repo['private'] is False
            and repo['default_branch'] == 'main' and repo.get('archived') is False, 'repository-identity')
    head = api.request('/git/ref/heads/main')['object']
    require(head['type'] == 'commit' and head['sha'] == revision, 'main-changed')
    owner_controls = immutable_enabled(env)
    prs = api.pages('/commits/' + revision + '/pulls')
    require(any(row.get('merged_at') and row.get('merge_commit_sha') == revision
                and row.get('base', {}).get('ref') == 'main'
                and row.get('base', {}).get('repo', {}).get('id') == REPO_ID for row in prs), 'merged-main-source')
    runs = api.pages('/actions/workflows/ci.yml/runs?head_sha=' + revision + '&branch=main&event=push', 'workflow_runs')
    require(runs, 'ci-run-missing')
    run = max(runs, key=lambda row: (row['run_number'], row['run_attempt']))
    require(run['head_sha'] == revision and run['head_branch'] == 'main' and run['event'] == 'push'
            and run['path'] == '.github/workflows/ci.yml' and run['status'] == 'completed'
            and run['conclusion'] == 'success' and run['repository']['id'] == REPO_ID
            and run['head_repository']['id'] == REPO_ID, 'complete-ci-required')
    checks = api.pages('/commits/' + revision + '/check-runs?filter=all', 'check_runs')
    # Bind the successful aggregate to this run's latest attempt, not an older rerun.
    jobs = api.pages('/actions/runs/' + str(run['id']) + '/attempts/' + str(run['run_attempt']) + '/jobs', 'jobs')
    aggregate = [row for row in jobs if row['name'] == 'ci-required']
    require(len(aggregate) == 1 and aggregate[0]['status'] == 'completed'
            and aggregate[0]['conclusion'] == 'success', 'ci-attempt-binding')
    checks = [row for row in checks if row['name'] == 'ci-required'
              and row.get('check_suite', {}).get('id') == run['check_suite_id']
              and aggregate[0]['check_run_url'] == API + '/check-runs/' + str(row['id'])]
    require(len(checks) == 1 and checks[0]['app']['id'] == 15368
            and checks[0]['head_sha'] == revision and checks[0]['status'] == 'completed'
            and checks[0]['conclusion'] == 'success', 'ci-required-integration')
    return dict(revision=revision, source_sha256=digest, ci_run_id=run['id'], ci_run_attempt=run['run_attempt'],
                ci_check_id=checks[0]['id'], owner_controls=owner_controls)


def unallocated(api, release):
    tags = [row['name'] for row in api.pages('/tags')]
    tags += [row['tag_name'] for row in api.pages('/releases')]
    for tag in set(tags):
        parsed = re.fullmatch(r'candidate-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-build([1-9][0-9]*)', tag)
        require(parsed is not None, 'unrecognized-release-allocation')
        require('.'.join(parsed.groups()[:3]) != release['version']
                and int(parsed[4]) < int(release['build']), 'version-or-build-allocated')
    require(api.request('/git/ref/tags/' + release['tag'], missing=True) is None
            and api.request('/releases/tags/' + release['tag'], missing=True) is None, 'candidate-already-allocated')


def reservation_body(prepared):
    return ('Private MVP candidate allocation; this draft has no distribution assets.\n'
            'No installation, migration, update, or operator acceptance is implied.\n'
            'Source: ' + prepared['revision'] + '\n'
            'Source input SHA-256: ' + prepared['source_sha256'] + '\n'
            'Owner attempt: ' + str(prepared['run_id']) + '\n')


def reserved(api, prepared):
    tag = api.request('/git/ref/tags/' + prepared['tag'])
    require(tag['ref'] == 'refs/tags/' + prepared['tag'] and tag['object']['type'] == 'commit'
            and tag['object']['sha'] == prepared['revision'], 'reserved-tag-changed')
    release = api.request('/releases/' + str(prepared['release_id']))
    require(release['id'] == prepared['release_id'] and release['tag_name'] == prepared['tag']
            and release['target_commitish'] == prepared['revision']
            and release['body'] == reservation_body(prepared) and release['prerelease'] is True
            and release['draft'] is True, 'reserved-release-changed')
    return release


@isolated_stage
def prepare(api, env):
    require(not any(env.get(key) for key in execution.CONFIG), 'credentials-before-preparation')
    private_configuration(env)
    admitted = admission(api, env)
    release = metadata()
    unallocated(api, release)
    work = work_directory(env)
    require(not os.path.lexists(work), 'existing-release-attempt')
    work.mkdir(mode=0o700)
    with closed_environment(env):
        assembly.build.prepare(work / 'build', admitted, 'package-contract')
        pin = assembly.runtime.load_pin()
        require(pin['package_url'].startswith('https://www.python.org/ftp/python/'), 'dependency-origin')
        with urllib.request.urlopen(pin['package_url'], timeout=60) as response, (work / 'python.pkg').open('xb') as target:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                require(total <= pin['package_bytes'], 'dependency-size')
                target.write(chunk)
        require(total == pin['package_bytes'] and sha(work / 'python.pkg') == pin['package_sha256'], 'dependency-integrity')
    with closed_environment(env):
        prepare_signer(work)
    # Preparation is complete before allocation and before any Apple credential.
    require(admission(api, env, admitted['source_sha256']) == admitted, 'admission-changed')
    unallocated(api, release)
    prepared = dict(admitted, **release, run_id=int(env['RELEASE_ATTEMPT_ID']),
                    package_sha256=sha(work / 'python.pkg'), build_sha256=sha(work / 'build/build.json'),
                    orchestrator_sha256=sha(Path(__file__)), signer_sha256=sha(work / 'sign_update'),
                    delivery_config_sha256=sha(Path(env['RELEASE_DELIVERY_CONFIG'])))
    write(work / 'allocation-intent.json', prepared)
    api.request('/git/refs', method='POST', data={'ref': 'refs/tags/' + release['tag'], 'sha': admitted['revision']})
    draft = api.request('/releases', method='POST', data={'tag_name': release['tag'],
        'target_commitish': admitted['revision'], 'name': release['tag'], 'body': reservation_body(prepared),
        'draft': True, 'prerelease': True, 'make_latest': 'false'})
    prepared['release_id'] = draft['id']
    require(type(prepared['release_id']) is int and prepared['release_id'] > 0, 'release-id')
    require(reserved(api, prepared)['assets'] == [], 'existing-release-assets')
    write(work / 'prepared.json', prepared)


def prepared_attempt(env):
    work = work_directory(env)
    require(work.is_dir() and not work.is_symlink() and work.stat().st_uid == os.getuid()
            and stat.S_IMODE(work.stat().st_mode) == 0o700, 'private-attempt')
    prepared = read(work / 'prepared.json')
    require(prepared['revision'] == context(env) and prepared['run_id'] == int(env['RELEASE_ATTEMPT_ID'])
            and {k: prepared[k] for k in metadata()} == metadata()
            and prepared['orchestrator_sha256'] == sha(Path(__file__))
            and prepared['package_sha256'] == sha(work / 'python.pkg')
            and prepared['build_sha256'] == sha(work / 'build/build.json')
            and prepared['signer_sha256'] == sha(work / 'sign_update') == execution.SIGNER_SHA256
            and prepared['delivery_config_sha256'] == sha(Path(env['RELEASE_DELIVERY_CONFIG'])), 'prepared-inputs-changed')
    return work, prepared


def apple_configuration(env):
    require(all(isinstance(env.get(k), str) and 0 < len(env[k]) <=
                (1_048_576 if k == 'APPLE_CERTIFICATE' else 4096) for k in APPLE), 'apple-configuration')
    team = assembly.json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier']
    require(env['APPLE_TEAM_ID'] == team and re.fullmatch(r'Developer ID Application: [^\r\n]+ \('
            + re.escape(team) + r'\)', env['APPLE_SIGNING_IDENTITY']), 'apple-publisher')
    certificate = base64.b64decode(env['APPLE_CERTIFICATE'], validate=True)
    require(certificate, 'empty-certificate')
    return certificate


@isolated_stage
def sign(api, env):
    work, prepared = prepared_attempt(env)
    require(admission(api, env, prepared['source_sha256']) == {k: prepared[k] for k in
            ('revision', 'source_sha256', 'ci_run_id', 'ci_run_attempt', 'ci_check_id', 'owner_controls')}, 'signing-admission-changed')
    require(reserved(api, prepared)['assets'] == [], 'premature-release-assets')
    certificate = apple_configuration(env)
    execution.configuration(env)
    # Retained signing intent prevents a second invocation even before notary IDs exist.
    write(work / 'signing-intent.json', {'revision': prepared['revision'], 'run_id': prepared['run_id']})
    with closed_environment(env):
        with execution.signing_keychain(work, certificate, env) as keychain:
            # Bound unlock to this job; notary waits can exceed readiness's probe timeout.
            execution.command('release-keychain-timeout', '/usr/bin/security', 'set-keychain-settings', '-lut', '7200', keychain)
            identities = execution.command('certificate-trust', '/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', keychain).stdout
            matches = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\r\n]+)"\s*$', identities, re.MULTILINE)
            fingerprints = [fingerprint for fingerprint, name in matches if name == env['APPLE_SIGNING_IDENTITY']]
            require(len(fingerprints) == 1, 'unique-signing-identity')
            fingerprint = fingerprints[0]
            execution.command('store-notary-profile', '/usr/bin/xcrun', 'notarytool', 'store-credentials',
                'shadow-sync-candidate', '--keychain', keychain, '--apple-id', env['APPLE_ID'],
                '--password', env['APPLE_PASSWORD'], '--team-id', env['APPLE_TEAM_ID'], '--validate')
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                assembly.runtime.build(SimpleNamespace(package=str(work / 'python.pkg'), output=str(work / 'runtime'),
                    signing_identity=fingerprint, publisher_team=env['APPLE_TEAM_ID'], allow_ad_hoc_fixture=False))
            args = SimpleNamespace(app=str(work / 'build/production/package/ShadowSync.app'),
                build_record=str(work / 'build/build.json'), runtime_output=str(work / 'runtime'),
                output=str(work / 'assembly'), signing_identity=fingerprint, keychain=str(keychain),
                publisher_team=env['APPLE_TEAM_ID'], source_revision=prepared['revision'], source_sha256=prepared['source_sha256'])
            assembly.assemble(args)
            args.assembly, args.output = str(work / 'assembly'), str(work / 'notary')
            args.notary_profile, args.resume = 'shadow-sync-candidate', False
            notary.package(args)
        execution.cleanup(work)
        detached_assets(work, prepared, env)
    write(work / 'credentials-removed.json', {'revision': prepared['revision'], 'temporary_credentials_removed': True})


def package_assets(work, prepared):
    package = read(work / 'notary/release-package.json')
    expected = dict(schema='shadow-sync-release-package/v1', revision=prepared['revision'],
        source_sha256=prepared['source_sha256'], assembly_sha256=sha(work / 'assembly/release-assembly.json'),
        packager_sha256=sha(ROOT / 'scripts/notarize-release-bundle.py'),
        publisher_team=assembly.json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier'])
    require(all(package[k] == value for k, value in expected.items()) and package['version'] == prepared['version']
            and package['build'] == prepared['build'] and package['architecture'] == 'arm64'
            and all(package[k] is True for k in ('notarized', 'stapled', 'gatekeeper'))
            and all(package[k] is False for k in ('published', 'installed', 'product_accepted')), 'package-binding')
    name = 'ShadowSync-' + prepared['version'] + '-build' + prepared['build'] + '-macos-arm64.dmg'
    artifact = work / 'notary' / name
    notary.regular(artifact)
    require(package['artifact'] == {'name': name, 'bytes': artifact.stat().st_size, 'sha256': sha(artifact)}, 'distribution-bytes')
    return artifact


def private_configuration(env):
    config = delivery.load_config(env['RELEASE_DELIVERY_CONFIG'])
    delivery.require_free(config)
    return config


def prepare_signer(work):
    # Use the already qualified standalone signing utility; no updater is added.
    with urllib.request.urlopen(execution.ARCHIVE_URL, timeout=60) as response:
        raw = response.read(64 * 1024 * 1024 + 1)
    require(len(raw) <= 64 * 1024 * 1024 and hashlib.sha256(raw).hexdigest() == execution.ARCHIVE_SHA256,
            'detached-tool-archive')
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        member = archive.getmember('./bin/sign_update')
        require(member.isfile() and 0 < member.size < 10_000_000, 'detached-tool-layout')
        data = archive.extractfile(member).read()
    require(hashlib.sha256(data).hexdigest() == execution.SIGNER_SHA256, 'detached-tool-integrity')
    path = work / 'sign_update'
    with path.open('xb') as stream:
        stream.write(data)
    path.chmod(0o700)
    execution.command('detached-tool-signature', '/usr/bin/codesign', '--verify', '--strict', path)


def verify_detached(path, public, signature):
    raw = base64.b64decode(public, validate=True)
    sig = base64.b64decode(signature, validate=True)
    require(len(raw) == 32 and hashlib.sha256(raw).hexdigest() == execution.PUBLIC_KEY_SHA256
            and len(sig) == 64 and base64.b64encode(sig).decode() == signature, 'detached-key-and-signature')
    # Independent pinned Node crypto verification, including a tamper control.
    js = """const fs=require('node:fs'),c=require('node:crypto');
const [p,k,s]=process.argv.slice(1),b=fs.readFileSync(p),sig=Buffer.from(s,'base64');
const key=c.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(k,'base64')]),format:'der',type:'spki'});
if(!c.verify(null,b,key,sig))process.exit(1);b[0]^=1;if(c.verify(null,b,key,sig))process.exit(1);"""
    execution.command('detached-verify', delivery.pinned_node(), '-e', js, path, public, signature)


def detached_assets(work, prepared, env):
    artifact = package_assets(work, prepared)
    app = work / 'notary/payload/ShadowSync.app'
    record = read(work / 'notary/app-stapled.json')
    require(notary.app_tree(app) == record['entries'], 'final-stapled-app-bytes')
    team = assembly.json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier']
    assembly.verify_code(app, team, assembly.APP_ID)
    assembly.verify_code(app / 'Contents/Helpers/ShadowSyncLifecycleCoordinator', team, assembly.HELPER_ID)
    execution.command('final-app-ticket', '/usr/bin/xcrun', 'stapler', 'validate', app)
    archive = work / 'ShadowSync.zip'
    require(not os.path.lexists(archive), 'existing-final-archive')
    execution.command('final-stapled-archive', '/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    require(notary.app_tree(app) == record['entries'], 'archived-app-changed')
    descriptors = []
    for kind, path in (('archive', archive), ('package', artifact)):
        notary.regular(path, delivery.MAX_ARCHIVE)
        require(0 < path.stat().st_size <= delivery.MAX_ARCHIVE, 'empty-or-large-artifact')
        before = sha(path)
        signature = execution.command('detached-sign', work / 'sign_update', '--ed-key-file', '-', '-p', path,
                                      input=env['SPARKLE_PRIVATE_ED_KEY'] + '\n').stdout.strip()
        verify_detached(path, env['SPARKLE_PUBLIC_ED_KEY'], signature)
        require(sha(path) == before, 'signed-artifact-changed')
        descriptors.append(dict(path=f"/v1/apps/{delivery.APP}/releases/{prepared['tag']}/{kind}",
            size=path.stat().st_size, sha256=before, ed25519_signature=signature))
    value = dict(schema='shadow-sync/release/v1', app_id=delivery.APP, bundle_id=delivery.APP,
        team_id=team, channel='qualification', qualified=False, version=prepared['version'], build=int(prepared['build']),
        minimum_macos='26.0', architecture='arm64', data_schema_version=1, source_revision=prepared['revision'],
        qualification_id=prepared['tag'], archive=descriptors[0], first_install=descriptors[1])
    delivery.validate_manifest(value)
    receipt = dict(schema='shadow-sync/qualification/v1', app_id=delivery.APP,
        qualification_id=value['qualification_id'], source_revision=prepared['revision'], build=value['build'],
        archive_sha256=value['archive']['sha256'], archive_size=value['archive']['size'],
        first_install_sha256=value['first_install']['sha256'], first_install_size=value['first_install']['size'],
        checks={key: True for key in delivery.CHECKS})
    # This producer reached every check above; never accepts caller-supplied gates.
    delivery.validate_receipt(value, receipt)
    write(work / 'manifest.json', value)
    write(work / 'qualification.json', receipt)
    write(work / 'detached.json', dict(public_key=env['SPARKLE_PUBLIC_ED_KEY'],
        manifest_sha256=sha(work / 'manifest.json'), receipt_sha256=sha(work / 'qualification.json')))


def publication_inputs(work, prepared):
    artifact = package_assets(work, prepared)
    value, receipt, detached = (read(work / name) for name in ('manifest.json', 'qualification.json', 'detached.json'))
    require(detached['manifest_sha256'] == sha(work / 'manifest.json')
            and detached['receipt_sha256'] == sha(work / 'qualification.json'), 'private-record-binding')
    delivery.validate_manifest(value)
    delivery.validate_receipt(value, receipt)
    require(value['channel'] == 'qualification' and value['qualified'] is False
            and value['source_revision'] == prepared['revision'] and value['version'] == prepared['version']
            and value['build'] == int(prepared['build']) and value['qualification_id'] == prepared['tag'], 'qualification-only')
    for kind, path, descriptor in (('archive', work / 'ShadowSync.zip', value['archive']),
                                    ('package', artifact, value['first_install'])):
        notary.regular(path, delivery.MAX_ARCHIVE)
        require(descriptor['path'] == f"/v1/apps/{delivery.APP}/releases/{prepared['tag']}/{kind}"
                and (sha(path), path.stat().st_size) == (descriptor['sha256'], descriptor['size']), 'publication-input-changed')
        verify_detached(path, detached['public_key'], descriptor['ed25519_signature'])
    return value, receipt, work / 'ShadowSync.zip', artifact


@isolated_stage
def publish(api, env):
    require(not any(env.get(key) for key in execution.CONFIG), 'credentials-during-publication')
    config = private_configuration(env)
    work, prepared = prepared_attempt(env)
    require(read(work / 'credentials-removed.json') == {'revision': prepared['revision'],
            'temporary_credentials_removed': True}, 'cleanup-unproven')
    execution.cleanup(work)
    require(admission(api, env, prepared['source_sha256']) == {k: prepared[k] for k in
            ('revision', 'source_sha256', 'ci_run_id', 'ci_run_attempt', 'ci_check_id', 'owner_controls')}, 'publication-admission-changed')
    require(reserved(api, prepared)['assets'] == [], 'public-release-assets-forbidden')
    value, receipt, archive, package = publication_inputs(work, prepared)
    intent = dict(revision=prepared['revision'], manifest_sha256=sha(work / 'manifest.json'),
                  receipt_sha256=sha(work / 'qualification.json'), config_sha256=sha(Path(env['RELEASE_DELIVERY_CONFIG'])))
    # Exclusive durable intent precedes every provider effect. On ambiguity,
    # retain it and use the existing delivery reconciliation interface explicitly.
    notary.record(work / 'publication-inputs.json', intent)
    write(work / 'publication-intent.json', intent)
    def before_promote():
        require(sha(Path(env['RELEASE_DELIVERY_CONFIG'])) == intent['config_sha256'], 'delivery-config-changed')
        private_configuration(env)
        require(admission(api, env, prepared['source_sha256']) == {k: prepared[k] for k in
                ('revision', 'source_sha256', 'ci_run_id', 'ci_run_attempt', 'ci_check_id', 'owner_controls')}, 'promotion-admission-changed')
        require(reserved(api, prepared)['assets'] == [], 'public-release-assets-forbidden')
    with closed_environment(env):
        # Original HOME preserves owner OAuth. An explicit API token belongs only
        # to Wrangler's child environment, never Git, Node validation or signing.
        authentication = {key: env[key] for key in ('CLOUDFLARE_API_TOKEN',) if key in env}
        provider = delivery.Cloudflare(config, wrangler_auth=authentication)
        delivery.publish(provider, value, receipt, archive, package, before_promote=before_promote)
    # Existing delivery has authenticated both downloaded artifacts and revoked
    # readback grants before its verified qualification pointer can advance.
    require(admission(api, env, prepared['source_sha256']) == {k: prepared[k] for k in
            ('revision', 'source_sha256', 'ci_run_id', 'ci_run_attempt', 'ci_check_id', 'owner_controls')}, 'publication-postflight-changed')
    require(reserved(api, prepared)['assets'] == [], 'public-release-assets-forbidden')
    write(work / 'published.json', dict(schema='shadow-sync-private-candidate-publication/v1',
        revision=prepared['revision'], tag=prepared['tag'], channel='qualification',
        manifest_sha256=intent['manifest_sha256'], downloaded_bytes_verified=True,
        installed=False, product_accepted=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('run', 'prepare', 'sign', 'publish', 'cleanup'))
    parser.add_argument('--source-revision', required=True)
    parser.add_argument('--attempt-id', required=True)
    parser.add_argument('--work-directory', required=True, type=Path)
    parser.add_argument('--delivery-config', required=True, type=Path)
    parser.add_argument('--credentials', type=Path, help='Private mode-0600 eight-key signing JSON; run or sign only')
    args = parser.parse_args()
    old_mask = os.umask(0o077)
    old_handler = signal.getsignal(signal.SIGTERM)
    try:
        env = dict(os.environ, RELEASE_SOURCE_REVISION=args.source_revision, RELEASE_ATTEMPT_ID=args.attempt_id,
                   RELEASE_WORK_DIRECTORY=str(args.work_directory), RELEASE_DELIVERY_CONFIG=str(args.delivery_config))
        with closed_environment(env):
            context(env)
            require(not any(env.get(key) for key in execution.CONFIG), 'ambient-signing-credentials')
            require((args.stage in ('run', 'sign')) == (args.credentials is not None), 'explicit-signing-configuration')
            work = work_directory(env)
            # Parent must already be owner-private; serialize the whole attempt,
            # including prepare before its output exists. Never remove the lock.
            lock = work.with_name(work.name + '.lock')
            descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            try:
                info = os.fstat(descriptor)
                require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                        and info.st_size == 0 and stat.S_IMODE(info.st_mode) == 0o600, 'attempt-lock')
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(Refusal('interrupted')))
                if args.stage == 'cleanup':
                    if work.exists(): execution.cleanup(work)
                else:
                    private_configuration(env)
                    api = GitHub(env.get('GH_TOKEN'))
                    stages = ('prepare', 'sign', 'publish') if args.stage == 'run' else (args.stage,)
                    try:
                        for stage in stages:
                            if stage == 'sign':
                                credentials = delivery.private_json(args.credentials)
                                require(set(credentials) == set(execution.CONFIG), 'closed-signing-config')
                                env.update(credentials)
                                credentials.clear()
                            try:
                                globals()[stage](api, env)
                            finally:
                                for name in execution.CONFIG:
                                    env.pop(name, None)
                    finally:
                        if work.exists():
                            with closed_environment(env):
                                execution.cleanup(work)

            finally:
                os.close(descriptor)
        print('Private candidate stage completed; installation and acceptance remain separate.')
        return 0
    except BaseException:
        print('Private candidate stage refused. Retain the attempt and allocation; reconcile privately before retry.', file=sys.stderr)
        return 1
    finally:
        os.umask(old_mask)
        signal.signal(signal.SIGTERM, old_handler)


if __name__ == '__main__':
    raise SystemExit(main())
