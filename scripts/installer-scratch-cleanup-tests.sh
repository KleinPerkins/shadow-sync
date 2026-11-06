#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
REPO="$(cd "$CAPABILITY/../../.." && pwd)"
# shellcheck disable=SC1091 # Resolved from the runtime capability root.
. "$CAPABILITY/scripts/owned-cleanup.sh"
ROOT="$(mktemp -d /private/tmp/shadow-sync-installer-cleanup.XXXXXX)"
chmod 700 "$ROOT"
REGISTERED_ROOTS="$ROOT/registered-roots"
: >"$REGISTERED_ROOTS"

remove_case_root() {
  local root="$1" parent_device
  [ ! -e "$root" ] && [ ! -L "$root" ] && return 0
  case "$root" in /private/tmp/shadow-sync-m6-live.*) ;; *) return 1 ;; esac
  if [ -L "$root" ]; then
    /bin/rm -f -- "$root"
    return
  fi
  [ -d "$root" ] && [ "$(cd -P "$root" && pwd)" = "$root" ] \
    && [ "$(stat -f '%u' "$root")" = "$(id -u)" ] || return 1
  parent_device="$(stat -f '%d' /private/tmp)"
  [ "$(stat -f '%d' "$root")" = "$parent_device" ] || return 1
  /bin/rm -rf -- "$root"
}

cleanup() {
  local status=$? root safe=1
  trap - EXIT INT TERM
  if [ -f "$REGISTERED_ROOTS" ]; then
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      remove_case_root "$root" || safe=0
    done <"$REGISTERED_ROOTS"
  fi
  shadow_sync_reap_owned_root_helpers "$ROOT" installer-scratch-cleanup-tests 1 || safe=0
  if [ "$safe" -eq 1 ]; then
    shadow_sync_remove_owned_root "$ROOT" installer-scratch-cleanup-tests || status=1
  else
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

register_root() {
  local root="$1"
  case "$root" in /private/tmp/shadow-sync-m6-live.*) ;;
    *) printf 'installer-scratch-cleanup-tests: unexpected root: %s\n' "$root" >&2; return 1 ;;
  esac
  printf '%s\n' "$root" >>"$REGISTERED_ROOTS"
}

assert_root_absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || {
    printf 'installer-scratch-cleanup-tests: root leaked: %s\n' "$1" >&2
    return 1
  }
}

snapshot_live() {
  python3 - "$1" <<'PY'
import hashlib
import json
import os
import pwd
import stat
import sys

home = pwd.getpwuid(os.geteuid()).pw_dir
roots = [
    os.path.join(home, "Applications", "ShadowSync.app"),
    os.path.join(home, "Library", "LaunchAgents", "com.kleinperkins.shadow-sync.plist"),
    os.path.join(home, ".local", "state", "shadow-sync"),
]
rows = {}
def visit(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        rows[path] = None
        return
    row = {
        "mode": stat.S_IMODE(info.st_mode),
        "type": stat.S_IFMT(info.st_mode),
        "uid": info.st_uid,
        "gid": info.st_gid,
        "nlink": info.st_nlink,
        "size": info.st_size,
    }
    if stat.S_ISREG(info.st_mode):
        with open(path, "rb") as handle:
            row["sha256"] = hashlib.sha256(handle.read()).hexdigest()
    rows[path] = row
    if stat.S_ISDIR(info.st_mode):
        for name in sorted(os.listdir(path)):
            visit(os.path.join(path, name))
for root in roots:
    visit(root)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(rows, handle, sort_keys=True)
    handle.write("\n")
PY
}

assert_only_sibling_root() {
  python3 - "$1" <<'PY'
import glob
import sys

expected = [sys.argv[1]]
actual = sorted(glob.glob("/private/tmp/shadow-sync-m6-live.*"))
if actual != expected:
    raise SystemExit(f"unexpected installer scratch roots: {actual!r}")
PY
}

write_fake_builder() {
  cat >"$1" <<'FAKE'
#!/bin/bash
set -euo pipefail
SCRATCH=""
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scratch-path) SCRATCH="$2"; shift 2 ;;
    --output-dir) OUTPUT="$2"; shift 2 ;;
    --source-revision|--source-input-sha256|--release-contract-sha256) shift 2 ;;
    --testing) shift ;;
    *) printf 'fake-build: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$SCRATCH" ] && [ -n "$OUTPUT" ]
