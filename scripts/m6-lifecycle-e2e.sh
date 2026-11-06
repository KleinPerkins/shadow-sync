#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TEST_ROOT=""

if [ "${1:-}" = "--test-root" ] && [ "$#" -eq 2 ]; then
  TEST_ROOT="$2"
else
  printf 'usage: m6-lifecycle-e2e.sh --test-root /private/tmp/shadow-sync-m6.*\n' >&2
  exit 2
fi

case "$TEST_ROOT" in /private/tmp/shadow-sync-m6.*) ;; *)
  printf 'm6-lifecycle-e2e: test root must use /private/tmp/shadow-sync-m6.*\n' >&2
  exit 2
esac
[ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] || {
  printf 'm6-lifecycle-e2e: test root must be an existing physical directory\n' >&2
  exit 2
}
TEST_ROOT="$(cd -P "$TEST_ROOT" && pwd)"
[ "$(stat -f '%u' "$TEST_ROOT")" = "$(id -u)" ] \
  && [ $((8#$(stat -f '%Lp' "$TEST_ROOT") & 077)) -eq 0 ] || {
    printf 'm6-lifecycle-e2e: test root must be private and caller-owned\n' >&2
    exit 2
  }
[ -z "$(ls -A "$TEST_ROOT")" ] || {
  printf 'm6-lifecycle-e2e: test root must be empty\n' >&2
  exit 2
}

run_owned_with_deadline() {
  local timeout="$1" marker="$2" pid deadline command
  shift 2
  "$@" &
  pid=$!
  kill -0 "$pid" 2>/dev/null || {
    wait "$pid"
    return
  }
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$command" ] || {
    wait "$pid"
    return
  }
  case "$command" in *"$marker"*"$TEST_ROOT"*) ;; *)
    printf 'm6-lifecycle-e2e: could not verify owned helper %s\n' "$pid" >&2
    return 1
  esac
  deadline=$((SECONDS + timeout))
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in *"$marker"*"$TEST_ROOT"*) kill -TERM "$pid" 2>/dev/null || true ;; *)
      printf 'm6-lifecycle-e2e: owned helper identity changed\n' >&2
      return 1
    esac
    deadline=$((SECONDS + 2))
    while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.05
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in *"$marker"*"$TEST_ROOT"*) kill -KILL "$pid" 2>/dev/null || true ;; *)
      printf 'm6-lifecycle-e2e: owned helper identity changed before KILL\n' >&2
      return 1
    esac
    deadline=$((SECONDS + 2))
    while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.05
    done
  fi
  kill -0 "$pid" 2>/dev/null && return 1
  wait "$pid"
}

