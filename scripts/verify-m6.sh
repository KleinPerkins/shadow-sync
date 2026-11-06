#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
VERIFIER_PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
RUN_FOUNDATION=1
if [ "${1:-}" = "--reuse-current-foundation-evidence" ] && [ "$#" -eq 1 ]; then
  RUN_FOUNDATION=0
elif [ "$#" -ne 0 ]; then
  printf 'usage: verify-m6.sh [--reuse-current-foundation-evidence]\n' >&2
  exit 2
fi

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
REPO="$(cd "$CAPABILITY/../../.." && pwd)"
ROOT="$(mktemp -d /private/tmp/shadow-sync-m6.XXXXXX)"
chmod 700 "$ROOT"
BEFORE="$(mktemp /private/tmp/shadow-sync-m6-live-before.XXXXXX)"
AFTER="$(mktemp /private/tmp/shadow-sync-m6-live-after.XXXXXX)"
LIFECYCLE_PID=""

terminate_lifecycle() {
  local command deadline
  [ -n "$LIFECYCLE_PID" ] || return 0
  kill -0 "$LIFECYCLE_PID" 2>/dev/null || {
    wait "$LIFECYCLE_PID" 2>/dev/null || true
    LIFECYCLE_PID=""
    return 0
  }
  command="$(ps -p "$LIFECYCLE_PID" -o command= 2>/dev/null || true)"
  case "$command" in *"$CAPABILITY/scripts/m6-lifecycle-e2e.sh"*"$ROOT/lifecycle"*) ;;
    *) printf 'verify-m6: lifecycle helper identity changed\n' >&2; return 1 ;;
  esac
  kill -TERM "$LIFECYCLE_PID" 2>/dev/null || true
  deadline=$((SECONDS + 35))
  while kill -0 "$LIFECYCLE_PID" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.05
  done
  if kill -0 "$LIFECYCLE_PID" 2>/dev/null; then
    command="$(ps -p "$LIFECYCLE_PID" -o command= 2>/dev/null || true)"
    case "$command" in *"$CAPABILITY/scripts/m6-lifecycle-e2e.sh"*"$ROOT/lifecycle"*)
      kill -KILL "$LIFECYCLE_PID" 2>/dev/null || true
      ;;
      *) printf 'verify-m6: lifecycle helper identity changed before KILL\n' >&2; return 1 ;;
    esac
    deadline=$((SECONDS + 2))
    while kill -0 "$LIFECYCLE_PID" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.05
    done
  fi
  kill -0 "$LIFECYCLE_PID" 2>/dev/null && return 1
  wait "$LIFECYCLE_PID" 2>/dev/null || true
  LIFECYCLE_PID=""
}

remove_root_bounded() {
  local pid command deadline
  /bin/rm -rf -- "$ROOT" &
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
  case "$command" in *"/bin/rm -rf"*"$ROOT"*) ;; *) return 1 ;; esac
  deadline=$((SECONDS + 15))
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in *"/bin/rm -rf"*"$ROOT"*) kill -KILL "$pid" 2>/dev/null || true ;; *)
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
  status=$?
  trap - EXIT INT TERM
  safe_to_remove=1
  terminate_lifecycle || { status=1; safe_to_remove=0; }
  if ! shadow_sync_reap_owned_root_helpers "$ROOT" verify-m6 1; then
    status=1
    safe_to_remove=0
  fi
  if [ "$safe_to_remove" -eq 1 ] && [ -e "$ROOT" ]; then
    remove_root_bounded || status=1
  fi
  rm -f -- "$BEFORE" "$AFTER"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

snapshot_live "$BEFORE"
"$CAPABILITY/install.sh" --check
if [ "$RUN_FOUNDATION" -eq 1 ]; then
  env PATH="$VERIFIER_PATH" "$CAPABILITY/scripts/verify-m1.sh"
  env PATH="$VERIFIER_PATH" "$CAPABILITY/scripts/verify-m5.sh"
fi
LIFECYCLE_ROOT="$ROOT/lifecycle"
mkdir -m 700 "$LIFECYCLE_ROOT"
"$CAPABILITY/scripts/m6-lifecycle-e2e.sh" --test-root "$LIFECYCLE_ROOT" &
LIFECYCLE_PID=$!
lifecycle_deadline=$((SECONDS + 1200))
while kill -0 "$LIFECYCLE_PID" 2>/dev/null && [ "$SECONDS" -lt "$lifecycle_deadline" ]; do
  sleep 0.1
done
if kill -0 "$LIFECYCLE_PID" 2>/dev/null; then
  printf 'verify-m6: lifecycle E2E exceeded 1200 seconds\n' >&2
  terminate_lifecycle
  exit 1
fi
wait "$LIFECYCLE_PID"
LIFECYCLE_PID=""
snapshot_live "$AFTER"
cmp "$BEFORE" "$AFTER" || {
  printf 'verify-m6: live product state changed\n' >&2
  diff -u "$BEFORE" "$AFTER" >&2 || true
  exit 1
}