ROOT="$(dirname "$SCRATCH")"
printf '%s\n' "$ROOT" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"
if [ -n "${SHADOW_SYNC_FIXTURE_BUILDER_RECORD:-}" ]; then
  printf 'builder-invoked\n' >>"$SHADOW_SYNC_FIXTURE_BUILDER_RECORD"
fi
if [ -n "${SHADOW_SYNC_FIXTURE_CREATED_IDENTITY_RECORD:-}" ]; then
  stat -f '%N %u %d %i %Lp' "$ROOT" >"$SHADOW_SYNC_FIXTURE_CREATED_IDENTITY_RECORD"
fi

make_app() {
  local app executable
  mkdir -m 700 "$SCRATCH" "$OUTPUT"
  app="$OUTPUT/ShadowSync.app"
  executable="$app/Contents/MacOS/ShadowSync"
  mkdir -m 700 -p "$(dirname "$executable")"
  cat >"$executable" <<'APP'
#!/bin/bash
set -euo pipefail
if [ -n "${SHADOW_SYNC_FIXTURE_ACTION_RECORD:-}" ]; then
  printf '%s\n' "$*" >>"$SHADOW_SYNC_FIXTURE_ACTION_RECORD"
fi
exit 0
APP
  chmod 700 "$executable"
}

case "${SHADOW_SYNC_FIXTURE_MODE:-success}" in
  success)
    make_app
    printf '%s\n' "$OUTPUT/ShadowSync.app"
    ;;
  fail-after-build)
    [ -f "$ROOT/capture/global/tools/shadow-sync/install.sh" ]
    make_app
    printf 'capture-and-build-complete\n' >"$SHADOW_SYNC_FIXTURE_STAGE_RECORD"
    exit 92
    ;;
  wait-term)
    mkdir -m 700 "$SCRATCH"
    printf '%s\n' "$$" >"$SHADOW_SYNC_FIXTURE_BUILD_PID_RECORD"
    /bin/sleep 300 &
    child=$!
    printf '%s\n' "$child" >"$SHADOW_SYNC_FIXTURE_CHILD_PID_RECORD"
    wait "$child"
    ;;
  replace-directory)
    old_inode="$(stat -f '%i' "$ROOT")"
    /bin/rm -rf -- "$ROOT"
    mkdir -m 700 "$ROOT"
    printf 'replacement\n' >"$ROOT/replacement-marker"
    new_inode="$(stat -f '%i' "$ROOT")"
    printf '%s %s\n' "$old_inode" "$new_inode" >"$SHADOW_SYNC_FIXTURE_IDENTITY_RECORD"
    exit 94
    ;;
  replace-symlink)
    /bin/rm -rf -- "$ROOT"
    ln -s "$SHADOW_SYNC_FIXTURE_SYMLINK_TARGET" "$ROOT"
    exit 93
    ;;
  *)
    printf 'fake-build: unexpected mode\n' >&2
    exit 2
    ;;
esac
FAKE
  chmod 700 "$1"
}

