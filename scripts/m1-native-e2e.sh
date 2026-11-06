#!/bin/bash
set -euo pipefail
umask 077

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
ROOT="$(mktemp -d /private/tmp/shadow-sync-m1.XXXXXX)"
LOGICAL_ORIGIN="git@github.com:fixture-owner/fixture-repo.git"
AGENT_PID=""

cleanup() {
  local status="$1"
  trap - EXIT INT TERM
  if [ -n "$AGENT_PID" ]; then
    shadow_sync_reap_known_owned_root_pid "$ROOT" m1-native-e2e-agent "$AGENT_PID" \
      || status=1
    AGENT_PID=""
  fi
  if ! shadow_sync_reap_owned_root_helpers "$ROOT" m1-native-e2e; then
    printf 'm1-native-e2e: fixture child leaked before cleanup\n' >&2
    status=1
  fi
  shadow_sync_remove_owned_root "$ROOT" m1-native-e2e || status=1
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot_live_state() {
  python3 - "$1" <<'PY'
import hashlib
import json
import os
import pwd
import stat
import sys

home = pwd.getpwuid(os.geteuid()).pw_dir
roots = [
    os.path.join(home, ".local/state/shadow-sync"),
    os.path.join(home, "Applications/ShadowSync.app"),
    os.path.join(home, "Library/LaunchAgents/com.kleinperkins.shadow-sync.plist"),
]
snapshot = {}

def capture(path, git_control=False):
    try:
        value = os.lstat(path)
    except FileNotFoundError:
        snapshot[path] = None
        return
    row = {
        "mode": stat.S_IFMT(value.st_mode) | stat.S_IMODE(value.st_mode),
        "uid": value.st_uid,
        "links": value.st_nlink,
        "size": value.st_size,
        "device": value.st_dev,
        "inode": value.st_ino,
        "mtime_ns": value.st_mtime_ns,
    }
    if stat.S_ISREG(value.st_mode) and value.st_size <= 16 * 1024 * 1024:
        with open(path, "rb") as handle:
            row["sha256"] = hashlib.sha256(handle.read()).hexdigest()
    elif stat.S_ISLNK(value.st_mode):
        row["target"] = os.readlink(path)
    snapshot[path] = row

for root in roots:
    capture(root)
    if os.path.isdir(root) and not os.path.islink(root):
        for current, directories, files in os.walk(root, followlinks=False):
            directories.sort()
            files.sort()
            for name in directories + files:
                capture(os.path.join(current, name))

git = os.path.join(home, "dev/.git")
git_roots = [
    os.path.join(git, "HEAD"),
    os.path.join(git, "index"),
    os.path.join(git, "config"),
    os.path.join(git, "FETCH_HEAD"),
    os.path.join(git, "ORIG_HEAD"),
    os.path.join(git, "packed-refs"),
    os.path.join(git, "refs"),
    os.path.join(git, "logs"),
]
for root in git_roots:
    capture(root, git_control=True)
    if os.path.isdir(root) and not os.path.islink(root):
        count = 0
        for current, directories, files in os.walk(root, followlinks=False):
            directories.sort()
            files.sort()
            for name in directories + files:
                capture(os.path.join(current, name), git_control=True)
                count += 1
                if count > 4096:
                    raise SystemExit("real ~/dev Git-control snapshot exceeded bound")
worktrees = os.path.join(git, "worktrees")
if os.path.isdir(worktrees) and not os.path.islink(worktrees):
    worktree_names = sorted(
        name for name in os.listdir(worktrees)
        if os.path.isdir(os.path.join(worktrees, name))
        and not os.path.islink(os.path.join(worktrees, name))
    )
    snapshot[worktrees + "#names"] = worktree_names
    for name in worktree_names:
        worktree = os.path.join(worktrees, name)
        for relative in (
            "HEAD", "index", "ORIG_HEAD", "FETCH_HEAD", "gitdir",
            "commondir", "locked", "config.worktree",
        ):
            capture(os.path.join(worktree, relative), git_control=True)
else:
    snapshot[worktrees + "#names"] = None
objects = os.path.join(git, "objects")
capture(objects, git_control=True)
inventory = []
if os.path.isdir(objects) and not os.path.islink(objects):
    for current, directories, files in os.walk(objects, followlinks=False):
        directories.sort()
        files.sort()
        for name in directories + files:
            path = os.path.join(current, name)
            value = os.lstat(path)
            inventory.append({
                "path": os.path.relpath(path, objects),
                "mode": stat.S_IFMT(value.st_mode) | stat.S_IMODE(value.st_mode),
                "size": value.st_size,
                "mtime_ns": value.st_mtime_ns,
            })
            if len(inventory) > 4096:
                raise SystemExit("real ~/dev object inventory exceeded bound")
snapshot[objects + "#bounded-inventory"] = {
    "entries": inventory,
    "complete": True,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, sort_keys=True)
    handle.write("\n")
PY
}

assert_live_state_unchanged() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    before = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    after = json.load(handle)
changed = sorted(
    path for path in set(before) | set(after)
    if before.get(path) != after.get(path)
)
if changed:
    for path in changed[:20]:
        print(f"live snapshot changed: {path}", file=sys.stderr)
        print(f"  before={before.get(path)!r}", file=sys.stderr)
        print(f"  after={after.get(path)!r}", file=sys.stderr)
    raise SystemExit("live and Git-control snapshot changed")
PY
}

