#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$CAPABILITY"
. "$CAPABILITY/scripts/owned-cleanup.sh"
if [ "${1:-}" = "--portable-source-contract" ] && [ "$#" -eq 1 ]; then
  for script in \
    install.sh scripts/build-app.sh scripts/owned-cleanup.sh \
    scripts/m1-core-tests.sh scripts/m1-native-e2e.sh \
    scripts/v2-body1-acceptance.sh scripts/v2-body2-acceptance.sh \
    scripts/v2-body4-acceptance.sh scripts/v3-preflight-acceptance.sh \
    scripts/v4-preflight-acceptance.sh scripts/verify-m1.sh \
    scripts/verify-m5.sh scripts/verify-m6.sh \
    scripts/beta-v0.1-native-smoke.sh \
    scripts/beta-v0.2-native-smoke.sh \
    scripts/verify-beta-v0.2.sh \
    scripts/verify-beta-v0.6.sh \
    scripts/verify-beta-v0.7.sh; do
    bash -n "$CAPABILITY/$script"
  done
  python3 - "$CAPABILITY" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys

capability = Path(sys.argv[1])
expected = {
    "Resources/ShadowSyncIcon-1024.png":
        "bec4636abe7ada114c61897e6b7f66181b13ec93438d37b8213d5061ab13bd90",
    "Resources/ShadowSync.icns":
        "e27b55fc793f25867793f1ca9000e2454d448329169ade1b89e4beb3950444cc",
}
for relative, digest in expected.items():
    observed = sha256((capability / relative).read_bytes()).hexdigest()
    if observed != digest:
        raise SystemExit(f"portable contract digest drift: {relative}")

package = (capability / "Package.swift").read_text(encoding="utf-8")
if (
    "// swift-tools-version: 6.2" not in package
    or '.macOS("26.0")' not in package
    or ".package(" in package
    or '"ShadowSyncCatalog"' not in package
    or '"ShadowSyncSelfTest"' not in package
):
    raise SystemExit("portable package contract audit failed")

catalog = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted((capability / "Sources/ShadowSyncCatalog").glob("*.swift"))
)
for forbidden in (
    "Foundation.Process", "URLSession", "NWConnection",
    "RunAuthority", "RepositoryInventoryDiscovery",
):
    if forbidden in catalog:
        raise SystemExit(f"portable catalog boundary audit failed: {forbidden}")

router = (
    capability / "Sources/ShadowSyncApp/AppLifecycleRouter.swift"
).read_text(encoding="utf-8")
delegate = (
    capability / "Sources/ShadowSyncApp/AppDelegate.swift"
).read_text(encoding="utf-8")
for required in (
    "SelectedHydrationDrainTracker",
    "hydrationDrainEvidenceExact",
    "preferenceOutcomeRecorded",
    "allChildrenReaped",
    "inventoryAuthorityReleased",
):
    if required not in router:
        raise SystemExit(f"portable lifecycle audit missing: {required}")
continue_start = delegate.index("private func continueRepositorySelection(")
work_start = delegate.index(
    "let executablePath = self.executablePath", continue_start
)
continue_admission = delegate[continue_start:work_start]
for required in (
    "RepositorySelectionIntent", "settleHydrationFailure",
    "reopenAdmission",
):
    if required not in continue_admission:
        raise SystemExit(f"portable Continue recovery audit missing: {required}")
if "Task { @MainActor [weak self] in\n                        self?.accept" in delegate:
    raise SystemExit("portable worker callback ordering audit failed")