make_base_fixture() {
  local fixture="$1"
  mkdir -m 700 "$fixture"
  mkdir -m 700 "$fixture/global" "$fixture/.github"
  mkdir -m 700 "$fixture/global/tools" "$fixture/.github/scripts"
  cp -R "$CAPABILITY" "$fixture/global/tools/shadow-sync"
  cp "$REPO/.eco-registry.lock" "$fixture/.eco-registry.lock"
  cp "$REPO/.github/scripts/eco-lock.sh" "$fixture/.github/scripts/eco-lock.sh"
  write_fake_builder "$fixture/global/tools/shadow-sync/scripts/build-app.sh"
  python3 - "$fixture/global/tools/shadow-sync/install.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
start = text.index("effective_home() {\n")
end = text.index("\n}\n\nlive_doctor()", start) + 2
replacement = "effective_home() {\n  printf '%s\\n' \"$SHADOW_SYNC_FIXTURE_HOME\"\n}"
path.write_text(text[:start] + replacement + text[end:], encoding="utf-8")
PY
  git -C "$fixture" init -q -b main
  git -C "$fixture" config user.name "ShadowSync Test"
  git -C "$fixture" config user.email "shadow-sync@test.invalid"
  git -C "$fixture" add .eco-registry.lock .github/scripts/eco-lock.sh global/tools/shadow-sync
  git -C "$fixture" commit -q -m "fixture source"
  git -C "$fixture" remote add origin git@github.com:fixture-owner/skills.git
  git -C "$fixture" update-ref refs/remotes/origin/main HEAD
}

make_variant() {
  local base="$1" fixture="$2" kind="$3"
  cp -R "$base" "$fixture"
  python3 - "$fixture/global/tools/shadow-sync/install.sh" "$kind" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
text = path.read_text(encoding="utf-8")
capture = '  capture="$root/capture"\n'
chmod = '  chmod 700 "$root"\n'
root_stat = '  root_identity="$(stat -f \'%u %d %i %Lp\' "$root")"\n'
parent_stat = '  parent_identity="$(stat -f \'%d %i\' /private/tmp)"\n'
injections = {
    "fail-after-create": (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        "  return 91\n"
    ),
    "wrong-owner": (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        "  root_uid=$((root_uid + 1))\n"
        "  return 95\n"
    ),
    "wrong-parent-device": (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        "  parent_device=$((parent_device + 1))\n"
        "  return 96\n"
    ),
}
if kind in injections:
    if text.count(capture) != 1:
        raise SystemExit("fixture capture seam changed")
    text = text.replace(capture, injections[kind] + capture, 1)
elif kind == "fail-chmod":
    replacement = (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        '  chmod 700 "$SHADOW_SYNC_FIXTURE_MISSING_PATH"\n'
    )
    if text.count(chmod) != 1:
        raise SystemExit("fixture chmod seam changed")
    text = text.replace(chmod, replacement, 1)
elif kind == "fail-root-stat":
    replacement = (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        '  root_identity="$(stat -f \'%u %d %i %Lp\' "$SHADOW_SYNC_FIXTURE_MISSING_PATH")"\n'
    )
    if text.count(root_stat) != 1:
        raise SystemExit("fixture root-stat seam changed")
    text = text.replace(root_stat, replacement, 1)
elif kind == "fail-parent-stat":
    replacement = (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        '  parent_identity="$(stat -f \'%d %i\' "$SHADOW_SYNC_FIXTURE_MISSING_PATH")"\n'
    )
    if text.count(parent_stat) != 1:
        raise SystemExit("fixture parent-stat seam changed")
    text = text.replace(parent_stat, replacement, 1)
elif kind == "pre-identity-nonempty":
    replacement = (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        '  printf "preserve\\n" >"$root/pre-identity-marker"\n'
        "  return 83\n"
    )
    if text.count(root_stat) != 1:
        raise SystemExit("fixture root-stat seam changed")
    text = text.replace(root_stat, replacement + root_stat, 1)
elif kind == "pre-identity-symlink":
    replacement = (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        '  /bin/rmdir "$root"\n'
        '  ln -s "$SHADOW_SYNC_FIXTURE_SYMLINK_TARGET" "$root"\n'
        "  return 84\n"
    )
    if text.count(root_stat) != 1:
        raise SystemExit("fixture root-stat seam changed")
    text = text.replace(root_stat, replacement + root_stat, 1)
elif kind == "pre-identity-replaced":
    replacement = (
        '  printf "%s\\n" "$root" >>"$SHADOW_SYNC_FIXTURE_ROOT_RECORD"\n'
        '  old_inode="$(stat -f \'%i\' "$root")"\n'
        '  /bin/rmdir "$root"\n'
        '  mkdir -m 700 "$root"\n'
        '  new_inode="$(stat -f \'%i\' "$root")"\n'
        '  printf "%s %s\\n" "$old_inode" "$new_inode" >"$SHADOW_SYNC_FIXTURE_IDENTITY_RECORD"\n'
        "  return 85\n"
    )
    if text.count(parent_stat) != 1:
        raise SystemExit("fixture parent-stat seam changed")
    text = text.replace(parent_stat, replacement + parent_stat, 1)
elif kind == "repeat":
    dispatch = 'case "${1:-}" in\n'
    if text.count(dispatch) != 1:
        raise SystemExit("fixture dispatch seam changed")
    text = text[:text.index(dispatch)] + (
        "trap 'printf \"unrelated-exit\\\\n\" >>\"$SHADOW_SYNC_FIXTURE_TRAP_RECORD\"' EXIT\n"
        "build_captured_release --check-only\n"
        "build_captured_release --check-only\n"
    )
else:
    raise SystemExit(f"unexpected variant: {kind}")
path.write_text(text, encoding="utf-8")
PY
  git -C "$fixture" add global/tools/shadow-sync/install.sh
  git -C "$fixture" commit -q -m "fixture $kind"
  git -C "$fixture" update-ref refs/remotes/origin/main HEAD
}