FIXTURE_GIT_HOME="$ROOT/fixture-git-home"
mkdir -m 700 "$FIXTURE_GIT_HOME"
fixture_git() {
  env -i \
    HOME="$FIXTURE_GIT_HOME" \
    USER="shadow-sync-fixture" \
    LOGNAME="shadow-sync-fixture" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    LANG=C \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    /usr/bin/git "$@"
}

git_at() {
  fixture_git -C "$1" "${@:2}"
}

run_sandboxed_app() {
  /usr/bin/sandbox-exec \
    -p '(version 1) (allow default) (deny network*)' \
    "$@"
}

run_harness() {
  local repository="$1" output="$2"
  local live_before="${output}.live-before" live_after="${output}.live-after"
  snapshot_live_state "$live_before"
  SHADOW_SYNC_EXECUTABLE="$TEST_EXECUTABLE" \
  SHADOW_SYNC_ROOT="$ROOT" \
  SHADOW_SYNC_REPOSITORY="$repository" \
  SHADOW_SYNC_ORIGIN="$LOGICAL_ORIGIN" \
  SHADOW_SYNC_REMOTE="$REMOTE" \
  SHADOW_SYNC_OUTPUT="$output" \
  GIT_TRACE="$ROOT/forbidden-git-trace" \
  GIT_TRACE2_EVENT="$ROOT/forbidden-trace2" \
  GIT_REDIRECT_STDERR="$ROOT/forbidden-redirect" \
  GIT_ASKPASS="$ROOT/forbidden-askpass" \
  GIT_SSH_COMMAND="$ROOT/forbidden-ssh-command" \
  python3 <<'PY'
import json
import os
import signal
import socket
import subprocess

parent, child = socket.socketpair()
request = {
    "schema": "shadow-sync-m1-harness/v1",
    "testRoot": os.environ["SHADOW_SYNC_ROOT"],
    "repositoryPath": os.environ["SHADOW_SYNC_REPOSITORY"],
    "logicalOrigin": os.environ["SHADOW_SYNC_ORIGIN"],
    "localBareRemote": os.environ["SHADOW_SYNC_REMOTE"],
    "seededDiagnostic": (
        "Authorization: Bearer seeded-bearer-secret "
        "api_key=seeded-api-key-secret "
        "github_pat_1234567890abcdefghijklmnop"
    ),
}
process = subprocess.Popen(
    [
        "/usr/bin/sandbox-exec",
        "-p",
        "(version 1) (allow default) (deny network*)",
        os.environ["SHADOW_SYNC_EXECUTABLE"],
        "--shadow-sync-m1-test-channel",
        str(child.fileno()),
    ],
    pass_fds=(child.fileno(),),
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=False,
    start_new_session=True,
)
child.close()
try:
    parent.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
    parent.settimeout(160)
    stream = parent.makefile("rb", buffering=0)
    line = stream.readline()
    status = process.wait(timeout=160)
except (TimeoutError, socket.timeout, subprocess.TimeoutExpired):
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=6)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)
    raise SystemExit("staged app harness timed out and was drained")
finally:
    parent.close()
stderr = process.stderr.read().decode(errors="replace")
if status != 0:
    raise SystemExit(f"staged app failed ({status}): {stderr}")
if not line:
    raise SystemExit(f"staged app returned no typed response: {stderr}")
