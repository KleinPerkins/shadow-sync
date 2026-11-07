#!/usr/bin/env python3
"""Protected first MVP candidate orchestration; never installs or promotes.

A tag and draft reserve the version/build before Apple effects. Every ambiguous
failure leaves that allocation intact. Reruns and existing allocations refuse:
use recorded submission IDs for owner reconciliation, never blind resubmission.
The existing notarization helper owns explicit local resume of retained bytes.
Only the distribution DMG and the constructed public receipt are release assets.
"""
import base64
from contextlib import contextmanager
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
require, Refusal, sha = execution.require, execution.Refusal, assembly.sha


def context(env):
    revision = execution.context(env)
    require(env.get('GITHUB_WORKFLOW_REF') == REPO + '/' + WORKFLOW + '@refs/heads/main'
            and env.get('RUNNER_ENVIRONMENT') == 'github-hosted'
            and env.get('RUNNER_ARCH') == 'ARM64' and env.get('GITHUB_RUN_ATTEMPT') == '1', 'release-context')
    return revision


def work_directory(env):
    context(env)
    # ci-build's accepted root is /private/tmp, never a source-tree build cache.
    return Path('/private/tmp') / ('shadow-sync-candidate-' + env['GITHUB_RUN_ID'])


def metadata():
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    require((version, build) == ('0.10.0', '15'), 'mvp-allocation-scope')
    return dict(version=version, build=build, tag='candidate-v' + version + '-build' + build)


def read(path):
    notary.regular(path, 8_388_608)
    return assembly.json_file(path)


def write(path, value):
    execution.write_json(path, value)


@contextmanager
def closed_environment(env):
    original = dict(os.environ)
    os.environ.clear()
    os.environ.update(execution.child_environment(env))
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(original)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Refusal('unexpected-api-redirect')


class GitHub:
    def __init__(self, token):
        require(isinstance(token, str) and token and '\n' not in token, 'github-token')
        self.token = token

    def request(self, path, *, method='GET', data=None, missing=False, asset=None):
        require(path == '' or path.startswith('/') and not path.startswith('//'), 'api-path')
        url = API + path
        body, content_type = None, 'application/json'
        if asset is not None:
            require(method == 'POST' and re.fullmatch(r'/releases/[1-9][0-9]*/assets\?name=[A-Za-z0-9._-]+', path), 'upload-path')
            url = 'https://uploads.github.com/repos/' + REPO + path
            notary.regular(asset)
            require(asset.stat().st_size <= 512 * 1024 * 1024, 'asset-size')
            body, content_type = asset.read_bytes(), 'application/octet-stream'
        elif data is not None:
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
    # This token is never supplied to the release-write client. No admin mutator
    # exists here. The pinned mint action requests administration:read only.
    client = app_credentials.GitHubReadClient(env.get('APP_TOKEN', ''))
    app_credentials.qualify(env, client)
    path = '/repos/' + REPO + '/immutable-releases'
    request = urllib.request.Request('https://api.github.com' + path, method='GET', headers={
        'Authorization': 'Bearer ' + client.token, 'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2026-03-10', 'User-Agent': 'shadow-sync-release-candidate'})
    try:
        with client.opener.open(request, timeout=20) as response:
            require(response.status == 200 and response.geturl() == request.full_url, 'immutability-readback')
            value = app_credentials.decode(response.read(app_credentials.MAX_RESPONSE + 1))
    except (OSError, urllib.error.URLError):
        raise Refusal('immutability-capability-unavailable') from None
    require(isinstance(value, dict) and value.get('enabled') is True, 'immutable-releases-required')