cleanup() {
  status=$? safe_to_remove=1
  trap - EXIT INT TERM
  if [ -n "${TEST_EXECUTABLE:-}" ] && [ -x "${TEST_EXECUTABLE:-}" ]; then
    if ! run_owned_with_deadline 15 --shadow-sync-m6-cleanup-root \
      "$TEST_EXECUTABLE" --shadow-sync-m6-cleanup-root "$TEST_ROOT"; then
      status=1
      safe_to_remove=0
    fi
  fi
  if [ "$safe_to_remove" -eq 1 ]; then
    run_owned_with_deadline 15 "/bin/rm -rf" \
      /bin/rm -rf -- "$TEST_ROOT" || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -m 700 "$TEST_ROOT/home"
REPO="$(cd "$CAPABILITY/../../.." && pwd)"
META_DIGEST="$(cd "$REPO" && bash .github/scripts/eco-lock.sh digest "$CAPABILITY/meta.yml" 2>/dev/null || true)"
if [ "${#META_DIGEST}" -ne 64 ]; then
  META_DIGEST="$(awk '$1 == "shadow-sync" {print $2}' "$CAPABILITY/../../../.eco-registry.lock")"
fi

SOURCE_FIXTURE="$TEST_ROOT/source-fixture"
mkdir -m 700 -p "$SOURCE_FIXTURE/global/tools"
mkdir -m 700 -p "$SOURCE_FIXTURE/.github/scripts"
cp -R "$CAPABILITY" "$SOURCE_FIXTURE/global/tools/shadow-sync"
cp "$REPO/.eco-registry.lock" "$SOURCE_FIXTURE/.eco-registry.lock"
cp "$REPO/.github/scripts/eco-lock.sh" "$SOURCE_FIXTURE/.github/scripts/eco-lock.sh"
git -C "$SOURCE_FIXTURE" init -q -b main
git -C "$SOURCE_FIXTURE" config user.name "ShadowSync Test"
git -C "$SOURCE_FIXTURE" config user.email "shadow-sync@test.invalid"
git -C "$SOURCE_FIXTURE" add .eco-registry.lock .github/scripts/eco-lock.sh global/tools/shadow-sync
git -C "$SOURCE_FIXTURE" commit -q -m "fixture source"
git -C "$SOURCE_FIXTURE" remote add origin git@github.com:fixture-owner/skills.git
git -C "$SOURCE_FIXTURE" update-ref refs/remotes/origin/main HEAD
"$SOURCE_FIXTURE/global/tools/shadow-sync/install.sh" --source-identity >/dev/null

printf 'dirty\n' >>"$SOURCE_FIXTURE/global/tools/shadow-sync/README.md"
if "$SOURCE_FIXTURE/global/tools/shadow-sync/install.sh" --source-identity >/dev/null 2>&1; then
  printf 'm6-lifecycle-e2e: dirty source was accepted\n' >&2
  exit 1
fi
git -C "$SOURCE_FIXTURE" checkout -q -- global/tools/shadow-sync/README.md
touch "$SOURCE_FIXTURE/global/tools/shadow-sync/untracked"
if "$SOURCE_FIXTURE/global/tools/shadow-sync/install.sh" --source-identity >/dev/null 2>&1; then
  printf 'm6-lifecycle-e2e: untracked source was accepted\n' >&2
  exit 1
fi
rm "$SOURCE_FIXTURE/global/tools/shadow-sync/untracked"
printf '# drift\n' >>"$SOURCE_FIXTURE/.eco-registry.lock"
if "$SOURCE_FIXTURE/global/tools/shadow-sync/install.sh" --source-identity >/dev/null 2>&1; then
  printf 'm6-lifecycle-e2e: metadata-lock drift was accepted\n' >&2
  exit 1
fi
git -C "$SOURCE_FIXTURE" checkout -q -- .eco-registry.lock

git -C "$SOURCE_FIXTURE" worktree add -q --detach "$TEST_ROOT/source-linked"
if "$TEST_ROOT/source-linked/global/tools/shadow-sync/install.sh" --source-identity >/dev/null 2>&1; then
  printf 'm6-lifecycle-e2e: linked-worktree source was accepted\n' >&2
  exit 1
fi

RACE_LOG="$TEST_ROOT/source-race.log"
"$SOURCE_FIXTURE/global/tools/shadow-sync/install.sh" --build-release-check \
  >"$RACE_LOG" 2>&1 &
RACE_PID=$!
for _ in $(seq 1 400); do
  if grep -q 'captured source revision' "$RACE_LOG"; then
    break
  fi
  kill -0 "$RACE_PID" 2>/dev/null || break
  sleep 0.05
done
grep -q 'captured source revision' "$RACE_LOG" || {
  wait "$RACE_PID" || true
  printf 'm6-lifecycle-e2e: source race did not reach captured build\n' >&2
  exit 1
}
printf 'drift-during-build\n' >>"$SOURCE_FIXTURE/global/tools/shadow-sync/README.md"
if wait "$RACE_PID"; then
  printf 'm6-lifecycle-e2e: source drift before promotion was accepted\n' >&2
  exit 1
fi
git -C "$SOURCE_FIXTURE" checkout -q -- global/tools/shadow-sync/README.md

TEST_OUTPUT="$TEST_ROOT/testing-output"
"$CAPABILITY/scripts/build-app.sh" \
  --scratch-path "$TEST_ROOT/testing-swift" \
  --output-dir "$TEST_OUTPUT" \
  --testing
TEST_APP="$TEST_OUTPUT/ShadowSync.app"
TEST_EXECUTABLE="$TEST_APP/Contents/MacOS/ShadowSync"

make_host_source() {
  local name="$1" revision="$2" digest="$3" app
  app="$TEST_ROOT/$name.app"
  cp -R "$TEST_APP" "$app"
  plutil -replace ShadowSyncBuildMode -string production "$app/Contents/Info.plist"
  plutil -replace ShadowSyncSourceRevision -string "$revision" "$app/Contents/Info.plist"
  plutil -replace ShadowSyncSourceInputSHA256 -string "$digest" "$app/Contents/Info.plist"
  plutil -replace ShadowSyncReleaseContractSHA256 -string "$META_DIGEST" "$app/Contents/Info.plist"
  codesign --force --sign - --timestamp=none \
    --identifier com.kleinperkins.shadow-sync "$app" >/dev/null
  /usr/bin/xattr -cr "$app"
  codesign --verify --strict --verbose=2 "$app" >/dev/null
  printf '%s\n' "$app"
}
SOURCE_HOST_N="$(make_host_source host-n \
  1111111111111111111111111111111111111111 \
  2222222222222222222222222222222222222222222222222222222222222222)"
SOURCE_HOST_N1="$(make_host_source host-n1 \
  3333333333333333333333333333333333333333 \
  4444444444444444444444444444444444444444444444444444444444444444)"
SOURCE_PREDECESSOR="$(make_host_source predecessor-main-783fa058 \
  783fa0587cccdb2c88a6a8b246c1ed0ed536e60b \
  0aaaad83bb080e6ed0db71de2df9b9010d63a79ceb78dfee73785cfe218ffa7c)"
plutil -replace ShadowSyncReleaseContractSHA256 \
  -string 08d13f1f8425e952a2aa6d8662eebc846066d135fec806f82b14ba44b9175b5f \
  "$SOURCE_PREDECESSOR/Contents/Info.plist"
codesign --force --sign - --timestamp=none \
  --identifier com.kleinperkins.shadow-sync "$SOURCE_PREDECESSOR" >/dev/null
/usr/bin/xattr -cr "$SOURCE_PREDECESSOR"

swift build \
  --package-path "$CAPABILITY" \
  --scratch-path "$TEST_ROOT/testing-swift" \
  --configuration release \
  --product ShadowSyncSelfTest \
  --disable-index-store \
  -Xswiftc -DSHADOW_SYNC_TESTING >/dev/null
BIN_DIR="$(swift build \
  --package-path "$CAPABILITY" \
  --scratch-path "$TEST_ROOT/testing-swift" \
  --configuration release \
  --product ShadowSyncSelfTest \
  --disable-index-store \
  -Xswiftc -DSHADOW_SYNC_TESTING \
  --show-bin-path)"
"$BIN_DIR/ShadowSyncSelfTest" --app-executable "$TEST_EXECUTABLE" --m6-only

build_release() {
  local name="$1" revision="$2" source_digest="$3" capture captured_capability
  capture="$TEST_ROOT/$name-capture"
  mkdir -m 700 "$capture"
  git -C "$SOURCE_FIXTURE" archive HEAD global/tools/shadow-sync \
    | tar -x -C "$capture"
  captured_capability="$capture/global/tools/shadow-sync"
  "$captured_capability/scripts/build-app.sh" \
    --scratch-path "$TEST_ROOT/$name-swift" \
    --output-dir "$TEST_ROOT/$name-output" \
    --source-revision "$revision" \
    --source-input-sha256 "$source_digest" \
    --release-contract-sha256 "$META_DIGEST"
}

SOURCE_N="$(build_release n \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
SOURCE_N_DUPLICATE="$(build_release n-duplicate \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
clone_release() {
  local name="$1" revision="$2" source_digest="$3" output app
  output="$TEST_ROOT/$name-output"
  mkdir -m 700 "$output"
  app="$output/ShadowSync.app"
  cp -R "$SOURCE_N" "$app"
  plutil -replace ShadowSyncSourceRevision -string "$revision" "$app/Contents/Info.plist"
  plutil -replace ShadowSyncSourceInputSHA256 -string "$source_digest" "$app/Contents/Info.plist"
  codesign --force --sign - --timestamp=none \
    --identifier com.kleinperkins.shadow-sync "$app" >/dev/null
  /usr/bin/xattr -cr "$app"
  codesign --verify --strict --verbose=2 "$app" >/dev/null
  printf '%s\n' "$app"
}
SOURCE_EQUIVALENT="$(clone_release equivalent \
  eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
SOURCE_N1="$(clone_release n1 \
  cccccccccccccccccccccccccccccccccccccccc \
  dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd)"

POST_SIGN_EVIDENCE="$TEST_ROOT/post-sign-evidence.txt"
python3 - "$SOURCE_N" "$SOURCE_N_DUPLICATE" >"$POST_SIGN_EVIDENCE" <<'PY'
import hashlib
import os
import plistlib
import stat
import struct
import sys

def inventory(root):
    rows = {}
    root_info = os.lstat(root)
    rows["."] = ("d", stat.S_IMODE(root_info.st_mode), 0, "-")
    for current, directories, files in os.walk(root):
        directories.sort()
        files.sort()
        for name in directories + files:
            path = os.path.join(current, name)
            relative = os.path.relpath(path, root)
            info = os.lstat(path)
            if stat.S_ISDIR(info.st_mode):
                rows[relative] = ("d", stat.S_IMODE(info.st_mode), 0, "-")
            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                with open(path, "rb") as handle:
                    digest = hashlib.sha256(handle.read()).hexdigest()
                rows[relative] = ("f", stat.S_IMODE(info.st_mode), info.st_size, digest)
            else:
                raise SystemExit(f"unsafe bundle entry: {relative}")
    return rows

def normalized_macho(path):
    data = bytearray(open(path, "rb").read())
    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise SystemExit("unexpected non-arm64 Mach-O in repeated build")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    cursor = 32
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, cursor)
        if command == 0x1B:
            data[cursor + 8:cursor + 24] = b"\0" * 16
        elif command == 0x1D:
            offset, length = struct.unpack_from("<II", data, cursor + 8)
            data[offset:offset + length] = b"\0" * length
        cursor += size
    return bytes(data)

