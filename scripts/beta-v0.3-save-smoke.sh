#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
OUTPUT="${1:-}"
case "$OUTPUT" in /*) ;; *) printf 'usage: %s ABSOLUTE_FRESH_OUTPUT_DIR\n' "$0" >&2; exit 2 ;; esac
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || {
  printf 'output directory must be fresh\n' >&2
  exit 1
}
mkdir -m 700 "$OUTPUT"
ROOT="$(mktemp -d /private/tmp/shadowsync-beta-v03-save.XXXXXX)"
HOST_PID=""

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [ -n "$HOST_PID" ]; then
    shadow_sync_reap_known_owned_root_pid "$ROOT" beta-v03-save "$HOST_PID" || result=1
  fi
  shadow_sync_reap_owned_root_helpers "$ROOT" beta-v03-save || result=1
  shadow_sync_remove_owned_root "$ROOT" beta-v03-save || result=1
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BUILD=(
  --package-path "$CAPABILITY"
  --scratch-path "$ROOT/swift"
  --disable-index-store
  -Xswiftc -DSHADOW_SYNC_TESTING
)
swift build "${BUILD[@]}" --product ShadowSync >/dev/null
BIN="$(swift build "${BUILD[@]}" --show-bin-path)/ShadowSync"
"$BIN" --shadow-sync-beta-recut-visual-host "$ROOT" \
  >"$ROOT/ready.txt" 2>"$ROOT/host.stderr" &
HOST_PID=$!
for _ in $(jot 200 1); do
  grep -q '^READY ' "$ROOT/ready.txt" 2>/dev/null && break
  kill -0 "$HOST_PID" 2>/dev/null || {
    cat "$ROOT/host.stderr" >&2
    exit 1
  }
  sleep 0.1
done
READY="$(grep '^READY ' "$ROOT/ready.txt" | tail -1)"
WINDOW="$(printf '%s\n' "$READY" | awk '{for(i=1;i<=NF;i++) if($i ~ /^window=/){sub(/^window=/,"",$i); print $i}}')"
case "$WINDOW" in *[!0-9]*|"") printf 'chooser window unavailable\n' >&2; exit 1 ;; esac
screencapture -x -l "$WINDOW" "$OUTPUT/01-before-save.png"
touch "$ROOT/save-defaults"
for _ in $(jot 100 1); do
  grep -q '^SAVED ' "$ROOT/ready.txt" 2>/dev/null && break
  sleep 0.1
done
SAVED="$(grep '^SAVED ' "$ROOT/ready.txt" | tail -1)"
[ -n "$SAVED" ] || {
  printf 'save outcome timed out\n' >&2
  exit 1
}
BEFORE="$(printf '%s\n' "$SAVED" | awk '{sub(/^before=/,"",$2); print $2}')"
AFTER="$(printf '%s\n' "$SAVED" | awk '{sub(/^after=/,"",$3); print $3}')"
[ "$BEFORE" = "$AFTER" ] || {
  printf 'save moved chooser: %s\n' "$SAVED" >&2
  exit 1
}
printf '%s\n' "$SAVED" | grep -q 'status=Defaults saved.'
screencapture -x -l "$WINDOW" "$OUTPUT/02-after-save.png"
printf '%s\n' "$SAVED" >"$OUTPUT/save-frame.txt"
printf 'beta-v0.3-save-smoke: PASS evidence=%s\n' "$OUTPUT"