def admission(api, env, expected=None):
    revision = context(env)
    digest = source(revision)
    require(expected is None or expected == digest, 'source-changed')
    repo = api.request('')
    require(repo['id'] == REPO_ID and repo['full_name'] == REPO and repo['private'] is False
            and repo['default_branch'] == 'main' and repo.get('archived') is False, 'repository-identity')
    head = api.request('/git/ref/heads/main')['object']
    require(head['type'] == 'commit' and head['sha'] == revision, 'main-changed')
    immutable_enabled(env)
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
                ci_check_id=checks[0]['id'])


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
    return ('MVP candidate allocation; incomplete until immutable publication.\n'
            'No installation, migration, update, or operator acceptance is implied.\n'
            'Source: ' + prepared['revision'] + '\n'
            'Source input SHA-256: ' + prepared['source_sha256'] + '\n'
            'Workflow run: ' + str(prepared['run_id']) + '\n')


def reserved(api, prepared, *, published=False):
    tag = api.request('/git/ref/tags/' + prepared['tag'])
    require(tag['ref'] == 'refs/tags/' + prepared['tag'] and tag['object']['type'] == 'commit'
            and tag['object']['sha'] == prepared['revision'], 'reserved-tag-changed')
    release = api.request('/releases/' + str(prepared['release_id']))
    require(release['id'] == prepared['release_id'] and release['tag_name'] == prepared['tag']
            and release['target_commitish'] == prepared['revision']
            and release['body'] == reservation_body(prepared) and release['prerelease'] is True
            and release['draft'] is (not published), 'reserved-release-changed')
    if published:
        require(release.get('immutable') is True, 'release-not-immutable')
    return release


def prepare(api, env):
    require(not any(env.get(key) for key in execution.CONFIG), 'credentials-before-preparation')
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
    # Preparation is complete before allocation and before any Apple credential.
    require(admission(api, env, admitted['source_sha256']) == admitted, 'admission-changed')
    unallocated(api, release)
    prepared = dict(admitted, **release, run_id=int(env['GITHUB_RUN_ID']),
                    package_sha256=sha(work / 'python.pkg'), build_sha256=sha(work / 'build/build.json'),
                    orchestrator_sha256=sha(Path(__file__)))
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
    require(prepared['revision'] == context(env) and prepared['run_id'] == int(env['GITHUB_RUN_ID'])
            and {k: prepared[k] for k in metadata()} == metadata()
            and prepared['orchestrator_sha256'] == sha(Path(__file__))
            and prepared['package_sha256'] == sha(work / 'python.pkg')
            and prepared['build_sha256'] == sha(work / 'build/build.json'), 'prepared-inputs-changed')
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


def sign(api, env):
    work, prepared = prepared_attempt(env)
    require(admission(api, env, prepared['source_sha256']) == {k: prepared[k] for k in
            ('revision', 'source_sha256', 'ci_run_id', 'ci_run_attempt', 'ci_check_id')}, 'signing-admission-changed')
    require(reserved(api, prepared)['assets'] == [], 'premature-release-assets')
    certificate = apple_configuration(env)
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
    # Construct, never forward a raw producer record or arbitrary extra keys.
    public = {k: prepared[k] for k in ('revision', 'source_sha256', 'version', 'build', 'tag', 'run_id',
                                       'ci_run_id', 'ci_run_attempt', 'ci_check_id', 'orchestrator_sha256')}
    public.update(schema='shadow-sync-candidate/v1', repository=REPO, repository_id=REPO_ID,
        artifact=package['artifact'], architecture='arm64', publisher_team=expected['publisher_team'],
        package_receipt_sha256=sha(work / 'notary/release-package.json'),
        release_contract_sha256=sha(ROOT / 'Resources/release-contract.json'),
        notarized=True, stapled=True, downloaded_bytes_verified=False, installed=False, product_accepted=False)
    for key in ('app_notary_id', 'dmg_notary_id'):
        require(str(notary.uuid.UUID(package[key])) == package[key], 'public-notary-id')
        public[key] = package[key]
    receipt = work / 'candidate.json'
    write(receipt, public)
    return [artifact, receipt]