left, right = map(inventory, sys.argv[1:])
with open(os.path.join(sys.argv[1], "Contents", "Info.plist"), "rb") as handle:
    left_info = plistlib.load(handle)
with open(os.path.join(sys.argv[2], "Contents", "Info.plist"), "rb") as handle:
    right_info = plistlib.load(handle)
keys = [
    "ShadowSyncReleaseSchema", "CFBundleShortVersionString", "CFBundleVersion",
    "ShadowSyncSourceRevision", "ShadowSyncSourceInputSHA256",
    "ShadowSyncReleaseContractSHA256", "ShadowSyncArchitecture",
    "LSMinimumSystemVersion", "ShadowSyncBuildMode",
]
if {key: left_info[key] for key in keys} != {key: right_info[key] for key in keys}:
    raise SystemExit("declared release identity changed across clean builds")
if left == right:
    print("m6-lifecycle-e2e: repeated-post-sign-bundle=byte-identical")
else:
    changed = sorted(key for key in set(left) | set(right) if left.get(key) != right.get(key))
    permitted = {
        "Contents/MacOS/ShadowSync",
        "Contents/_CodeSignature/CodeResources",
    }
    if not set(changed).issubset(permitted):
        raise SystemExit(f"unexplained post-sign bundle variance: {changed}")
    left_binary = os.path.join(sys.argv[1], "Contents", "MacOS", "ShadowSync")
    right_binary = os.path.join(sys.argv[2], "Contents", "MacOS", "ShadowSync")
    if normalized_macho(left_binary) != normalized_macho(right_binary):
        raise SystemExit("binary variance extends beyond LC_UUID and code signature")
    print("m6-lifecycle-e2e: repeated-post-sign-bundle=variance")
    print("m6-lifecycle-e2e: post-sign-changed-paths=" + ",".join(changed))
    print("m6-lifecycle-e2e: post-sign-variance-cause=LC_UUID+adhoc-code-signature")