notice = (capability / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
for required in (
    "Lucide", "git-pull-request-draft", "1.47.0",
    "3b9ea6d08707edc439f25a4c354cb0d6b8bee973", "ISC License",
):
    if required not in notice:
        raise SystemExit(f"portable icon provenance audit missing: {required}")

core = capability / "Sources/ShadowSyncCore"
models = (core / "Models.swift").read_text(encoding="utf-8")
if (
    "public enum ChildProcessBudget" not in models
    or "#else\n        configured\n        #endif" not in models
):
    raise SystemExit("portable child budget audit: release path changed")
for relative, required in (
    ("ProcessRunner.swift", "ChildProcessBudget.seconds(request.timeoutSeconds)"),
    ("ProcessRunner.swift", "ChildProcessBudget.seconds(10)"),
    ("DiscoveryGitProbe.swift", "seconds: ChildProcessBudget.seconds("),
    ("GitSafety.swift", "ChildProcessBudget.seconds(5)"),
    ("ClosedProcessRunner.swift", "ChildProcessBudget.seconds(timeout)"),
):
    if required not in (core / relative).read_text(encoding="utf-8"):
        raise SystemExit(
            f"portable child budget audit missing: {relative}: {required}"
        )
PY
  printf 'v3-preflight-acceptance: portable-source-contract PASS (macOS runtime acceptance remains separate)\n'
  exit 0
elif [ "$#" -ne 0 ]; then
  printf 'usage: %s [--portable-source-contract]\n' "$0" >&2
  exit 2
fi
SCRATCH="$(mktemp -d /private/tmp/shadow-sync-v3-preflight.XXXXXX)"
export SWIFTPM_MODULECACHE_OVERRIDE="$SCRATCH/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-module-cache"

cleanup() {
  local status="$1"
  trap - EXIT INT TERM
  shadow_sync_reap_owned_root_helpers "$SCRATCH" v3-preflight-acceptance || status=1
  shadow_sync_remove_owned_root "$SCRATCH" v3-preflight-acceptance || status=1
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TEST_BUILD=(
  --package-path "$CAPABILITY"
  --scratch-path "$SCRATCH/testing"
  --disable-index-store
  -Xswiftc -DSHADOW_SYNC_TESTING
)
swift build "${TEST_BUILD[@]}" --product ShadowSync
swift build "${TEST_BUILD[@]}" --product ShadowSyncSelfTest
TEST_BIN="$(swift build "${TEST_BUILD[@]}" --show-bin-path)"
APP="$TEST_BIN/ShadowSync"
SELF_TEST="$TEST_BIN/ShadowSyncSelfTest"

run_focused() {
  local id="$1" selector="$2"
  "$SELF_TEST" --app-executable "$APP" "$selector" |
    tee "$SCRATCH/$id.log"
}

run_focused DM3-T01 --dm3-t01-only
run_focused DM3-T02 --dm3-t02-only
run_focused DM3-T03 --dm3-t03-only
run_focused DM3-T04 --dm3-t04-only
run_focused DM3-T05 --dm3-t05-only
run_focused DM3-T06 --dm3-t06-only
run_focused DM3-T07 --dm3-t07-only
run_focused DM3-T08 --dm3-t08-only
run_focused DM3-T09 --dm3-t09-only
run_focused DM3-T10 --dm3-t10-only
run_focused DM3-T11 --dm3-t11-only
run_focused DM3-T12 --dm3-t12-only
run_focused DM3-T13 --dm3-t13-only
run_focused DM3-T14 --dm3-t14-only
run_focused DM3-T15 --dm3-t15-only

/usr/bin/grep -E \
  '^METRIC first-screen trials=20 .*git_children=0 gh_children=0 .*network_attempts=0 authority_acquisitions=0$' \
  "$SCRATCH/DM3-T14.log" >/dev/null

python3 - "$APP" "$SCRATCH/chooser-probe.json" <<'PY'
import json
import os
import select
import socket
import subprocess
import sys
import time

executable, output = sys.argv[1:]
# Each wait ends on the probe's newline-terminated message or EOF; the
# limits below only bound a hung probe on a loaded or swapping host.
GUARD_SECONDS = 120
parent, child = socket.socketpair()
process = subprocess.Popen(
    [
        "/usr/bin/sandbox-exec",
        "-p",
        "(version 1) (allow default) (deny network*)",
        executable,
        "--shadow-sync-v3-chooser-probe-channel",
        str(child.fileno()),
    ],
    pass_fds=(child.fileno(),),
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
child.close()
parent.sendall(
    json.dumps(
        {"schema": "shadow-sync-v3-chooser-probe/v1"},
        separators=(",", ":"),
    ).encode()
    + b"\n"
)
ready_payload = b""
observed_descendants = set()
deadline = time.monotonic() + GUARD_SECONDS
while not ready_payload.endswith(b"\n") and time.monotonic() < deadline:
    rows = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,ppid=,command="],
        text=True,
    ).splitlines()
    parents = {}
    for row in rows:
        fields = row.strip().split(None, 2)
        if len(fields) >= 2:
            parents[int(fields[0])] = int(fields[1])
    changed = True
    descendants = {process.pid}
    while changed:
        changed = False
        for pid, ppid in parents.items():
            if ppid in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    observed_descendants.update(descendants - {process.pid})
    ready, _, _ = select.select([parent], [], [], 0.005)
    if ready:
        block = parent.recv(65536)
        if not block:
            break
        ready_payload += block
if not ready_payload.endswith(b"\n"):
    process.terminate()
    _, stderr = process.communicate(timeout=2)
    raise SystemExit(
        "v3 chooser probe did not publish ready state: "
        + stderr.decode(errors="replace")
    )
ready_line, payload = ready_payload.split(b"\n", 1)
ready_result = json.loads(ready_line)
assert (
    ready_result["schema"]
    == "shadow-sync-v3-chooser-ready/v1"
), ready_result
if observed_descendants:
    process.terminate()
    process.wait(timeout=2)
    raise SystemExit(
        "v3 chooser probe admitted pre-Continue descendants: "
        + ",".join(map(str, sorted(observed_descendants)))
    )
parent.sendall(
    json.dumps(
        {"schema": "shadow-sync-v3-chooser-continue/v1"},
        separators=(",", ":"),
    ).encode()
    + b"\n"
)
parent.shutdown(socket.SHUT_WR)
deadline = time.monotonic() + GUARD_SECONDS
while not payload.endswith(b"\n") and time.monotonic() < deadline:
    ready, _, _ = select.select([parent], [], [], 0.01)
    if ready:
        block = parent.recv(65536)
        if not block:
            break
        payload += block
parent.close()
try:
    stdout, stderr = process.communicate(timeout=GUARD_SECONDS)
except subprocess.TimeoutExpired:
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
    raise SystemExit("v3 chooser probe timed out")
if process.returncode != 0:
    raise SystemExit(
        "v3 chooser probe failed: "
        + stderr.decode(errors="replace")
        + stdout.decode(errors="replace")
    )
result = json.loads(payload)
assert result["schema"] == "shadow-sync-v3-chooser-probe-result/v1", result
assert result["trials"] == 20, result
assert result["allRowsEnabledWithinOneSecond"] is True, result
for key in [
    "gitChildren",
    "ghChildren",
    "helperChildren",
    "otherChildren",
    "networkAttempts",
    "authorityAcquisitions",
]:
    assert result[key] == 0, (key, result)
assert result["firstChildStrictlyAfterContinue"] is True, result
assert (
    result["firstChildNanoseconds"]
    > result["continueNanoseconds"]
), result
assert result["childReaped"] is True, result
assert result["progressAndCancellationVisible"] is True, result
assert result["recoverySheetCancelClosesChooser"] is True, result
with open(output, "w", encoding="utf-8") as handle:
    json.dump(result, handle, sort_keys=True)
    handle.write("\n")
print(
    "METRIC app-first-screen trials=20 "
    f"p50_ms={result['p50Nanoseconds']/1_000_000:.3f} "
    f"p95_ms={result['p95Nanoseconds']/1_000_000:.3f} "
    f"max_ms={result['maximumNanoseconds']/1_000_000:.3f} "
    "pre_continue_descendants=0 network_attempts=0 "
    "authority_acquisitions=0 first_child_after_continue=1 "
    "child_reaped=1"
)
PY

python3 - "$APP" <<'PY'
import json
import socket
import subprocess
import sys

executable = sys.argv[1]
parent, child = socket.socketpair()
process = subprocess.Popen(
    [
        executable,
        "--shadow-sync-v3-lifecycle-probe-channel",
        str(child.fileno()),
    ],
    pass_fds=(child.fileno(),),
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
child.close()
parent.sendall(
    b'{"schema":"shadow-sync-v3-lifecycle-probe/v1"}\n'
)
parent.shutdown(socket.SHUT_WR)
payload = b""
while not payload.endswith(b"\n"):
    block = parent.recv(65536)
    if not block:
        break
    payload += block
parent.close()
stdout, stderr = process.communicate(timeout=120)
if process.returncode != 0:
    raise SystemExit(
        "v3 lifecycle probe failed: "
        + stderr.decode(errors="replace")
        + stdout.decode(errors="replace")
    )
result = json.loads(payload)
assert result == {
    "schema": "shadow-sync-v3-lifecycle-probe-result/v1",
    "independentDrainCuts": 12,
    "saveLinearizationBeforeQuit": True,
    "saveFailureOutcomeBeforeQuit": True,
    "staleCallbackIgnored": True,
    "doubleAdmissionRejected": True,
    "continueIntentFailureRecovered": True,
    "hydrationDrainEvidenceExact": True,
    "exactlyOnceTermination": True,
}, result
print(
    "PASS lifecycle-router drain_cuts=12 "
    "save_order=1 save_failure_outcome=1 stale_ignored=1 "
    "double_admission=0 intent_failure_recovered=1 "
    "hydration_drain_evidence=1 "
    "termination_count=1"
)
PY

PROD_BUILD=(
  --package-path "$CAPABILITY"
  --scratch-path "$SCRATCH/production"
  --disable-index-store
)
swift build "${PROD_BUILD[@]}" --product ShadowSync
PROD_BIN="$(swift build "${PROD_BUILD[@]}" --show-bin-path)"
PRODUCTION_BINARY="$PROD_BIN/ShadowSync"

/bin/cp \
  "$CAPABILITY/Tests/Fixtures/V3Negative/NoCapability.swift.fixture" \
  "$SCRATCH/no-capability.swift"
if /usr/bin/xcrun swiftc -typecheck -swift-version 6 \
    -I "$PROD_BIN" \
    "$SCRATCH/no-capability.swift" \
    >"$SCRATCH/no-capability.stdout" \
    2>"$SCRATCH/no-capability.stderr"; then
  printf 'v3-preflight-acceptance: capability-free constructors compiled\n' >&2
  exit 1
fi
[ "$(/usr/bin/grep -c "missing argument for parameter 'capability'" \
  "$SCRATCH/no-capability.stderr")" -ge 5 ] || {
  /bin/cat "$SCRATCH/no-capability.stderr" >&2
  printf 'v3-preflight-acceptance: capability negative compile was inconclusive\n' >&2
  exit 1
}

swift package \
  --package-path "$CAPABILITY" \
  --scratch-path "$SCRATCH/package-audit" \
  dump-package \
  >"$SCRATCH/package.json"
python3 - "$SCRATCH/package.json" <<'PY'
import json
import sys

package = json.load(open(sys.argv[1], encoding="utf-8"))
targets = {target["name"]: target for target in package["targets"]}
catalog = targets["ShadowSyncCatalog"]
if catalog.get("dependencies"):
    raise SystemExit("ShadowSyncCatalog must have no target dependencies")
core_dependencies = {
    dependency.get("byName", [None])[0]
    for dependency in targets["ShadowSyncCore"]["dependencies"]
}
if "ShadowSyncCatalog" not in core_dependencies:
    raise SystemExit("ShadowSyncCore must depend on ShadowSyncCatalog")
PY

CATALOG_OBJECTS=()
while IFS= read -r object; do
  CATALOG_OBJECTS+=("$object")
done < <(
  /usr/bin/find "$SCRATCH/production" -type f \
    -path '*/ShadowSyncCatalog*.build/*' -name '*.o' -print
)
[ "${#CATALOG_OBJECTS[@]}" -gt 0 ] || {
  printf 'v3-preflight-acceptance: catalog objects are missing\n' >&2
  exit 1
}
/usr/bin/nm -u "${CATALOG_OBJECTS[@]}" >"$SCRATCH/catalog-undefined.txt"
if /usr/bin/grep -E \
  '(_posix_spawn|_fork|_exec|_system|URLSession|NSURLSession|libcurl|curl_easy|RunAuthority|RepositoryInventory)' \
  "$SCRATCH/catalog-undefined.txt"; then
  printf 'v3-preflight-acceptance: catalog imports forbidden capability\n' >&2
  exit 1
fi

/usr/bin/nm -gj "$PRODUCTION_BINARY" |
  /usr/bin/xcrun swift-demangle >"$SCRATCH/production-symbols.txt"
if /usr/bin/grep -E \
  'SHADOW_SYNC_TESTING|DM3PreflightSelfTests|--dm3-t|--v3-preflight|RepositoryDiscovery\.discover\(\)|RepositoryInventoryDiscovery\.discoverInventory\(\)' \
  "$SCRATCH/production-symbols.txt"; then
  printf 'v3-preflight-acceptance: production binary exposes a test or broad route\n' >&2
  exit 1
fi
if /usr/bin/strings "$PRODUCTION_BINARY" |
    /usr/bin/grep -E -- '--dm3-t|--v3-preflight'; then
  printf 'v3-preflight-acceptance: production binary contains a v3 test selector\n' >&2
  exit 1
fi

if /usr/bin/nm -u "$PRODUCTION_BINARY" |
    /usr/bin/grep -E 'URLSession|NSURLSession|libcurl|curl_easy|curl_multi'; then
  printf 'v3-preflight-acceptance: unapproved network client found\n' >&2
  exit 1
fi

if /usr/bin/grep -R -n -E \
    '([T]ODO|[F]IXME|fatalError\("[t]est|preconditionFailure\("[t]est)' \
    "$CAPABILITY/Sources" "$CAPABILITY/scripts"; then
  printf 'v3-preflight-acceptance: unresolved production placeholder found\n' >&2
  exit 1
fi

printf 'PASS DM3-T16 production-governance\n'
printf 'v3-preflight-acceptance: PASS\n'