def asset_inventory(api, prepared, paths, expected):
    assets = api.pages('/releases/' + str(prepared['release_id']) + '/assets')
    require(len(assets) == len(paths) and {a['name'] for a in assets} == {p.name for p in paths}, 'release-asset-inventory')
    for path in paths:
        notary.regular(path)
        item = next(a for a in assets if a['name'] == path.name)
        require(item['state'] == 'uploaded' and item['size'] == path.stat().st_size
                and sha(path) == expected[path.name]
                and item['digest'] == 'sha256:' + expected[path.name], 'uploaded-asset-binding')
    return assets


def download_digest(url, expected_size):
    # Unauthenticated public readback. No token follows the CDN redirect.
    with urllib.request.urlopen(url, timeout=180) as response:
        digest, count = hashlib.sha256(), 0
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            require(count <= expected_size, 'download-size')
            digest.update(chunk)
    require(count == expected_size, 'download-size')
    return digest.hexdigest()


def publish(api, env):
    require(not any(env.get(key) for key in execution.CONFIG), 'credentials-during-publication')
    work, prepared = prepared_attempt(env)
    require(read(work / 'credentials-removed.json') == {'revision': prepared['revision'],
            'temporary_credentials_removed': True}, 'cleanup-unproven')
    execution.cleanup(work)
    admission(api, env, prepared['source_sha256'])
    require(reserved(api, prepared)['assets'] == [], 'release-already-started')
    paths = package_assets(work, prepared)
    public = read(paths[1])
    expected = {paths[0].name: public['artifact']['sha256'], paths[1].name: sha(paths[1])}
    require(sha(paths[0]) == expected[paths[0].name], 'publication-input-changed')
    write(work / 'publication-intent.json', {'release_id': prepared['release_id'], 'assets': expected})
    for path in paths:
        api.request('/releases/' + str(prepared['release_id']) + '/assets?name=' + path.name, method='POST', asset=path)
    asset_inventory(api, prepared, paths, expected)
    admission(api, env, prepared['source_sha256'])
    reserved(api, prepared)
    api.request('/releases/' + str(prepared['release_id']), method='PATCH',
                data={'draft': False, 'prerelease': True, 'make_latest': 'false'})
    reserved(api, prepared, published=True)
    assets = asset_inventory(api, prepared, paths, expected)
    latest = api.request('/releases/latest', missing=True)
    require(latest is None or latest['id'] != prepared['release_id'], 'candidate-is-latest')
    for path in paths:
        item = next(row for row in assets if row['name'] == path.name)
        url = 'https://github.com/' + REPO + '/releases/download/' + prepared['tag'] + '/' + path.name
        require(item['browser_download_url'] == url and download_digest(url, path.stat().st_size) == expected[path.name], 'downloaded-asset-binding')
    write(work / 'published.json', {'schema': 'shadow-sync-candidate-publication/v1',
        'revision': prepared['revision'], 'release_id': prepared['release_id'], 'tag': prepared['tag'],
        'immutable': True, 'latest': False, 'downloaded_bytes_verified': True,
        'assets': expected, 'installed': False, 'product_accepted': False})