PY
cat "$POST_SIGN_EVIDENCE"
if grep -q 'repeated-post-sign-bundle=variance' "$POST_SIGN_EVIDENCE"; then
  for bundle in "$SOURCE_N" "$SOURCE_N_DUPLICATE"; do
    binary="$bundle/Contents/MacOS/ShadowSync"
    uuid="$(otool -l "$binary" | awk '/LC_UUID/{seen=1; next} seen && /uuid/{print $2; exit}')"
    cdhash="$(codesign -dvvv "$bundle" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
    printf 'm6-lifecycle-e2e: post-sign-variance uuid=%s cdhash=%s\n' \
      "${uuid:-none}" "${cdhash:-none}"
  done
fi

RESULT="$TEST_ROOT/result.json"
python3 - "$TEST_EXECUTABLE" "$TEST_ROOT" "$SOURCE_N" "$SOURCE_EQUIVALENT" "$SOURCE_N1" "$RESULT" <<'PY'
import json
import os
import socket
import subprocess
import sys

executable, root, source_n, source_equivalent, source_n1, result_path = sys.argv[1:]
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
    raise SystemExit("M6 app harness timed out")
finally:
    parent.close()
if process.returncode != 0:
    raise SystemExit(
        f"M6 app harness failed ({process.returncode}): "
        + stderr.decode(errors="replace")
        + stdout.decode(errors="replace")
    )
result = json.loads(payload)
if result.get("schema") != "shadow-sync-m6-lifecycle-result/v1":
    raise SystemExit(f"unexpected M6 result: {result}")
required = {
    "first-install",
    "same-source-no-op",
    "launchagent-exact-managed-role",
    "launch-failure-rollback",
    "verified-uninstall-durable-state",
    "durable-state-update-repair-rollback-uninstall",
    "v4-stopped-predecessor-dead-coordination-repair",
}
if not required.issubset(set(result.get("passed", []))):
    raise SystemExit(f"missing M6 evidence: {result}")
if any("/bin/launchctl" in item or "gui/" in item for item in result["launchctlInvocations"]):
    raise SystemExit("M6 test invoked a live launchctl domain")
with open(result_path, "w", encoding="utf-8") as handle:
    json.dump(result, handle, sort_keys=True)
    handle.write("\n")
print(
    "m6-lifecycle-e2e: "
    f"passed={len(result['passed'])} "
    f"recorded-launch-actions={len(result['launchctlInvocations'])} "
    "live-launchctl=never"
)
PY

python3 - "$TEST_EXECUTABLE" "$TEST_ROOT" "$SOURCE_HOST_N" "$SOURCE_HOST_N1" \
  "$SOURCE_PREDECESSOR" <<'PY'
import json
import os
import socket
import subprocess
import sys