single_recorded_root() {
  local record="$1"
  [ -f "$record" ] && [ "$(wc -l <"$record" | tr -d ' ')" -eq 1 ] || {
    printf 'installer-scratch-cleanup-tests: expected one root record\n' >&2
    return 1
  }
  cat "$record"
}

expect_failure() {
  local log="$1"
  shift
  if "$@" >"$log" 2>&1; then
    printf 'installer-scratch-cleanup-tests: expected failure\n' >&2
    return 1
  fi
}

python3 - <<'PY'
import glob
matches = glob.glob("/private/tmp/shadow-sync-m6-live.*")
if matches:
    raise SystemExit(f"pre-existing installer scratch roots: {matches!r}")
PY
snapshot_live "$ROOT/live-before.json"
UNRELATED="/private/tmp/shadow-sync-m6-live.UNRELATED-$$"
test ! -e "$UNRELATED" && test ! -L "$UNRELATED"
mkdir -m 700 "$UNRELATED"
printf 'unrelated\n' >"$UNRELATED/marker"
register_root "$UNRELATED"

BASE="$ROOT/base"
make_base_fixture "$BASE"
INSTALL="$BASE/global/tools/shadow-sync/install.sh"

started=$SECONDS
record="$ROOT/success.roots"
action="$ROOT/success.actions"
builder="$ROOT/success.builder"
created_identity="$ROOT/success.created-identity"
success_home="$ROOT/success-home"
mkdir -m 700 "$success_home"
env SHADOW_SYNC_FIXTURE_MODE=success SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  SHADOW_SYNC_FIXTURE_ACTION_RECORD="$action" SHADOW_SYNC_FIXTURE_BUILDER_RECORD="$builder" \
  SHADOW_SYNC_FIXTURE_CREATED_IDENTITY_RECORD="$created_identity" \
  SHADOW_SYNC_FIXTURE_HOME="$success_home" "$INSTALL" >"$ROOT/success.log" 2>&1
root="$(single_recorded_root "$record")"
register_root "$root"
assert_root_absent "$root"
[ "$(grep -c '^builder-invoked$' "$builder")" -eq 1 ]
[ "$(wc -l <"$action" | tr -d ' ')" -eq 1 ]
grep -q '^--lifecycle-reconcile ' "$action"
read -r created_root created_uid created_device created_inode created_mode <"$created_identity"
[ "$created_root" = "$root" ] && [ "$created_uid" = "$(id -u)" ] \
  && [ "$created_device" = "$(stat -f '%d' /private/tmp)" ] \
  && [ -n "$created_inode" ] && [ "$created_mode" = 700 ]