def evidence(env):
    """Allowlisted reconciliation data only; no recursive upload of attempt state."""
    work = work_directory(env)
    if work.exists():
        require(work.is_dir() and not work.is_symlink() and work.stat().st_uid == os.getuid()
                and stat.S_IMODE(work.stat().st_mode) == 0o700, 'evidence-directory')
    result = {'schema': 'shadow-sync-candidate-attempt/v1', 'revision': context(env),
              'run_id': int(env['GITHUB_RUN_ID']), **metadata(), 'submissions': {}}
    for label in ('app', 'dmg'):
        rows = {}
        for kind in ('intent', 'submitted', 'accepted'):
            path = work / 'notary' / (label + '-' + kind + '.json')
            if path.exists():
                record = read(path)
                expected_name = 'submission.zip' if label == 'app' else 'submission.dmg'
                require(record['filename'] == expected_name and re.fullmatch('[0-9a-f]{64}', record['sha256']), 'evidence-binding')
                row = {'filename': expected_name, 'sha256': record['sha256']}
                if kind != 'intent':
                    require(str(notary.uuid.UUID(record['id'])) == record['id'], 'evidence-id')
                    row['id'] = record['id']
                if kind == 'accepted':
                    require(record['status'] == 'Accepted' and re.fullmatch('[0-9a-f]{64}', record['log_sha256']), 'evidence-accepted')
                    row.update(status='Accepted', log_sha256=record['log_sha256'])
                rows[kind] = row
        result['submissions'][label] = rows
    for name, fields in {'prepared': ('release_id', 'source_sha256'),
                         'allocation-intent': ('source_sha256',),
                         'published': ('release_id', 'immutable', 'latest', 'downloaded_bytes_verified', 'assets')}.items():
        path = work / (name + '.json')
        if path.exists():
            value = read(path)
            require(value['revision'] == context(env), 'evidence-source')
            if 'source_sha256' in fields:
                require(re.fullmatch('[0-9a-f]{64}', value['source_sha256']), 'evidence-source-digest')
            if 'release_id' in fields:
                require(type(value['release_id']) is int and value['release_id'] > 0, 'evidence-release-id')
            if name == 'published':
                require(value['immutable'] is True and value['latest'] is False
                        and value['downloaded_bytes_verified'] is True
                        and set(value['assets']) == {'candidate.json', 'ShadowSync-0.10.0-build15-macos-arm64.dmg'}
                        and all(re.fullmatch('[0-9a-f]{64}', v) for v in value['assets'].values()), 'evidence-publication')
            result[name] = {key: value[key] for key in fields}
    destination = evidence_directory()
    result['read_token_revocations'] = {}
    for phase in ('prepare', 'sign', 'publish'):
        path = destination / ('read-token-' + phase + '.json')
        expected = dict(revision=context(env), run_id=int(env['GITHUB_RUN_ID']), phase=phase,
                        token_revoked=True, subsequent_request_rejected=True)
        result['read_token_revocations'][phase] = path.exists() and read(path) == expected
    result['reconciliation_required'] = not ((work / 'published.json').exists()
        and all(result['read_token_revocations'].values()))
    write(destination / 'attempt.json', result)


def evidence_directory():
    parent = ROOT
    for name in ('outputs', 'release-candidate'):
        parent = parent / name
        if not os.path.lexists(parent):
            parent.mkdir(mode=0o700)
        require(parent.is_dir() and not parent.is_symlink() and parent.stat().st_uid == os.getuid()
                and not parent.stat().st_mode & 0o022, 'public-evidence-directory')
    return parent


def revoke_admin(env):
    app_credentials.context(env)
    phase = env.get('REVOCATION_PHASE')
    require(phase in ('prepare', 'sign', 'publish'), 'revocation-phase')
    app_credentials.GitHubReadClient(env.get('APP_TOKEN', '')).revoke_and_confirm()
    write(evidence_directory() / ('read-token-' + phase + '.json'), dict(revision=context(env),
        run_id=int(env['GITHUB_RUN_ID']), phase=phase, token_revoked=True, subsequent_request_rejected=True))


def main():
    os.umask(0o077)
    try:
        env = dict(os.environ)
        context(env)
        require(len(sys.argv) == 2 and sys.argv[1] in ('prepare', 'sign', 'publish', 'cleanup', 'evidence', 'admin-revoke'), 'mode')
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(Refusal('interrupted')))
        stage = sys.argv[1]
        if stage == 'admin-revoke':
            revoke_admin(env)
        elif stage == 'cleanup':
            work = work_directory(env)
            if work.exists():
                execution.cleanup(work)
        elif stage == 'evidence':
            evidence(env)
        else:
            globals()[stage](GitHub(env.get('GH_TOKEN')), env)
        print('Candidate stage completed; installation and acceptance remain separate.')
        return 0
    except BaseException:
        # Never expose subprocess output, credential values, network bodies or paths.
        print('Candidate stage refused. Preserve the allocation and reconcile recorded submission IDs; do not blindly rerun.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