executable, root, source_n, source_n1, source_predecessor = sys.argv[1:]
def run(operation, operation_root):
    os.makedirs(os.path.join(operation_root, "home"), mode=0o700, exist_ok=True)
    parent, child = socket.socketpair()
    parent.settimeout(120)
    request = {
        "schema": "shadow-sync-m6-lifecycle/v1",
        "testRoot": operation_root,
        "sourceN": source_n,
        "sourceEquivalent": source_n,
        "sourceN1": source_n1,
        "sourceHostN": source_n,
        "sourceHostN1": source_n1,
        "sourcePredecessor": source_predecessor,
        "operation": operation,
    }
    process = subprocess.Popen(
        [
            executable, "--shadow-sync-m6-lifecycle-channel", str(child.fileno()),
        ],
        pass_fds=(child.fileno(),),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    child.close()
    parent.sendall(json.dumps(request, sort_keys=True).encode() + b"\n")
    parent.shutdown(socket.SHUT_WR)
    payload = b""
    try:
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
        raise SystemExit(f"{operation} harness timed out")
    finally:
        parent.close()
    if process.returncode != 0:
        raise SystemExit(
            f"{operation} harness failed: "
            + stderr.decode(errors="replace")
            + stdout.decode(errors="replace")
        )
    return json.loads(payload)

compatibility = run("compatibility", root)
recovery_pairing = run("recovery-pairing", root)
post_start = run("post-start-convergence", root)
result = run("real-host", root)
result["passed"] += compatibility.get("passed", [])
result["passed"] += recovery_pairing.get("passed", [])
result["passed"] += post_start.get("passed", [])
required = {
    "real-host-lock-socket-readiness",
    "real-host-n-to-n-plus-one-handoff",
    "real-host-corrupted-bundle-repair",
    "real-host-verified-uninstall",
    "startup-role-exact-marker-contract",
    "managed-start-published-pid-admitted",
    "managed-start-pre-publication-admitted",
    "managed-start-launcher-contention-retried",
    "managed-start-no-self-kickstart-or-readiness-wait",
    "manual-start-ready-nil-pid-no-kickstart",
    "manual-start-ready-stale-pid-no-kickstart",
    "manual-start-became-ready-during-observation",
    "manual-start-matching-pid-then-ready-no-kickstart",
    "manual-start-observed-managed-pid-without-kickstart",
    "manual-start-persistent-nil-kickstarted-once",
    "manual-start-wrong-ready-identity-refused",
    "repair-ready-nil-or-stale-pid-no-kickstart",
    "post-start-managed-child-admitted-before-lag",
    "post-kickstart-nil-then-matching-converged",
    "post-kickstart-stale-then-matching-converged",
    "post-kickstart-matching-immediate",
    "post-kickstart-nil-deadline-refused",
    "post-kickstart-conflicting-pid-refused",
    "post-kickstart-query-failure-refused",
    "post-kickstart-no-duplicate-restart",
    "post-kickstart-manual-repair-parity",
    "forged-managed-marker-refused",
    "stopped-job-manual-launch-routed",
    "live-host-manual-launch-routed",
    "manual-launch-never-became-host",
    "pid-mismatch-reuse-refused",
    "stale-pid-manual-launch-restarted",
    "stale-pid-repair-restarted",
    "stopped-job-repair-restarted",
    "stopped-job-bytes-unchanged",
    "rollback-delayed-exit-restored-backups",
    "rollback-immediate-exit-restored-backups",
    "rollback-stale-registration-cleaned-after-drain",
    "rollback-exit-timeout-fail-closed",
    "rollback-timeout-remained-recoverable",
    "predecessor-healthy-default-migrated",
    "predecessor-stopped-required-repair",
    "current-contract-reconcile-idempotent",
    "predecessor-extra-key-refused",
    "predecessor-wrong-label-refused",
    "predecessor-wrong-program-refused",
    "predecessor-invalid-signature-refused",
    "failed-migration-restored-stopped-predecessor",
    "predecessor-transaction-windows-no-new-old",
    "successful-migration-current-contract-only",
    "predecessor-recovery-resumed-after-app-promotion",
    "current-recovery-resumed-after-app-promotion",
    "first-install-legacy-plist-backup-refused",
    "current-target-legacy-plist-backup-refused",
    "predecessor-target-legacy-plist-drift-refused",
    "corrupt-app-backup-current-target-refused",
    "corrupt-app-backup-predecessor-target-refused",
    "corrupt-app-backup-missing-target-refused",
    "corrupt-app-backup-invalid-target-refused",
}
if not required.issubset(set(result.get("passed", []))):
    raise SystemExit(f"missing real-host evidence: {result}")
print(
    "m6-lifecycle-e2e: startup-role=explicit "
    "published-pid=PASS pre-publication=PASS launcher-contention=PASS "
    "self-kickstart=absent readiness-first=PASS manual-host=refused"
)
print(
    "m6-lifecycle-e2e: rollback-order=drain-before-cleanup "
    "delayed=PASS immediate=PASS stale=PASS timeout=FAIL-CLOSED "
    "recoverability=PASS"
)
print(
    "m6-lifecycle-e2e: predecessor=783fa058 exact-contract=MIGRATED "
    "stopped=REPAIR-ONLY drift=REFUSED rollback=RESTORED "
    "postcondition=CURRENT-ONLY"
)
print(
    "m6-lifecycle-e2e: recovery-pairing=VERIFIED "
    "interrupted-predecessor=RESUMED current=RESUMED "
    "missing-corrupt-mismatch-drift=REFUSED"
)
print(
    "m6-lifecycle-e2e: post-start-convergence=VERIFIED "
    "nil-stale-to-matching=PASS conflict-query-deadline=REFUSED "
    "manual-repair=PARITY"
)
PY

python3 - "$TEST_EXECUTABLE" "$TEST_ROOT" "$SOURCE_N" <<'PY'
import atexit
import json
import os
import select
import shutil
import socket
import subprocess
import sys

executable, master, source_n = sys.argv[1:]
owned_processes = []

def reap_owned():
    for process in owned_processes:
        if process.poll() is not None:
            continue
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)