[ ! -e "$success_home/Applications" ] && [ ! -L "$success_home/Applications" ]
[ -f "$UNRELATED/marker" ]
printf 'installer-scratch-cleanup-tests: deterministic-success-cleanup=PASS duration=%ss\n' \
  "$((SECONDS - started))"

started=$SECONDS
for kind in fail-chmod fail-root-stat fail-parent-stat; do
  fixture="$ROOT/$kind"
  make_variant "$BASE" "$fixture" "$kind"
  record="$ROOT/$kind.roots"
  missing="$ROOT/$kind-missing"
  test ! -e "$missing" && test ! -L "$missing"
  expect_failure "$ROOT/$kind.log" \
    env SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" SHADOW_SYNC_FIXTURE_MISSING_PATH="$missing" \
    "$fixture/global/tools/shadow-sync/install.sh" --build-release-check
  root="$(single_recorded_root "$record")"
  register_root "$root"
  assert_root_absent "$root"
done
printf 'installer-scratch-cleanup-tests: pre-identity-empty-failures=PASS duration=%ss\n' \
  "$((SECONDS - started))"

started=$SECONDS
NONEMPTY="$ROOT/pre-identity-nonempty"
make_variant "$BASE" "$NONEMPTY" pre-identity-nonempty
record="$ROOT/pre-identity-nonempty.roots"
expect_failure "$ROOT/pre-identity-nonempty.log" \
  env SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  "$NONEMPTY/global/tools/shadow-sync/install.sh" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
[ -f "$root/pre-identity-marker" ]
grep -q 'refusing non-empty pre-identity captured-release cleanup' \
  "$ROOT/pre-identity-nonempty.log"
remove_case_root "$root"

PRE_SYMLINK_TARGET="$ROOT/pre-identity-symlink-target"
mkdir -m 700 "$PRE_SYMLINK_TARGET"
printf 'preserve\n' >"$PRE_SYMLINK_TARGET/marker"
PRE_SYMLINK="$ROOT/pre-identity-symlink"
make_variant "$BASE" "$PRE_SYMLINK" pre-identity-symlink
record="$ROOT/pre-identity-symlink.roots"
expect_failure "$ROOT/pre-identity-symlink.log" \
  env SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" SHADOW_SYNC_FIXTURE_SYMLINK_TARGET="$PRE_SYMLINK_TARGET" \
  "$PRE_SYMLINK/global/tools/shadow-sync/install.sh" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
[ -L "$root" ] && [ "$(readlink "$root")" = "$PRE_SYMLINK_TARGET" ]
grep -q '^preserve$' "$PRE_SYMLINK_TARGET/marker"
grep -q 'refusing pre-identity cleanup of an unexpected captured-release root' \
  "$ROOT/pre-identity-symlink.log"
remove_case_root "$root"

PRE_REPLACED="$ROOT/pre-identity-replaced"
make_variant "$BASE" "$PRE_REPLACED" pre-identity-replaced
record="$ROOT/pre-identity-replaced.roots"
identity="$ROOT/pre-identity-replaced.identity"
expect_failure "$ROOT/pre-identity-replaced.log" \
  env SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" SHADOW_SYNC_FIXTURE_IDENTITY_RECORD="$identity" \
  "$PRE_REPLACED/global/tools/shadow-sync/install.sh" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
[ -d "$root" ] && [ ! -L "$root" ] && [ -z "$(ls -A "$root")" ]
read -r old_inode new_inode <"$identity"
[ "$old_inode" != "$new_inode" ]
grep -q 'refusing pre-identity cleanup after captured-release root changed' \
  "$ROOT/pre-identity-replaced.log"
remove_case_root "$root"
printf 'installer-scratch-cleanup-tests: pre-identity-refusals=PASS duration=%ss\n' \
  "$((SECONDS - started))"

started=$SECONDS
IMMEDIATE="$ROOT/fail-after-create"
make_variant "$BASE" "$IMMEDIATE" fail-after-create
record="$ROOT/fail-after-create.roots"
expect_failure "$ROOT/fail-after-create.log" \
  env SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  "$IMMEDIATE/global/tools/shadow-sync/install.sh" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
