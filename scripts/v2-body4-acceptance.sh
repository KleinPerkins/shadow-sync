#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
SCRATCH="$(mktemp -d /private/tmp/shadow-sync-v2-body4.XXXXXX)"
export SWIFTPM_MODULECACHE_OVERRIDE="$SCRATCH/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-module-cache"
HOTFIX_ONLY=0
if [ "${1:-}" = "--hotfix-only" ] && [ "$#" -eq 1 ]; then
  HOTFIX_ONLY=1
elif [ "$#" -ne 0 ]; then
  printf 'usage: v2-body4-acceptance.sh [--hotfix-only]\n' >&2
  exit 2
fi

cleanup() {
  local status="$1"
  trap - EXIT INT TERM
  shadow_sync_reap_owned_root_helpers "$SCRATCH" v2-body4-acceptance || status=1
  shadow_sync_remove_owned_root "$SCRATCH" v2-body4-acceptance || status=1
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BUILD_ARGS=(
  --package-path "$CAPABILITY"
  --scratch-path "$SCRATCH/testing"
  --disable-index-store
  -Xswiftc -DSHADOW_SYNC_TESTING
)
swift build "${BUILD_ARGS[@]}" --product ShadowSync
swift build "${BUILD_ARGS[@]}" --product ShadowSyncSelfTest
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$BIN_DIR/ShadowSync"
SELF_TEST="$BIN_DIR/ShadowSyncSelfTest"

run_focused() {
  local id="$1" argument="$2" timing="$SCRATCH/$1.time"
  if ! /usr/bin/time -p -o "$timing" \
      "$SELF_TEST" --app-executable "$APP" "$argument"; then
    cat "$timing" >&2
    return 1
  fi
  printf 'v2-body4-acceptance: %s duration=%ss\n' \
    "$id" "$(awk '$1 == "real" {print $2}' "$timing")"
}

if [ "$HOTFIX_ONLY" -eq 0 ]; then
  run_focused DM2-T04-success --dm2-t04-success-only
  run_focused DM2-T04-relations --dm2-t04-relations-only
  run_focused DM2-T04-claim-races --dm2-t04-races-a-only
  run_focused DM2-T04-identity-races --dm2-t04-races-b-only
  run_focused DM2-T05-trace --dm2-t05-trace-only
  run_focused DM2-T05-veto --dm2-t05-veto-only
  run_focused DM2-T05-shared-command-policy --dm2-t05-policy-only
fi
run_focused DM2-T13 --dm2-t13-only

REPORT_FIXTURE="$CAPABILITY/Tests/ShadowSyncSelfTests/Fixtures/legacy-v1-report.json"
LOG_FIXTURE="$CAPABILITY/Tests/ShadowSyncSelfTests/Fixtures/legacy-v1-latest.log"
printf '%s  %s\n' \
  d3030cc8a53fbb0f9ef85974d0b0fdf04496f7f50bdcc2744f5f41230ec995af \
  "$REPORT_FIXTURE" >"$SCRATCH/fixtures.sha256"
printf '%s  %s\n' \
  51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7 \
  "$LOG_FIXTURE" >>"$SCRATCH/fixtures.sha256"
/usr/bin/shasum -a 256 -c "$SCRATCH/fixtures.sha256"

"$CAPABILITY/scripts/build-app.sh" \
  --scratch-path "$SCRATCH/production-swift" \
  --output-dir "$SCRATCH/production-output" \
  >"$SCRATCH/production-app-path.txt"
PRODUCTION_APP="$(cat "$SCRATCH/production-app-path.txt")"
PRODUCTION_BINARY="$PRODUCTION_APP/Contents/MacOS/ShadowSync"
[ "$(plutil -extract ShadowSyncBuildMode raw \
  "$PRODUCTION_APP/Contents/Info.plist")" = production ]
codesign --verify --strict --verbose=2 "$PRODUCTION_APP"
/usr/bin/nm -gj "$PRODUCTION_BINARY" >"$SCRATCH/production-symbols.txt"
if /usr/bin/grep -E \
  'SHADOW_SYNC_TESTING|DM2Body4|V2Body4SelfTest|finalRefMutationMarker' \
  "$SCRATCH/production-symbols.txt"; then
  printf 'v2-body4-acceptance: production binary exposes a Body 4 test seam\n' >&2
  exit 1
fi
if /usr/bin/strings "$PRODUCTION_BINARY" | /usr/bin/grep -E -- \
    '--dm2-t0(4|5)-|--dm2-t13-|--shadow-sync-test-final-mutation=ref'; then
  printf 'v2-body4-acceptance: production binary contains a Body 4 test marker\n' >&2
  exit 1
fi
if /usr/bin/nm -u "$PRODUCTION_BINARY" | /usr/bin/grep -E \
    'URLSession|NSURLSession|libcurl|curl_easy|curl_multi'; then
  printf 'v2-body4-acceptance: unapproved network client found\n' >&2
  exit 1
fi

TEST_APP_OUTPUT="$SCRATCH/testing-app-output"
"$CAPABILITY/scripts/build-app.sh" \
  --scratch-path "$SCRATCH/testing-app-swift" \
  --output-dir "$TEST_APP_OUTPUT" \
  --testing >/dev/null
TEST_APP_EXECUTABLE="$TEST_APP_OUTPUT/ShadowSync.app/Contents/MacOS/ShadowSync"
METADATA_DIGEST="$(printf 'f%.0s' $(seq 1 64))"
LIFECYCLE_ROOT="$SCRATCH/lifecycle-root"
mkdir -m 700 "$LIFECYCLE_ROOT"
mkdir -m 700 "$LIFECYCLE_ROOT/home"
make_lifecycle_source() {
  local name="$1" revision="$2" source_digest="$3" app
  app="$LIFECYCLE_ROOT/$name.app"
  cp -R "$PRODUCTION_APP" "$app"
  plutil -replace ShadowSyncSourceRevision \
    -string "$revision" "$app/Contents/Info.plist"
  plutil -replace ShadowSyncSourceInputSHA256 \
    -string "$source_digest" "$app/Contents/Info.plist"
  plutil -replace ShadowSyncReleaseContractSHA256 \
    -string "$METADATA_DIGEST" "$app/Contents/Info.plist"
  codesign --force --sign - --timestamp=none \
    --identifier com.kleinperkins.shadow-sync "$app" >/dev/null
  /usr/bin/xattr -cr "$app"
  codesign --verify --strict --verbose=2 "$app" >/dev/null
  printf '%s\n' "$app"
}
SOURCE_N="$(make_lifecycle_source lifecycle-n \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
SOURCE_EQUIVALENT="$(make_lifecycle_source lifecycle-equivalent \
  cccccccccccccccccccccccccccccccccccccccc \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
SOURCE_N1="$(make_lifecycle_source lifecycle-n1 \
  dddddddddddddddddddddddddddddddddddddddd \
  eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee)"
python3 - \
  "$TEST_APP_EXECUTABLE" "$LIFECYCLE_ROOT" \
  "$SOURCE_N" "$SOURCE_EQUIVALENT" "$SOURCE_N1" <<'PY'
import json
import socket
import subprocess
import sys

executable, root, source_n, source_equivalent, source_n1 = sys.argv[1:]
parent, child = socket.socketpair()
parent.settimeout(120)
request = {
    "schema": "shadow-sync-m6-lifecycle/v1",
    "testRoot": root,
    "sourceN": source_n,
    "sourceEquivalent": source_equivalent,
    "sourceN1": source_n1,
}
process = subprocess.Popen(
    [
        "/usr/bin/sandbox-exec",
        "-p",
        "(version 1) (allow default) (deny network*) "
        "(allow network-bind (local unix-socket)) "
        "(allow network-outbound (remote unix-socket))",
        executable,
        "--shadow-sync-m6-lifecycle-channel",
        str(child.fileno()),
    ],
    pass_fds=(child.fileno(),),
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
child.close()
try:
    parent.sendall(json.dumps(request, sort_keys=True).encode() + b"\n")
    parent.shutdown(socket.SHUT_WR)
    payload = b""
    while not payload.endswith(b"\n"):
        block = parent.recv(65536)
        if not block:
            break
        payload += block
    stdout, stderr = process.communicate(timeout=120)
except (socket.timeout, subprocess.TimeoutExpired):
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
    raise SystemExit("Body 4 lifecycle cut timed out")
finally:
    parent.close()
if process.returncode != 0:
    raise SystemExit(
        f"Body 4 lifecycle cut failed ({process.returncode}): "
        + stderr.decode(errors="replace")
        + stdout.decode(errors="replace")
    )
result = json.loads(payload)
required = {
    "first-install",
    "historical-label-absent-launchd-install",
    "previous-release-absent-launchd-repair",
    "dead-coordination-readiness-rollback",
    "foreign-dead-coordination-refusal",
    "dead-coordination-preview-race-refusal",
    "staged-only-coordination-uninstall",
    "staged-uninstall-interruption-recovery",
    "paired-staged-coordination-uninstall",
    "foreign-staged-uninstall-refusal",
    "malformed-staged-uninstall-refusal",
    "wrong-mode-staged-uninstall-refusal",
    "hardlinked-staged-uninstall-refusal",
    "symlinked-staged-uninstall-refusal",
    "live-staged-uninstall-refusal",
    "unpaired-staged-uninstall-refusal",
    "raced-staged-uninstall-refusal",
    "same-source-no-op",
    "launch-failure-rollback",
    "verified-uninstall-durable-state",
}
if result.get("schema") != "shadow-sync-m6-lifecycle-result/v1":
    raise SystemExit(f"unexpected lifecycle result: {result}")
if not required.issubset(set(result.get("passed", []))):
    raise SystemExit(f"missing lifecycle evidence: {result}")
if any("/bin/launchctl" in item or "gui/" in item
       for item in result["launchctlInvocations"]):
    raise SystemExit("lifecycle cut entered a live launchctl domain")
print(
    "v2-body4-acceptance: lifecycle-preservation=passed "
    f"checks={len(result['passed'])} live-launchctl=never"
)
PY

PRODUCTION_SOURCES=(
  "$CAPABILITY/Sources/ShadowSyncCore/FastForwardTransactionV2.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/GitSafety.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/ProcessRunner.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryModelV2.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryPolicy.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RunLog.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/ProcessOwnership.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/InstallationLifecycle.swift"
  "$CAPABILITY/Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
  "$CAPABILITY/Sources/ShadowSyncApp/LifecycleMain.swift"
)
if grep -E \
  '"(checkout|switch|reset|stash|clean)"[[:space:]]*[,)]|"branch"[[:space:]]*,[[:space:]]*"-(d|D)"|"update-ref"[[:space:]]*,[[:space:]]*"-d"|"remote"[[:space:]]*,[[:space:]]*"(remove|set-head)"' \
  "${PRODUCTION_SOURCES[@]}"; then
  printf 'v2-body4-acceptance: forbidden branch/worktree grammar found\n' >&2
  exit 1
fi
if grep -E 'Process[[:space:]]*\(|/bin/(sh|bash|zsh)' \
  "$CAPABILITY/Sources/ShadowSyncCore/FastForwardTransactionV2.swift" \
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift" \
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryPolicy.swift" \
  "$CAPABILITY/Sources/ShadowSyncCore/RunLog.swift"; then
  printf 'v2-body4-acceptance: arbitrary executable path entered Body 4 core\n' >&2
  exit 1
fi
grep -Fq 'LegacyRunPresentation.isLegacy(report)' \
  "$CAPABILITY/Sources/ShadowSyncApp/RunPresentation.swift"
grep -Fq 'LegacyRunPresentation.label' \
  "$CAPABILITY/Sources/ShadowSyncApp/RunPresentation.swift"
if grep -E '\.package[[:space:]]*\(' "$CAPABILITY/Package.swift"; then
  printf 'v2-body4-acceptance: third-party dependency found\n' >&2
  exit 1
fi

DOCTOR_HOME="$SCRATCH/doctor-home"
STATE="$DOCTOR_HOME/.local/state/shadow-sync"
mkdir -m 700 "$DOCTOR_HOME"
mkdir -m 700 "$DOCTOR_HOME/.local"
mkdir -m 700 "$DOCTOR_HOME/.local/state"
mkdir -m 700 "$STATE"
mkdir -m 700 "$STATE/retention"
mkdir -m 700 "$STATE/retention/ret-body4-fixture"
cp "$LOG_FIXTURE" "$STATE/latest.log"
chmod 600 "$STATE/latest.log"
cat >"$STATE/repository-authorities.json" <<'JSON'
{"records":[],"revision":1,"schema":"shadow-sync-repository-authorities/v1"}
JSON
chmod 600 "$STATE/repository-authorities.json"
python3 - "$STATE/retention/ret-body4-fixture/manifest.json" <<'PY'
import hashlib
import json
import os
import sys

tip = "a" * 40
bundle = b"Body 4 protected branch bundle fixture\n"
bundle_path = os.path.join(
    os.path.dirname(sys.argv[1]),
    "branch.bundle",
)
with open(bundle_path, "xb") as stream:
    stream.write(bundle)
os.chmod(bundle_path, 0o400)
value = {
    "artifactID": "ret-body4-fixture",
    "branchRef": "refs/heads/evidence",
    "cloneID": "clone:body4",
    "commonDirectoryIdentity": {"device": 1, "inode": 1},
    "componentSHA256": {
        "branch.bundle": hashlib.sha256(bundle).hexdigest(),
    },
    "createdAt": "2026-09-01T00:00:00.000Z",
    "entries": [],
    "excludedPaths": [],
    "includedPaths": [],
    "indexSHA256": None,
    "objectFormat": "sha1",
    "possibleSecretsAuthorized": True,
    "registrationIdentity": None,
    "repositoryID": "owner/legacy-repo",
    "restoreInstructions": ["Readable evidence only; no automatic restore."],
    "restoreProof": {
        "bundleVerified": True,
        "connectivityVerified": True,
        "entryManifestVerified": True,
        "exactTipOID": tip,
        "indexVerified": True,
        "statusDigestVerified": True,
        "verifiedAt": "2026-09-01T00:00:00.000Z",
    },
    "schema": "shadow-sync-retention/v2",
    "secretShapedPaths": [],
    "sharedIndexFiles": {},
    "statusSHA256": None,
    "tipOID": tip,
    "worktreeID": None,
    "worktreeRootIdentity": None,
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(value, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
chmod 400 "$STATE/retention/ret-body4-fixture/manifest.json"
mkdir -m 700 "$DOCTOR_HOME/Applications"
mkdir -m 700 "$DOCTOR_HOME/Library"
mkdir -m 700 "$DOCTOR_HOME/Library/LaunchAgents"
cat >"$SCRATCH/absent-launchctl" <<'SH'
#!/bin/sh
printf 'Could not find service\n' >&2
exit 113
SH
chmod 700 "$SCRATCH/absent-launchctl"
"$CAPABILITY/scripts/source-doctor.sh" \
  --home "$DOCTOR_HOME" --launchctl "$SCRATCH/absent-launchctl"
doctor_must_refuse() {
  local label="$1"
  if "$CAPABILITY/scripts/source-doctor.sh" \
      --home "$DOCTOR_HOME" --launchctl "$SCRATCH/absent-launchctl" \
      >/dev/null 2>&1; then
    printf 'v2-body4-acceptance: doctor accepted %s\n' "$label" >&2
    exit 1
  fi
}
cp "$STATE/latest.log" "$SCRATCH/latest.valid"
python3 - "$SCRATCH/latest.valid" "$SCRATCH" <<'PY'
import json
import os
import sys

source, destination = sys.argv[1:]
variants = [
    "other/legacy-repo",
    "owner/other",
    "owner/legacy-repo/extra",
    "/owner/legacy-repo",
    "owner//legacy-repo",
    "owner/./legacy-repo",
    "owner/../legacy-repo",
    r"owner\legacy-repo",
    "owner%2Flegacy-repo",
    "owner%5Clegacy-repo",
    "owner/legacy-repo\x00",
    " owner/legacy-repo",
    "owner/legacy-repo ",
]
with open(source, "rb") as stream:
    records = [json.loads(line) for line in stream if line.strip()]
for index, display in enumerate(variants):
    changed = json.loads(json.dumps(records))
    changed[0]["intent"]["candidates"][0]["displayName"] = display
    changed[2]["report"]["results"][0]["repository"]["displayName"] = display
    path = os.path.join(destination, f"display-label-negative-{index:02d}.log")
    with open(path, "w", encoding="utf-8") as stream:
        for record in changed:
            stream.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
            stream.write("\n")
PY
for variant in "$SCRATCH"/display-label-negative-*.log; do
  cp "$variant" "$STATE/latest.log"
  chmod 600 "$STATE/latest.log"
  before_variant="$(shasum -a 256 "$STATE/latest.log" | awk '{print $1}')"
  doctor_must_refuse "an unsafe historical display label"
  after_variant="$(shasum -a 256 "$STATE/latest.log" | awk '{print $1}')"
  [ "$before_variant" = "$after_variant" ] \
    || { printf 'v2-body4-acceptance: doctor rewrote refused log\n' >&2; exit 1; }
done
cp "$SCRATCH/latest.valid" "$STATE/latest.log"
chmod 600 "$STATE/latest.log"
ln "$STATE/latest.log" "$SCRATCH/latest-hardlink"
doctor_must_refuse "a hardlinked latest.log"
rm "$SCRATCH/latest-hardlink"
cp "$STATE/repository-authorities.json" "$SCRATCH/authority.valid"
python3 - "$STATE/repository-authorities.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    value = json.load(stream)
value["futureField"] = True
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(value, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
chmod 600 "$STATE/repository-authorities.json"
doctor_must_refuse "a newer authority record"
if PYTHONOPTIMIZE=1 "$CAPABILITY/scripts/source-doctor.sh" \
    --home "$DOCTOR_HOME" --launchctl "$SCRATCH/absent-launchctl" \
    >/dev/null 2>&1; then
  printf 'v2-body4-acceptance: optimized Python bypassed doctor validation\n' >&2
  exit 1
fi
cp "$SCRATCH/authority.valid" "$STATE/repository-authorities.json"
chmod 600 "$STATE/repository-authorities.json"
MANIFEST="$STATE/retention/ret-body4-fixture/manifest.json"
chmod 600 "$MANIFEST"
cp "$MANIFEST" "$SCRATCH/manifest.valid"
doctor_must_refuse "a wrong-mode retention artifact"
cp "$SCRATCH/manifest.valid" "$MANIFEST"
chmod 600 "$MANIFEST"
python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    value = json.load(stream)
value["futureField"] = True
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(value, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
chmod 400 "$MANIFEST"
doctor_must_refuse "a newer retention artifact"
chmod 600 "$MANIFEST"
cp "$SCRATCH/manifest.valid" "$MANIFEST"
chmod 400 "$MANIFEST"
BUNDLE="$STATE/retention/ret-body4-fixture/branch.bundle"
mv "$BUNDLE" "$SCRATCH/branch.bundle"
doctor_must_refuse "a missing retention payload"
mv "$SCRATCH/branch.bundle" "$BUNDLE"
chmod 400 "$BUNDLE"
python3 - "$STATE/latest.log" <<'PY'
import os
import sys
with open(sys.argv[1], "r+b") as stream:
    stream.truncate(max(0, os.fstat(stream.fileno()).st_size - 1))
PY
doctor_must_refuse "a partial legacy log"
cp "$SCRATCH/latest.valid" "$STATE/latest.log"
chmod 600 "$STATE/latest.log"
cat >"$STATE/latest.log" <<'JSON'
{"detail":"Immutable selected operation plan recorded.","phase":"Queued","plan":{"createdAt":"2026-09-01T00:00:00.000Z","nodes":[{"commonDirectoryKey":"clone:body4","dependencies":[],"id":"body3-node:body4-doctor","kind":"policyInvalidation","payload":{"policyInvalidation":{"repositoryID":"owner/legacy-repo"}},"repositoryID":"owner/legacy-repo","requiresExclusiveWorkerPool":true}],"policyEvidenceDigest":"body4-policy","run":"11111111-1111-4111-8111-111111111111","schema":"shadow-sync-batch-plan/v2"},"run":"11111111-1111-4111-8111-111111111111","schema":"shadow-sync-log/v2","sequence":1,"technicalDetail":"[REDACTED PATH] TOKEN=[REDACTED]","timestamp":"2026-09-01T00:00:00.000Z","type":"plan"}
JSON
"$CAPABILITY/scripts/source-doctor.sh" \
  --home "$DOCTOR_HOME" --launchctl "$SCRATCH/absent-launchctl" \
  >/dev/null
python3 - "$STATE/latest.log" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    value = json.load(stream)
value["technicalDetail"] = "token=private"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(value, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
doctor_must_refuse "unredacted v2 token detail"
python3 - "$STATE/latest.log" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    value = json.load(stream)
value["technicalDetail"] = "/" + "Users/operator/private"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(value, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
doctor_must_refuse "unredacted v2 path detail"
cat >"$STATE/latest.log" <<'JSON'
{"detail":"Immutable selected operation plan recorded.","phase":"Queued","plan":{"createdAt":"2026-09-01T00:00:00.000Z","nodes":[{"commonDirectoryKey":"clone:body4","dependencies":[],"id":"body3-node:body4-doctor","kind":"policyInvalidation","payload":{"policyInvalidation":{"repositoryID":"owner/legacy-repo"}},"repositoryID":"owner/legacy-repo","requiresExclusiveWorkerPool":true}],"policyEvidenceDigest":"body4-policy","run":"11111111-1111-4111-8111-111111111111","schema":"shadow-sync-batch-plan/v2"},"run":"11111111-1111-4111-8111-111111111111","schema":"shadow-sync-log/v2","sequence":1,"timestamp":"2026-09-01T00:00:00.000Z","type":"plan"}
{"detail":"Run finished.","report":{"cancelled":false,"endedAt":"2026-09-01T00:00:03.000Z","paused":false,"repositoryCounts":{"owner/legacy-repo":1},"results":[{"detail":"Completed safely.","durationMilliseconds":900,"endedAt":"2026-09-01T00:00:02.000Z","node":{"commonDirectoryKey":"clone:body4","dependencies":[],"id":"body3-node:body4-doctor","kind":"policyInvalidation","payload":{"policyInvalidation":{"repositoryID":"owner/legacy-repo"}},"repositoryID":"owner/legacy-repo","requiresExclusiveWorkerPool":true},"startedAt":"2026-09-01T00:00:01.000Z","status":"succeeded","worker":1}],"run":"11111111-1111-4111-8111-111111111111","schema":"shadow-sync-batch-report/v2","startedAt":"2026-09-01T00:00:01.000Z"},"run":"11111111-1111-4111-8111-111111111111","schema":"shadow-sync-log/v2","sequence":2,"timestamp":"2026-09-01T00:00:03.000Z","type":"run_finished"}
JSON
chmod 600 "$STATE/latest.log"
"$CAPABILITY/scripts/source-doctor.sh" \
  --home "$DOCTOR_HOME" --launchctl "$SCRATCH/absent-launchctl" \
  >/dev/null
cp "$STATE/latest.log" "$SCRATCH/v2-report.valid"
python3 - "$SCRATCH/v2-report.valid" "$SCRATCH" <<'PY'
import json
import os
import sys

source, destination = sys.argv[1:]
with open(source, "r", encoding="utf-8") as stream:
    records = [json.loads(line) for line in stream if line.strip()]
variants = {}
timing = json.loads(json.dumps(records))
timing[1]["report"]["results"][0]["endedAt"] = \
    "2026-08-31T23:59:59.000Z"
variants["contradictory-timing"] = timing
totals = json.loads(json.dumps(records))
totals[1]["report"]["repositoryCounts"]["owner/legacy-repo"] = 2
variants["forged-repository-totals"] = totals
detail = json.loads(json.dumps(records))
detail[1]["report"]["results"][0]["technicalDetail"] = "token=private"
variants["unredacted-nested-detail"] = detail
for label, changed in variants.items():
    path = os.path.join(destination, f"v2-report-{label}.log")
    with open(path, "w", encoding="utf-8") as stream:
        for record in changed:
            stream.write(json.dumps(
                record,
                sort_keys=True,
                separators=(",", ":"),
            ))
            stream.write("\n")
PY
for variant in "$SCRATCH"/v2-report-*.log; do
  cp "$variant" "$STATE/latest.log"
  chmod 600 "$STATE/latest.log"
  before_variant="$(shasum -a 256 "$STATE/latest.log" | awk '{print $1}')"
  doctor_must_refuse "$(basename "$variant" .log)"
  after_variant="$(shasum -a 256 "$STATE/latest.log" | awk '{print $1}')"
  [ "$before_variant" = "$after_variant" ] \
    || { printf 'v2-body4-acceptance: doctor rewrote refused v2 report\n' >&2; exit 1; }
done
cat >"$STATE/latest.log" <<'JSON'
{"plan":{},"run":"11111111-1111-4111-8111-111111111111","schema":"shadow-sync-log/v2","sequence":1,"timestamp":"2026-09-01T00:00:00.000Z","type":"plan"}
JSON
doctor_must_refuse "an incomplete v2 plan"
cp "$SCRATCH/latest.valid" "$STATE/latest.log"
chmod 600 "$STATE/latest.log"
mkdir -m 700 "$STATE/retention/.incomplete-ret-body4-cut"
doctor_must_refuse "incomplete retention"
rmdir "$STATE/retention/.incomplete-ret-body4-cut"
"$CAPABILITY/scripts/source-doctor.sh" \
  --home "$DOCTOR_HOME" --launchctl "$SCRATCH/absent-launchctl" \
  >/dev/null

bash -n "$CAPABILITY/scripts/v2-body4-acceptance.sh"
bash -n "$CAPABILITY/scripts/source-doctor.sh"
printf 'v2-body4-acceptance: production, command, fixture, and doctor audits passed\n'