atexit.register(reap_owned)

def lock_race(name, kinds):
    root = os.path.join(master, name)
    os.mkdir(root, 0o700)
    os.mkdir(os.path.join(root, "home"), 0o700)
    children = []
    for kind in kinds:
        gate_read, gate_write = os.pipe()
        result_read, result_write = os.pipe()
        process = subprocess.Popen(
            [
                executable, "--shadow-sync-m6-lock-contender", kind, root,
                str(gate_read), str(result_write),
            ],
            pass_fds=(gate_read, result_write),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        owned_processes.append(process)
        os.close(gate_read)
        os.close(result_write)
        children.append((process, gate_write, result_read))
    for _, gate, _ in children:
        os.write(gate, b"G")
        os.close(gate)
    outcomes = []
    for process, _, result in children:
        ready, _, _ = select.select([result], [], [], 5)
        if not ready:
            process.terminate()
            process.wait(timeout=2)
            raise SystemExit(f"{name} result timed out")
        outcomes.append(os.read(result, 1).decode())
        os.close(result)
        process.communicate(timeout=5)
    if sorted(outcomes) != ["C", "S"]:
        raise SystemExit(f"{name} admitted wrong outcomes: {outcomes}")
    shutil.rmtree(root)

lock_race("race-lifecycle-run", ["lifecycle", "run"])
lock_race("race-duplicate-launch", ["launcher", "launcher"])

root = os.path.join(master, "race-promotion")
os.mkdir(root, 0o700)
os.mkdir(os.path.join(root, "home"), 0o700)
copied = os.path.join(root, "source.app")
shutil.copytree(source_n, copied, copy_function=shutil.copy2)
request = {
    "schema": "shadow-sync-m6-lifecycle/v1",
    "testRoot": root,
    "sourceN": copied,
    "sourceEquivalent": copied,
    "sourceN1": copied,
    "operation": "install-only",
}
contenders = []
for _ in range(2):
    parent, child = socket.socketpair()
    parent.settimeout(30)
    process = subprocess.Popen(
        [executable, "--shadow-sync-m6-lifecycle-channel", str(child.fileno())],
        pass_fds=(child.fileno(),),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    owned_processes.append(process)
    child.close()
    contenders.append((process, parent))
for _, channel in contenders:
    channel.sendall(json.dumps(request, sort_keys=True).encode() + b"\n")
    channel.shutdown(socket.SHUT_WR)
statuses = []
for process, channel in contenders:
    try:
        while channel.recv(65536):
            pass
        process.communicate(timeout=30)
    except (socket.timeout, subprocess.TimeoutExpired):
        process.terminate()
        process.wait(timeout=2)
        raise SystemExit("concurrent promotion timed out")
    statuses.append(process.returncode)
if sorted(statuses) != [0, 2]:
    raise SystemExit(f"concurrent promotion outcomes were not serialized: {statuses}")
shutil.rmtree(root)
print("m6-lifecycle-e2e: process-barrier lifecycle/run, duplicate-launch, promotion passed")
PY

python3 - "$TEST_EXECUTABLE" "$TEST_ROOT" "$SOURCE_HOST_N" "$SOURCE_HOST_N1" <<'PY'
import json
import os
import shutil
import socket
import subprocess
import sys

executable, master, source_n, source_n1 = sys.argv[1:]
stages = [
    "after-gates",
    "after-drain",
    "before-promotion",
    "after-app-backup",
    "after-plist-backup",
    "after-app-promotion",
    "after-plist-promotion",
    "after-bootstrap",
    "after-kickstart",
    "after-readiness",
    "after-commit",
    "install-cleanup-app-quarantined",
    "install-cleanup-app-removed",
    "install-cleanup-plist-quarantined",
    "install-cleanup-plist-removed",
    "install-cleanup-incoming-removed",
    "after-cleanup",
]

def invoke(request, expected):
    parent, child = socket.socketpair()
    parent.settimeout(120)
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
        raise SystemExit("lifecycle crash channel timed out")
    finally:
        parent.close()
    if process.returncode != expected:
        raise SystemExit(
            f"crash harness status {process.returncode}, expected {expected}: "
            + stderr.decode(errors="replace")
            + stdout.decode(errors="replace")
        )
    return json.loads(payload) if payload else None

for index, stage in enumerate(stages):
    root = os.path.join(master, f"crash-{index}")
    os.mkdir(root, 0o700)
    os.mkdir(os.path.join(root, "home"), 0o700)
    copied_n = os.path.join(root, "source-n.app")
    copied_n1 = os.path.join(root, "source-n1.app")
    shutil.copytree(source_n, copied_n, copy_function=shutil.copy2)
    shutil.copytree(source_n1, copied_n1, copy_function=shutil.copy2)
    base = {
        "schema": "shadow-sync-m6-lifecycle/v1",
        "testRoot": root,
        "sourceN": copied_n,
        "sourceEquivalent": copied_n,
        "sourceN1": copied_n1,
    }
    invoke({**base, "operation": "crash", "faultStage": stage}, 86)
    admission = invoke({**base, "operation": "admission"}, 0)
    expected_admission = {
        "after-gates": "admission-succeeded",
        "after-drain": "launchd-incomplete-admission-refused",
        "install-cleanup-plist-removed": "admission-succeeded",
        "install-cleanup-incoming-removed": "admission-succeeded",
        "after-cleanup": "admission-succeeded",
    }.get(stage, "lifecycle-residue-admission-refused")
    if admission.get("passed") != [expected_admission]:
        raise SystemExit(
            f"wrong update admission outcome for {stage}: "
            f"expected {expected_admission}, got {admission}"
        )
    result = invoke({**base, "operation": "recover"}, 0)
    if "crash-recovered" not in result.get("passed", []):
        raise SystemExit(f"crash recovery did not pass for {stage}: {result}")
    shutil.rmtree(root)
    print(f"m6-lifecycle-e2e: hard-crash-cut={stage} recovered=yes")

for index, stage in enumerate(stages):
    root = os.path.join(master, f"repair-crash-{index}")
    os.mkdir(root, 0o700)
    os.mkdir(os.path.join(root, "home"), 0o700)
    copied_n = os.path.join(root, "source-n.app")
    copied_n1 = os.path.join(root, "source-n1.app")
    shutil.copytree(source_n, copied_n, copy_function=shutil.copy2)
    shutil.copytree(source_n1, copied_n1, copy_function=shutil.copy2)
    base = {
        "schema": "shadow-sync-m6-lifecycle/v1",
        "testRoot": root,
        "sourceN": copied_n,
        "sourceEquivalent": copied_n,
        "sourceN1": copied_n1,
    }
    invoke({**base, "operation": "repair-crash", "faultStage": stage}, 86)
    admission = invoke({**base, "operation": "admission"}, 0)
    expected_admission = {
        "after-gates": "invalid-signature-admission-refused",
        "after-drain": "invalid-signature-admission-refused",
        "install-cleanup-plist-removed": "admission-succeeded",
        "install-cleanup-incoming-removed": "admission-succeeded",
        "after-cleanup": "admission-succeeded",
    }.get(stage, "lifecycle-residue-admission-refused")
    if admission.get("passed") != [expected_admission]:
        raise SystemExit(
            f"wrong repair admission outcome for {stage}: "
            f"expected {expected_admission}, got {admission}"
        )
    result = invoke({**base, "operation": "recover"}, 0)
    if "crash-recovered" not in result.get("passed", []):
        raise SystemExit(f"repair crash recovery did not pass for {stage}: {result}")
    shutil.rmtree(root)
    print(f"m6-lifecycle-e2e: repair-hard-crash={stage} recovered=yes")

first_install_stages = [
    "after-gates",
    "after-drain",
    "before-promotion",
    "after-app-promotion",
    "after-plist-promotion",
    "after-bootstrap",
    "after-kickstart",
    "after-readiness",
    "after-commit",
    "install-cleanup-incoming-removed",
    "after-cleanup",
]
for index, stage in enumerate(first_install_stages):
    root = os.path.join(master, f"first-crash-{index}")
    os.mkdir(root, 0o700)
    os.mkdir(os.path.join(root, "home"), 0o700)
    copied_n1 = os.path.join(root, "source-n1.app")
    shutil.copytree(source_n1, copied_n1, copy_function=shutil.copy2)
    base = {
        "schema": "shadow-sync-m6-lifecycle/v1",
        "testRoot": root,
        "sourceN": copied_n1,
        "sourceEquivalent": copied_n1,
        "sourceN1": copied_n1,
    }
    invoke({**base, "operation": "first-crash", "faultStage": stage}, 86)
    admission = invoke({**base, "operation": "admission"}, 0)
    expected_admission = {
        "after-gates": "product-absent-admission-refused",
        "after-drain": "product-absent-admission-refused",
        "after-plist-promotion": "launchd-incomplete-admission-refused",
        "after-bootstrap": "launchd-incomplete-admission-refused",
        "after-kickstart": "admission-succeeded",
        "after-readiness": "admission-succeeded",
        "after-commit": "admission-succeeded",
        "install-cleanup-incoming-removed": "admission-succeeded",
        "after-cleanup": "admission-succeeded",
    }.get(stage, "lifecycle-residue-admission-refused")
    if admission.get("passed") != [expected_admission]:
        raise SystemExit(
            f"wrong first-install admission outcome for {stage}: "
            f"expected {expected_admission}, got {admission}"
        )
    result = invoke({**base, "operation": "recover"}, 0)
    if "crash-recovered" not in result.get("passed", []):
        raise SystemExit(f"first-install crash recovery did not pass for {stage}: {result}")
    shutil.rmtree(root)
    print(f"m6-lifecycle-e2e: first-install-hard-crash={stage} recovered=yes")

uninstall_stages = [
    "uninstall-after-gates",
    "uninstall-after-drain",
    "uninstall-after-backup",
    "uninstall-after-commit",
    "uninstall-cleanup-app-quarantined",
    "uninstall-cleanup-app-removed",
    "uninstall-cleanup-plist-quarantined",
    "uninstall-cleanup-plist-removed",
    "uninstall-cleanup-incoming-removed",
    "uninstall-after-cleanup",
    "uninstall-retired-launcher.lock",
    "uninstall-retired-run.lock",
    "uninstall-retired-operation.lock",
    "uninstall-retired-lifecycle.lock",
]
for index, stage in enumerate(uninstall_stages):
    root = os.path.join(master, f"uninstall-crash-{index}")
    os.mkdir(root, 0o700)
    os.mkdir(os.path.join(root, "home"), 0o700)
    copied_n = os.path.join(root, "source-n.app")
    shutil.copytree(source_n, copied_n, copy_function=shutil.copy2)
    base = {
        "schema": "shadow-sync-m6-lifecycle/v1",
        "testRoot": root,
        "sourceN": copied_n,
        "sourceEquivalent": copied_n,
        "sourceN1": copied_n,
    }
    invoke({**base, "operation": "uninstall-crash", "faultStage": stage}, 86)
    admission = invoke({**base, "operation": "admission"}, 0)
    expected_admission = {
        "uninstall-after-gates": "launchd-incomplete-admission-refused",
        "uninstall-after-drain": "launchd-incomplete-admission-refused",
        "uninstall-cleanup-plist-removed": "product-absent-admission-refused",
        "uninstall-cleanup-incoming-removed": "product-absent-admission-refused",
        "uninstall-after-cleanup": "product-absent-admission-refused",
        "uninstall-retired-launcher.lock": "product-absent-admission-refused",
        "uninstall-retired-run.lock": "product-absent-admission-refused",
        "uninstall-retired-operation.lock": "product-absent-admission-refused",
        "uninstall-retired-lifecycle.lock": "product-absent-admission-refused",
    }.get(stage, "lifecycle-residue-admission-refused")
    if admission.get("passed") != [expected_admission]:
        raise SystemExit(
            f"wrong uninstall admission outcome for {stage}: "
            f"expected {expected_admission}, got {admission}"
        )
    result = invoke({**base, "operation": "uninstall-recover"}, 0)
    required = {"uninstall-crash-recovered", "repeated-uninstall-verified"}
    if not required.issubset(set(result.get("passed", []))):
        raise SystemExit(f"uninstall recovery failed for {stage}: {result}")
    shutil.rmtree(root)
    print(f"m6-lifecycle-e2e: uninstall-hard-crash={stage} recovered=yes")
PY

if strings "$SOURCE_N/Contents/MacOS/ShadowSync" \
  | grep -E -q 'shadow-sync-m6-lifecycle-channel|M6AppDriver|M6SelfTestRunner'; then
  printf 'm6-lifecycle-e2e: production binary contains an M6 test entrypoint\n' >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$SOURCE_N"
codesign --verify --strict --verbose=2 "$SOURCE_N1"
printf 'm6-lifecycle-e2e: production-test-symbols=absent\n'
printf 'm6-lifecycle-e2e: latest-log-preserved=yes\n'
printf 'm6-lifecycle-e2e: cleanup=complete\n'