assert_root_absent "$root"
printf 'installer-scratch-cleanup-tests: immediate-failure=PASS duration=%ss\n' "$((SECONDS - started))"

started=$SECONDS
record="$ROOT/fail-after-build.roots"
stage="$ROOT/fail-after-build.stage"
expect_failure "$ROOT/fail-after-build.log" \
  env SHADOW_SYNC_FIXTURE_MODE=fail-after-build SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  SHADOW_SYNC_FIXTURE_STAGE_RECORD="$stage" "$INSTALL" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
assert_root_absent "$root"
grep -q '^capture-and-build-complete$' "$stage"
printf 'installer-scratch-cleanup-tests: post-build-failure=PASS duration=%ss\n' "$((SECONDS - started))"

started=$SECONDS
record="$ROOT/term.roots"
build_pid_record="$ROOT/term.build-pid"
child_pid_record="$ROOT/term.child-pid"
python3 - "$INSTALL" "$record" "$build_pid_record" "$child_pid_record" \
  "$ROOT/term.log" "$ROOT/term-identities.log" <<'PY'
import os
import signal
import subprocess
import sys
import time

installer, roots, build_record, child_record, log_path, identity_path = sys.argv[1:]
env = os.environ.copy()
env.update({
    "SHADOW_SYNC_FIXTURE_MODE": "wait-term",
    "SHADOW_SYNC_FIXTURE_ROOT_RECORD": roots,
    "SHADOW_SYNC_FIXTURE_BUILD_PID_RECORD": build_record,
    "SHADOW_SYNC_FIXTURE_CHILD_PID_RECORD": child_record,
})
with open(log_path, "wb") as log:
    process = subprocess.Popen(
        [installer, "--build-release-check"],
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if all(os.path.isfile(path) for path in (roots, build_record, child_record)):
                break
            if process.poll() is not None:
                raise SystemExit("TERM fixture exited before child identity was recorded")
            time.sleep(0.02)
        else:
            raise SystemExit("TERM fixture did not reach its controlled wait")
        build_pid = int(open(build_record, encoding="utf-8").read().strip())
        child_pid = int(open(child_record, encoding="utf-8").read().strip())
        identities = subprocess.check_output(
            ["/bin/ps", "-p", f"{process.pid},{build_pid},{child_pid}",
             "-o", "pid=,ppid=,uid=,command="],
            text=True,
        )
        with open(identity_path, "w", encoding="utf-8") as handle:
            handle.write(identities)
        if str(os.geteuid()) not in identities:
            raise SystemExit("TERM fixture process ownership was not observable")
        os.killpg(process.pid, signal.SIGTERM)
        returncode = process.wait(timeout=10)
        if returncode == 0:
            raise SystemExit("TERM fixture unexpectedly succeeded")
        deadline = time.monotonic() + 10
        root = open(roots, encoding="utf-8").read().strip()
        pids = (process.pid, build_pid, child_pid)
        while time.monotonic() < deadline:
            live = []
            for pid in pids:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                live.append(pid)
            if not os.path.lexists(root) and not live:
                break
            time.sleep(0.02)
        else:
            raise SystemExit(f"TERM cleanup incomplete: root={os.path.lexists(root)} pids={live!r}")
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
PY
root="$(single_recorded_root "$record")"
register_root "$root"
assert_root_absent "$root"
printf 'installer-scratch-cleanup-tests: term-cleanup=PASS duration=%ss\n' "$((SECONDS - started))"

started=$SECONDS
SYMLINK_TARGET="$ROOT/symlink-target"
mkdir -m 700 "$SYMLINK_TARGET"
printf 'sibling-safe\n' >"$SYMLINK_TARGET/marker"
record="$ROOT/symlink.roots"
expect_failure "$ROOT/symlink.log" \
  env SHADOW_SYNC_FIXTURE_MODE=replace-symlink SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  SHADOW_SYNC_FIXTURE_SYMLINK_TARGET="$SYMLINK_TARGET" "$INSTALL" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
[ -L "$root" ] && [ "$(readlink "$root")" = "$SYMLINK_TARGET" ]
grep -q '^sibling-safe$' "$SYMLINK_TARGET/marker"
grep -q 'refusing cleanup of an unexpected captured-release root' "$ROOT/symlink.log"
remove_case_root "$root"

record="$ROOT/replaced.roots"
identity="$ROOT/replaced.identity"
expect_failure "$ROOT/replaced.log" \
  env SHADOW_SYNC_FIXTURE_MODE=replace-directory SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  SHADOW_SYNC_FIXTURE_IDENTITY_RECORD="$identity" "$INSTALL" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
[ -f "$root/replacement-marker" ]
read -r old_inode new_inode <"$identity"
[ "$old_inode" != "$new_inode" ]
grep -q 'refusing cleanup after captured-release root identity changed' "$ROOT/replaced.log"
remove_case_root "$root"

OWNER="$ROOT/wrong-owner"
make_variant "$BASE" "$OWNER" wrong-owner
record="$ROOT/wrong-owner.roots"
expect_failure "$ROOT/wrong-owner.log" \
  env SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  "$OWNER/global/tools/shadow-sync/install.sh" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
[ -d "$root" ] && [ ! -L "$root" ]
grep -q 'refusing cleanup after captured-release root identity changed' "$ROOT/wrong-owner.log"
remove_case_root "$root"

PARENT_DEVICE="$ROOT/wrong-parent-device"
make_variant "$BASE" "$PARENT_DEVICE" wrong-parent-device
record="$ROOT/wrong-parent-device.roots"
expect_failure "$ROOT/wrong-parent-device.log" \
  env SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  "$PARENT_DEVICE/global/tools/shadow-sync/install.sh" --build-release-check
root="$(single_recorded_root "$record")"
register_root "$root"
[ -d "$root" ] && [ ! -L "$root" ]
grep -q 'refusing cleanup after captured-release root identity changed' \
  "$ROOT/wrong-parent-device.log"
remove_case_root "$root"
printf 'installer-scratch-cleanup-tests: substitution-guards=PASS duration=%ss\n' "$((SECONDS - started))"

started=$SECONDS
REPEAT="$ROOT/repeat"
make_variant "$BASE" "$REPEAT" repeat
record="$ROOT/repeat.roots"
trap_record="$ROOT/repeat.trap"
action="$ROOT/repeat.actions"
env SHADOW_SYNC_FIXTURE_MODE=success SHADOW_SYNC_FIXTURE_ROOT_RECORD="$record" \
  SHADOW_SYNC_FIXTURE_ACTION_RECORD="$action" SHADOW_SYNC_FIXTURE_TRAP_RECORD="$trap_record" \
  "$REPEAT/global/tools/shadow-sync/install.sh" >"$ROOT/repeat.log" 2>&1
[ "$(wc -l <"$record" | tr -d ' ')" -eq 2 ]
[ "$(sort -u "$record" | wc -l | tr -d ' ')" -eq 2 ]
while IFS= read -r root; do
  register_root "$root"
  assert_root_absent "$root"
done <"$record"
[ "$(grep -c '^unrelated-exit$' "$trap_record")" -eq 1 ]
[ "$(wc -l <"$action" | tr -d ' ')" -eq 2 ]
printf 'installer-scratch-cleanup-tests: repeat-and-trap=PASS duration=%ss\n' "$((SECONDS - started))"

assert_only_sibling_root "$UNRELATED"
[ -f "$UNRELATED/marker" ]
snapshot_live "$ROOT/live-after.json"
cmp "$ROOT/live-before.json" "$ROOT/live-after.json"
remove_case_root "$UNRELATED"
python3 - <<'PY'
import glob
matches = glob.glob("/private/tmp/shadow-sync-m6-live.*")
if matches:
    raise SystemExit(f"installer scratch residue remains: {matches!r}")
PY
printf 'installer-scratch-cleanup-tests: live-state=UNCHANGED sibling=INTACT residue=ZERO\n'