bash -n "$CAPABILITY/install.sh"
bash -n "$CAPABILITY/scripts/build-app.sh"
bash -n "$CAPABILITY/scripts/m6-lifecycle-e2e.sh"
bash -n "$CAPABILITY/scripts/verify-m6.sh"
bash -n "$CAPABILITY/scripts/v3-preflight-acceptance.sh"

if grep -R -n -i -E \
  'URLSession|NWConnection|Network\.framework|CFNetwork|api\.github|/usr/bin/(curl|wget)|/opt/homebrew/bin/(curl|wget)|telemetry|auto.?update|sparkle' \
  "$CAPABILITY/Sources" "$CAPABILITY/Package.swift"; then
  printf 'verify-m6: product network/updater client found\n' >&2
  exit 1
fi
GH_ADAPTER="$CAPABILITY/Sources/ShadowSyncCore/ReadOnlyGitHubCLIAdapter.swift"
GH_FIELDS='number,url,state,isDraft,headRefName,headRefOid,isCrossRepository,updatedAt,closedAt,mergedAt'
[ -f "$GH_ADAPTER" ] \
  && [ "$(grep -c '"/opt/homebrew/bin/gh"' "$GH_ADAPTER")" -eq 1 ] \
  && [ "$(grep -c '"/usr/local/bin/gh"' "$GH_ADAPTER")" -eq 1 ] \
  && grep -q '"pr", "list"' "$GH_ADAPTER" \
  && grep -q '"--limit", "100"' "$GH_ADAPTER" \
  && grep -Fq "\"$GH_FIELDS\"" "$GH_ADAPTER" \
  && grep -q '"GH_PROMPT_DISABLED": "1"' "$GH_ADAPTER" \
  && grep -q '"GH_PAGER": "cat"' "$GH_ADAPTER" \
  && ! grep -E \
    'GH_TOKEN|GITHUB_TOKEN|"(api|search|run|workflow|issue|repo|release)"' \
    "$GH_ADAPTER" >/dev/null \
  || {
    printf 'verify-m6: closed GitHub CLI adapter audit failed\n' >&2
    exit 1
  }
if grep -n -E '\.package[[:space:]]*\(' "$CAPABILITY/Package.swift"; then
  printf 'verify-m6: third-party package dependency found\n' >&2
  exit 1
fi
downstream_repo="card-platform""-product"
downstream_alias="c""pp"
downstream_vendor="affirm/""vendor"
if grep -R -n -i -E --exclude=verify-m6.sh \
  "$downstream_repo|\\b$downstream_alias\\b|$downstream_vendor" "$CAPABILITY"; then
  printf 'verify-m6: prohibited downstream link found\n' >&2
  exit 1
fi

bash "$REPO/.github/scripts/eco-lock.sh" check
bash "$REPO/.github/scripts/verify-skills.sh"
bash "$REPO/bootstrap.sh" --reconcile --dry-run >/dev/null
GH="/opt/homebrew/bin/gh"
[ -x "$GH" ] || {
  printf 'verify-m6: fixed GitHub CLI is unavailable for orchestrator status\n' >&2
  exit 1
}
ORCHESTRATOR_REGISTRY="$ROOT/orchestrator-registry.yml"
"$GH" api \
  'repos/KleinPerkins/ecosystem-orchestrator/contents/config/registry.yml?ref=main' \
  --jq .content | base64 --decode >"$ORCHESTRATOR_REGISTRY"
awk '
  $0 == "  - id: shadow-sync" { found=1; next }
  found && $0 == "    state: excluded" { excluded=1; exit }
  found && $0 ~ /^  - id:/ { exit }
  END { exit !(found && excluded) }
' "$ORCHESTRATOR_REGISTRY" || {
  printf 'verify-m6: live orchestrator main does not exclude shadow-sync\n' >&2
  exit 1
}
python3 - "$REPO/docs/plans/shadow-sync-global-capability-v1.md" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if "AT-01–33" not in text or "AT-32–33" not in text:
    raise SystemExit("verify-m6: acceptance ledger range authority is missing")
PY
if find "$CAPABILITY" -type l -print | grep -q .; then
  printf 'verify-m6: global capability contains a symbolic link\n' >&2
  exit 1
fi

printf 'verify-m6: lifecycle=PASS\n'
printf 'verify-m6: live-product-state=UNCHANGED\n'
printf 'verify-m6: network=identity-verified-read-only-gh-only dependencies=none updater=absent\n'
printf 'verify-m6: downstream-links=absent metadata-lock=parity\n'
printf 'verify-m6: selection-preferences=lifecycle-allowlisted-and-doctor-validated\n'
printf 'verify-m6: orchestrator-main=excluded\n'
if [ "$RUN_FOUNDATION" -eq 1 ]; then
  printf 'verify-m6: m1=PASS m5=PASS at-ledger=AT-01..33 repo-verifier=PASS\n'
else
  printf 'verify-m6: m1/m5=current-head-evidence-reused at-ledger=AT-01..33 repo-verifier=PASS\n'
fi