result = json.loads(line)
with open(os.environ["SHADOW_SYNC_OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(result, handle, sort_keys=True)
    handle.write("\n")
PY
  snapshot_live_state "$live_after"
  assert_live_state_unchanged "$live_before" "$live_after"
  rm -f "$live_before" "$live_after"
}

run_appkit_driver() {
  local repository="$1" output="$2" crash_sentinel="${3:-}"
  local live_before="${output}.live-before" live_after="${output}.live-after"
  snapshot_live_state "$live_before"
  SHADOW_SYNC_EXECUTABLE="$TEST_EXECUTABLE" \
  SHADOW_SYNC_ROOT="$ROOT" \
  SHADOW_SYNC_REPOSITORY="$repository" \
  SHADOW_SYNC_ORIGIN="$LOGICAL_ORIGIN" \
  SHADOW_SYNC_REMOTE="$REMOTE" \
  SHADOW_SYNC_OUTPUT="$output" \
  SHADOW_SYNC_CRASH_SENTINEL="$crash_sentinel" \
  python3 <<'PY'
import json
import os
import signal
import socket
import subprocess

parent, child = socket.socketpair()
request = {
    "schema": "shadow-sync-m1-appkit/v1",
    "testRoot": os.environ["SHADOW_SYNC_ROOT"],
    "repositoryPath": os.environ["SHADOW_SYNC_REPOSITORY"],
    "logicalOrigin": os.environ["SHADOW_SYNC_ORIGIN"],
    "localBareRemote": os.environ["SHADOW_SYNC_REMOTE"],
    "agentSocketPath": os.environ.get("SSH_AUTH_SOCK"),
}
if os.environ.get("SHADOW_SYNC_CRASH_SENTINEL"):
    request["crashSentinel"] = os.environ["SHADOW_SYNC_CRASH_SENTINEL"]
process = subprocess.Popen(
    [
        "/usr/bin/sandbox-exec",
        "-p",
        "(version 1) (allow default) (deny network*)",
        os.environ["SHADOW_SYNC_EXECUTABLE"],
        "--shadow-sync-m1-appkit-channel",
        str(child.fileno()),
    ],
    pass_fds=(child.fileno(),),
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=False,
    start_new_session=True,
)
child.close()
try:
    parent.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
    parent.settimeout(165)
    line = parent.makefile("rb", buffering=0).readline()
    status = process.wait(timeout=165)
except (TimeoutError, socket.timeout, subprocess.TimeoutExpired):
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=6)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)
    raise SystemExit("AppKit driver timed out and was drained")
finally:
    parent.close()
stderr = process.stderr.read().decode(errors="replace")
if status != 0:
    raise SystemExit(f"AppKit driver failed ({status}): {stderr}")
if not line:
    raise SystemExit(f"AppKit driver returned no response: {stderr}")
result = json.loads(line)
with open(os.environ["SHADOW_SYNC_OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(result, handle, sort_keys=True)
    handle.write("\n")
PY
  snapshot_live_state "$live_after"
  assert_live_state_unchanged "$live_before" "$live_after"
  rm -f "$live_before" "$live_after"
}

assert_result() {
  local output="$1" expected_code="$2" expected_fetched="$3" expected_updated="$4"
  python3 - "$output" "$expected_code" "$expected_fetched" "$expected_updated" <<'PY'
import json
import os
import sys

output, code, fetched, updated = sys.argv[1:]
with open(output, encoding="utf-8") as handle:
    envelope = json.load(handle)
assert envelope["schema"] == "shadow-sync-m1-harness-result/v1", envelope
report = envelope["report"]
assert report["schema"] == "shadow-sync-report/v1", report
assert len(report["results"]) == 1, report
row = report["results"][0]
assert row["code"] == code, row
assert row["fetched"] is (fetched == "true"), row
assert row["mainUpdated"] is (updated == "true"), row
assert row["durationMilliseconds"] >= 0, row
assert row["startedAt"] <= row["endedAt"], row
assert report["startedAt"] <= report["endedAt"], report
assert envelope["summary"].startswith("Run "), envelope["summary"]
events = envelope["events"]
assert events[0]["type"] == "run_started", events
assert events[-1]["type"] == "run_finished", events
assert [event["sequence"] for event in events] == list(range(1, len(events) + 1)), events
types = [event["type"] for event in events]
phases = [event.get("phase") for event in events if event["type"] == "repository_phase"]
assert "checking" in phases, phases
if fetched == "true":
    assert "fetching" in phases, phases
if updated == "true":
    assert "updating" in phases, phases
assert types.index("repository_result") < types.index("run_finished"), types
if code == "UPDATED":
    assert row["beforeCommit"] != row["targetCommit"], row
    assert row["afterCommit"] == row["targetCommit"], row
elif code == "ALREADY_CURRENT":
    assert row["beforeCommit"] == row["targetCommit"] == row["afterCommit"], row
elif fetched == "false":
    assert row.get("targetCommit") is None, row
with open(envelope["logPath"], "rb") as handle:
    raw_log = handle.read()
for secret in (
    b"seeded-bearer-secret",
    b"seeded-api-key-secret",
    b"github_pat_1234567890abcdefghijklmnop",
):
    assert secret not in raw_log, secret
records = [json.loads(line) for line in raw_log.splitlines()]
assert [record["sequence"] for record in records] == list(range(1, len(records) + 1)), records
final_reports = [
    record["report"] for record in records
    if record["type"] == "run_finished" and record.get("report")
]
assert final_reports == [report], (final_reports, report)
worker = int(envelope["workerPID"])
try:
    os.kill(worker, 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError(f"worker still exists after its event channel closed: {worker}")
PY
}

"$CAPABILITY/install.sh" --check

REMOTE="$ROOT/remote.git"
SEED="$ROOT/seed"
PRIMARY="$ROOT/primary"
fixture_git init --bare --quiet --initial-branch=main "$REMOTE"
fixture_git init --quiet --initial-branch=main "$SEED"
git_at "$SEED" config user.name "ShadowSync Fixture"
git_at "$SEED" config user.email "fixture@example.invalid"
printf 'base\n' > "$SEED/value.txt"
printf '[submodule "not-present"]\n\tpath = not-present\n\turl = git@github.com:fixture-owner/not-present.git\n' \
  > "$SEED/.gitmodules"
git_at "$SEED" add value.txt .gitmodules
git_at "$SEED" commit --quiet -m base
git_at "$SEED" remote add origin "$REMOTE"
git_at "$SEED" push --quiet -u origin main
fixture_git clone --quiet "$REMOTE" "$PRIMARY"

printf 'target\n' >> "$SEED/value.txt"
git_at "$SEED" commit --quiet -am target
git_at "$SEED" push --quiet origin main
BEFORE="$(git_at "$PRIMARY" rev-parse HEAD)"
TARGET="$(git_at "$SEED" rev-parse HEAD)"
test "$BEFORE" != "$TARGET"
git_at "$PRIMARY" remote set-url origin "$LOGICAL_ORIGIN"
git_at "$PRIMARY" config merge.autoStash true
git_at "$PRIMARY" config submodule.recurse true
git_at "$PRIMARY" config fetch.recurseSubmodules true

ESCAPE_ROOT="$ROOT/stage-escape"
ESCAPE_OUTSIDE="$ROOT/stage-escape-outside"
mkdir -m 700 "$ESCAPE_ROOT" "$ESCAPE_OUTSIDE"
printf 'preserve\n' > "$ESCAPE_OUTSIDE/sentinel"
ln -s "$ESCAPE_OUTSIDE" "$ESCAPE_ROOT/home"
if "$CAPABILITY/install.sh" \
  --m1-stage \
  --test-root "$ESCAPE_ROOT" \
  --scratch-path "$ESCAPE_ROOT/swift" >"$ROOT/stage-escape.log" 2>&1; then
  printf 'm1-native-e2e: staging followed a pre-existing symlink descendant\n' >&2
  exit 1
fi
test "$(cat "$ESCAPE_OUTSIDE/sentinel")" = preserve
test ! -e "$ESCAPE_ROOT/swift"
test ! -e "$ESCAPE_ROOT/build-output"

"$CAPABILITY/install.sh" \
  --m1-stage \
  --test-root "$ROOT" \
  --scratch-path "$ROOT/test-swift"
"$CAPABILITY/install.sh" --doctor --test-root "$ROOT"
TEST_APP="$ROOT/home/Applications/ShadowSync.app"
TEST_EXECUTABLE="$TEST_APP/Contents/MacOS/ShadowSync"
run_sandboxed_app "$TEST_EXECUTABLE" --check >/dev/null

if run_sandboxed_app "$TEST_EXECUTABLE" >"$ROOT/testing-fallback.log" 2>&1; then
  printf 'm1-native-e2e: testing bundle entered production AppKit mode\n' >&2
  exit 1
fi
rg -q 'requires an inherited isolated test channel' "$ROOT/testing-fallback.log"

AGENT_SOCKET="$ROOT/controlled-agent.sock"
AGENT_READY="$ROOT/controlled-agent.ready"
python3 - "$AGENT_SOCKET" "$AGENT_READY" <<'PY' &
import os
import socket
import sys
import time

agent = socket.socket(socket.AF_UNIX)
agent.bind(sys.argv[1])
agent.listen()
with open(sys.argv[2], "w", encoding="utf-8") as ready:
    ready.write("ready\n")
while True:
    time.sleep(60)
PY
AGENT_PID=$!
for _ in $(seq 1 200); do
  [ -S "$AGENT_SOCKET" ] && [ -f "$AGENT_READY" ] && break
  sleep 0.01
done
[ -S "$AGENT_SOCKET" ]
[ -f "$AGENT_READY" ]
AGENT_ENV_RESULT="$ROOT/agent-env-result"
AGENT_ENV_HOOK="$ROOT/agent-env-hook.sh"
cat > "$AGENT_ENV_HOOK" <<EOF
#!/bin/sh
printf '%s|%s\n' "\${SSH_AUTH_SOCK:-missing}" "\${SHADOW_SYNC_UNRELATED_SENTINEL:-absent}" > "$AGENT_ENV_RESULT"
exit 0
EOF
chmod 700 "$AGENT_ENV_HOOK"
git_at "$PRIMARY" config core.fsmonitor "$AGENT_ENV_HOOK"

APPKIT_RESULT="$ROOT/appkit.json"
SSH_AUTH_SOCK="$AGENT_SOCKET" \
  SHADOW_SYNC_UNRELATED_SENTINEL="must-not-survive" \
  run_appkit_driver "$PRIMARY" "$APPKIT_RESULT"
kill "$AGENT_PID"
wait "$AGENT_PID" >/dev/null 2>&1 || true
AGENT_PID=""
AGENT_ENV_OBSERVED="$(cat "$AGENT_ENV_RESULT")"
test "$AGENT_ENV_OBSERVED" = "$AGENT_SOCKET|absent" || {
  printf 'm1-native-e2e: controlled agent environment mismatch: %s\n' \
    "$AGENT_ENV_OBSERVED" >&2
  exit 1
}
git_at "$PRIMARY" config --unset core.fsmonitor
python3 - "$APPKIT_RESULT" "$BEFORE" "$TARGET" <<'PY'
import json
import sys

path, before, target = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    result = json.load(handle)
assert result["schema"] == "shadow-sync-m1-appkit-result/v1", result
for field in (
    "noDefaultSelection",
    "confirmationAccepted",
    "backAndCancelExercised",
    "confirmationPresentationExact",
    "openLogUsedIsolatedPath",
    "menuContentsExact",
    "selectionPresentationExact",
    "selectionControlsExact",
    "multiSelectionPresentationExact",
    "multiRowProgressExact",
    "discoveryPresentationExact",
    "resultLabelMappingExact",
    "statusSymbolMappingExact",
    "workerEnvironmentExact",
    "ownershipFailureLifecycleExact",
    "stopLifecycleStateExact",
    "controllerStopRaceExact",
    "workerStopSingleFlightExact",
    "lifecycleInvocationAdmissionExact",
    "takeoverTransitionExact",
    "cancelDuringWorkerEventsExact",
    "reportPersistedAfterClose",
    "workerDrained",
    "quitExercised",
):
    assert result[field] is True, (field, result)
assert result["mainRunLoopTicks"] > 0, result
row = result["report"]["results"][0]
assert row["code"] == "UPDATED", row
assert row["beforeCommit"] == before, row
assert row["targetCommit"] == target, row
assert row["afterCommit"] == target, row
assert row["fetched"] is True and row["mainUpdated"] is True, row
phases = result["phases"]
cursor = 0
for required in ("checking", "fetching", "updating", "complete"):
    cursor = phases.index(required, cursor) + 1
assert result["summary"].startswith("Run complete"), result
PY
test "$(git_at "$PRIMARY" rev-parse HEAD)" = "$TARGET"

EQUAL="$ROOT/equal.json"
run_harness "$PRIMARY" "$EQUAL"
assert_result "$EQUAL" ALREADY_CURRENT true false
test "$(git_at "$PRIMARY" rev-parse HEAD)" = "$TARGET"

CRASH_REPOSITORY="$ROOT/crash-repository"
fixture_git clone --quiet "$REMOTE" "$CRASH_REPOSITORY"
git_at "$CRASH_REPOSITORY" remote set-url origin "$LOGICAL_ORIGIN"
CRASH_BEFORE="$(git_at "$CRASH_REPOSITORY" rev-parse HEAD)"
CRASH_SENTINEL="$ROOT/crash-fsmonitor-started"
CRASH_HOOK="$ROOT/crash-fsmonitor"
cat > "$CRASH_HOOK" <<EOF
#!/bin/sh
printf '%s\n' "\$\$" > "$CRASH_SENTINEL"
sleep 3
printf '\n'
EOF
chmod 700 "$CRASH_HOOK"
git_at "$CRASH_REPOSITORY" config core.fsmonitor "$CRASH_HOOK"
CRASH_RESULT="$ROOT/appkit-crash.json"
run_appkit_driver "$CRASH_REPOSITORY" "$CRASH_RESULT" "$CRASH_SENTINEL"
python3 - "$CRASH_RESULT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
for field in (
    "backAndCancelExercised",
    "confirmationPresentationExact",
    "openLogUsedIsolatedPath",
    "menuContentsExact",
    "selectionPresentationExact",
    "selectionControlsExact",
    "multiSelectionPresentationExact",
    "multiRowProgressExact",
    "discoveryPresentationExact",
    "resultLabelMappingExact",
    "statusSymbolMappingExact",
    "workerEnvironmentExact",
    "ownershipFailureLifecycleExact",
    "stopLifecycleStateExact",
    "controllerStopRaceExact",
    "workerStopSingleFlightExact",
    "lifecycleInvocationAdmissionExact",
    "takeoverTransitionExact",
):
    assert result[field] is True, (field, result)
assert result["needsAttention"] is False, result
assert result["workerDrained"] is True, result
assert result["partialLogRecordCount"] > 0, result
report = result["report"]
assert report["summaryOverride"] == "Previous run interrupted — review required", report
assert [row["code"] for row in report["results"]] == ["CANCELLED_PENDING"], report
assert result["reportPersistedAfterClose"] is True, result
assert result["leaseBlockedAfterWorkerCrash"] is False, result
assert result["leaseReleasedAfterGitExit"] is True, result
assert result["childDrainedAfterWorkerCrash"] is True, result
assert result["recoveryEvidenceBlockedUntilAcknowledged"] is True, result
assert result["recoveryAcknowledgementEnabledSelection"] is True, result
assert result["quitExercised"] is True, result
PY
test "$(git_at "$CRASH_REPOSITORY" rev-parse HEAD)" = "$CRASH_BEFORE"

CUSTOM="$ROOT/custom"
UPLOADPACK="$ROOT/uploadpack"
DOTTED_UPLOADPACK="$ROOT/dotted-uploadpack"
REPLACED="$ROOT/replaced"
GRAFTED="$ROOT/grafted"
ALTERNATE="$ROOT/alternate"
PACKED_REPLACE="$ROOT/packed-replace"
WORKTREE_CONFIG="$ROOT/worktree-config"
EXTENSION_CONFIG="$ROOT/extension-config"
REWRITTEN="$ROOT/rewritten"
for repository in \
  "$CUSTOM" "$UPLOADPACK" "$DOTTED_UPLOADPACK" "$REPLACED" "$GRAFTED" "$ALTERNATE" \
  "$PACKED_REPLACE" "$WORKTREE_CONFIG" "$EXTENSION_CONFIG" \
  "$REWRITTEN"; do
  fixture_git clone --quiet "$REMOTE" "$repository"
  git_at "$repository" remote set-url origin "$LOGICAL_ORIGIN"
done
printf 'third\n' >> "$SEED/value.txt"
git_at "$SEED" commit --quiet -am third
git_at "$SEED" push --quiet origin main
THIRD="$(git_at "$SEED" rev-parse HEAD)"

git_at "$CUSTOM" config core.sshCommand /usr/bin/false
run_harness "$CUSTOM" "$ROOT/custom.json"
assert_result "$ROOT/custom.json" FAILED_INSPECTION false false
test "$(git_at "$CUSTOM" rev-parse HEAD)" != "$THIRD"

git_at "$UPLOADPACK" config remote.origin.uploadpack /usr/bin/false
run_harness "$UPLOADPACK" "$ROOT/uploadpack.json"
assert_result "$ROOT/uploadpack.json" FAILED_INSPECTION false false
test "$(git_at "$UPLOADPACK" rev-parse HEAD)" != "$THIRD"

cat >> "$DOTTED_UPLOADPACK/.git/config" <<'EOF'
[remote.origin]
	uploadpack = /usr/bin/false
EOF
run_harness "$DOTTED_UPLOADPACK" "$ROOT/dotted-uploadpack.json"
assert_result "$ROOT/dotted-uploadpack.json" FAILED_INSPECTION false false
test "$(git_at "$DOTTED_UPLOADPACK" rev-parse HEAD)" != "$THIRD"

mkdir -p "$REPLACED/.git/refs/replace"
run_harness "$REPLACED" "$ROOT/replaced.json"
assert_result "$ROOT/replaced.json" FAILED_INSPECTION false false
test "$(git_at "$REPLACED" rev-parse HEAD)" != "$THIRD"

printf '%s\n' "$(git_at "$GRAFTED" rev-parse HEAD)" > "$GRAFTED/.git/info/grafts"
run_harness "$GRAFTED" "$ROOT/grafted.json"
assert_result "$ROOT/grafted.json" FAILED_INSPECTION false false
test "$(git_at "$GRAFTED" rev-parse HEAD)" != "$THIRD"

printf '%s\n' "$REMOTE/objects" > "$ALTERNATE/.git/objects/info/alternates"
run_harness "$ALTERNATE" "$ROOT/alternate.json"
assert_result "$ROOT/alternate.json" FAILED_INSPECTION false false
test "$(git_at "$ALTERNATE" rev-parse HEAD)" != "$THIRD"

printf '%s refs/replace/race\n' "$(git_at "$PACKED_REPLACE" rev-parse HEAD)" \
  > "$PACKED_REPLACE/.git/packed-refs"
run_harness "$PACKED_REPLACE" "$ROOT/packed-replace.json"
assert_result "$ROOT/packed-replace.json" FAILED_INSPECTION false false

printf '[core]\n' > "$WORKTREE_CONFIG/.git/config.worktree"
run_harness "$WORKTREE_CONFIG" "$ROOT/worktree-config.json"
assert_result "$ROOT/worktree-config.json" FAILED_INSPECTION false false

git_at "$EXTENSION_CONFIG" config extensions.worktreeConfig true
run_harness "$EXTENSION_CONFIG" "$ROOT/extension-config.json"
assert_result "$ROOT/extension-config.json" FAILED_INSPECTION false false

cat > "$ROOT/home/.gitconfig" <<'EOF'
[url "git@github.com:other-owner/other-repository.git"]
	insteadOf = git@github.com:fixture-owner/fixture-repo.git
EOF
run_harness "$REWRITTEN" "$ROOT/rewritten.json"
assert_result "$ROOT/rewritten.json" SKIPPED_ORIGIN_CHANGED false false
test "$(git_at "$REWRITTEN" rev-parse HEAD)" != "$THIRD"
rm -f "$ROOT/home/.gitconfig"

LOG="$ROOT/state/shadow-sync/latest.log"
test -f "$LOG"
test "$(stat -f '%Lp' "$LOG")" = 600
test "$(stat -f '%l' "$LOG")" = 1
for sentinel in \
  "$ROOT/forbidden-git-trace" \
  "$ROOT/forbidden-trace2" \
  "$ROOT/forbidden-redirect" \
  "$ROOT/forbidden-askpass" \
  "$ROOT/forbidden-ssh-command"; do
  test ! -e "$sentinel"
done

PRODUCTION_OUTPUT="$ROOT/production-output"
"$CAPABILITY/scripts/build-app.sh" \
  --scratch-path "$ROOT/production-swift" \
  --output-dir "$PRODUCTION_OUTPUT" >/dev/null
PRODUCTION_EXECUTABLE="$PRODUCTION_OUTPUT/ShadowSync.app/Contents/MacOS/ShadowSync"
codesign --verify --strict --verbose=2 "$PRODUCTION_OUTPUT/ShadowSync.app"
run_sandboxed_app "$PRODUCTION_EXECUTABLE" --check >/dev/null
python3 - "$PRODUCTION_OUTPUT/ShadowSync.app" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
expected = {
    ".": ("directory", 0o700),
    "Contents": ("directory", 0o700),
    "Contents/MacOS": ("directory", 0o700),
    "Contents/MacOS/ShadowSync": ("file", 0o700),
    "Contents/Resources": ("directory", 0o700),
    "Contents/Resources/ShadowSync.icns": ("file", 0o600),
    "Contents/Resources/THIRD_PARTY_NOTICES.md": ("file", 0o600),
    "Contents/Resources/com.kleinperkins.shadow-sync.plist.template": ("file", 0o600),
    "Contents/Info.plist": ("file", 0o600),
    "Contents/_CodeSignature": ("directory", 0o700),
    "Contents/_CodeSignature/CodeResources": ("file", 0o600),
}
observed = {}
for current, directories, files in os.walk(root, followlinks=False):
    directories.sort()
    files.sort()
    relative_current = os.path.relpath(current, root)
    info = os.lstat(current)
    assert not stat.S_ISLNK(info.st_mode), relative_current
    observed[relative_current] = ("directory", stat.S_IMODE(info.st_mode))
    for name in directories + files:
        path = os.path.join(current, name)
        relative = os.path.relpath(path, root)
        info = os.lstat(path)
        assert not stat.S_ISLNK(info.st_mode), relative
        if stat.S_ISREG(info.st_mode):
            kind = "file"
        elif stat.S_ISDIR(info.st_mode):
            kind = "directory"
        else:
            kind = "other"
        observed[relative] = (kind, stat.S_IMODE(info.st_mode))
assert observed == expected, (observed, expected)
PY
PRODUCTION_HASH_BEFORE="$(shasum -a 256 "$PRODUCTION_EXECUTABLE" | awk '{print $1}')"
if "$CAPABILITY/scripts/build-app.sh" \
  --scratch-path "$ROOT/refused-production-swift" \
  --output-dir "$PRODUCTION_OUTPUT" >"$ROOT/refused-build.log" 2>&1; then
  printf 'm1-native-e2e: build replaced a pre-existing app destination\n' >&2
  exit 1
fi
test "$(shasum -a 256 "$PRODUCTION_EXECUTABLE" | awk '{print $1}')" = "$PRODUCTION_HASH_BEFORE"
if strings "$PRODUCTION_EXECUTABLE" |
  rg -q 'SHADOW_SYNC_TESTING|shadow-sync-m1-test-channel|shadow-sync-m1-appkit-channel|shadow-sync-m1-lock-holder|shadow-sync-m1-orphan-snapshot|shadow-sync-m5-ui-channel|shadow-sync-m5-practical-ui-channel|shadow-sync-m5-status-item-guidance-channel|shadow-sync-m5-latency-channel|shadow-sync-m1-harness|shadow-sync-m5|localBareRemote|isolatedRoot|M1SelfTestRunner|M2PracticalLiveDiagnosticRow|M5SelfTestRunner|M5AppKitDriver|models-origins-redaction|ShadowSyncSelfTest|--live-diagnostic|--test-root|--scratch-path|shadowSync\.m1TestRoot|shadowSync\.m1FDAudit'; then
  printf 'm1-native-e2e: production bundle contains a test-only control symbol\n' >&2
  exit 1
fi

BOOT_HOME="$ROOT/bootstrap-home"
BOOT_REPO="$ROOT/bootstrap-primary"
mkdir -p "$BOOT_HOME" "$BOOT_REPO/global/tools" "$BOOT_REPO/scripts"
cp "$CAPABILITY/../../../bootstrap.sh" "$BOOT_REPO/bootstrap.sh"
cp "$CAPABILITY/../../../scripts/capability_meta.py" "$BOOT_REPO/scripts/capability_meta.py"
cp -R "$CAPABILITY" "$BOOT_REPO/global/tools/shadow-sync"
BOOT_SENTINEL="$ROOT/bootstrap-installer-invoked"
cat > "$BOOT_REPO/global/tools/shadow-sync/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${SHADOW_SYNC_BOOTSTRAP_SENTINEL:?}"
touch "$SHADOW_SYNC_BOOTSTRAP_SENTINEL"
exit 97
EOF
chmod +x "$BOOT_REPO/global/tools/shadow-sync/install.sh"
fixture_git -C "$BOOT_REPO" init --quiet --initial-branch=main
SHADOW_SYNC_BOOTSTRAP_SENTINEL="$BOOT_SENTINEL" \
  HOME="$BOOT_HOME" \
  bash "$BOOT_REPO/bootstrap.sh" --reconcile --dry-run > "$ROOT/bootstrap.log"
rg -q 'RECORD shadow-sync \(tool; no PATH install\)' "$ROOT/bootstrap.log"
rg -q 'INSTALL shadow-sync \(flavor=1 post_mgmt=launchd\)' "$ROOT/bootstrap.log"
test ! -e "$BOOT_SENTINEL"

printf 'm1-native-e2e: PASS\n'
printf 'behind-before=%s\n' "$BEFORE"
printf 'captured-target=%s\n' "$TARGET"
printf 'updated-after=%s\n' "$(git_at "$PRIMARY" rev-parse HEAD)"
printf 'equal-result=ALREADY_CURRENT\n'
printf 'transport-change-unit=REFUSED\n'
printf 'pre-network-refusals=custom-ssh,upload-pack,dotted-upload-pack,replacement,graft,alternate,effective-url\n'
printf 'log-mode=600 log-links=1\n'
printf 'production-test-symbols=absent\n'
printf 'appkit-driven-flow=PASS\n'
printf 'bootstrap=RECORD+INSTALL installer-not-invoked\n'
printf 'transport-evidence=enforced-sandbox-network-denial+static-closed-environment+local-file-mapping\n'
printf 'live-state-snapshot=UNCHANGED\n'
printf 'real-dev-git-control-snapshot=UNCHANGED\n'
printf 'production-bundle-allowlist=EXACT\n'
