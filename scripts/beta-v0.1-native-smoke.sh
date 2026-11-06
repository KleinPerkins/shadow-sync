#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"

if [ "$#" -ne 2 ] || [ "$1" != "--output-dir" ]; then
  printf 'usage: %s --output-dir ABSOLUTE_FRESH_PATH\n' "$0" >&2
  exit 2
fi
OUTPUT="$2"
case "$OUTPUT" in /*) ;; *) printf 'output directory must be absolute\n' >&2; exit 2 ;; esac
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || {
  printf 'output directory must be fresh: %s\n' "$OUTPUT" >&2
  exit 1
}
OUTPUT_PARENT="$(dirname "$OUTPUT")"
[ -d "$OUTPUT_PARENT" ] && [ ! -L "$OUTPUT_PARENT" ] || {
  printf 'output parent must be a physical directory\n' >&2
  exit 1
}
mkdir -m 700 "$OUTPUT"

ROOT="$(mktemp -d /private/tmp/shadowsync-beta-native.XXXXXX)"
chmod 700 "$ROOT"
HOST_PID=""

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [ -n "$HOST_PID" ]; then
    shadow_sync_reap_known_owned_root_pid "$ROOT" beta-recut-visual "$HOST_PID" \
      || result=1
  fi
  shadow_sync_reap_owned_root_helpers "$ROOT" beta-recut-visual || result=1
  shadow_sync_remove_owned_root "$ROOT" beta-recut-visual || result=1
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
BIN_DIR="$(swift build "${BUILD[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/ShadowSync"
[ -x "$EXECUTABLE" ]

"$EXECUTABLE" \
  --shadow-sync-beta-recut-visual-host "$ROOT" \
  >"$ROOT/ready.txt" 2>"$ROOT/host.stderr" &
HOST_PID=$!

for _ in $(jot 200 1); do
  if grep -q '^READY ' "$ROOT/ready.txt" 2>/dev/null; then
    break
  fi
  kill -0 "$HOST_PID" 2>/dev/null || {
    cat "$ROOT/host.stderr" >&2
    printf 'visual host exited before readiness\n' >&2
    exit 1
  }
  sleep 0.1
done
READY="$(grep '^READY ' "$ROOT/ready.txt" | tail -1)"
[ -n "$READY" ] || {
  cat "$ROOT/host.stderr" >&2
  printf 'visual host readiness timed out\n' >&2
  exit 1
}
WINDOW="$(printf '%s\n' "$READY" | awk '{for(i=1;i<=NF;i++) if($i ~ /^window=/){sub(/^window=/,"",$i); print $i}}')"
READY_WIDTH="$(printf '%s\n' "$READY" | awk '{for(i=1;i<=NF;i++) if($i ~ /^width=/){sub(/^width=/,"",$i); print $i}}')"
READY_HEIGHT="$(printf '%s\n' "$READY" | awk '{for(i=1;i<=NF;i++) if($i ~ /^height=/){sub(/^height=/,"",$i); print $i}}')"
case "$WINDOW" in *[!0-9]*|"") printf 'invalid visual host window id\n' >&2; exit 1 ;; esac

UI_ENABLED="$(osascript -e 'tell application "System Events" to get UI elements enabled')"
[ "$UI_ENABLED" = "true" ] || {
  printf 'native UI automation is not authorized for this terminal\n' >&2
  exit 1
}

WINDOW_COUNT=0
for _ in $(jot 100 1); do
  WINDOW_COUNT="$(osascript - "$HOST_PID" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  tell application "System Events"
    tell (first application process whose unix id is targetPID)
      return count of windows
    end tell
  end tell
end run
APPLESCRIPT
)"
  [ "$WINDOW_COUNT" -gt 0 ] && break
  sleep 0.1
done
[ "$WINDOW_COUNT" -gt 0 ] || {
  printf 'native automation did not discover the chooser window\n' >&2
  exit 1
}

set_native_size() {
  local width="$1" height="$2"
  for _ in $(jot 100 1); do
    if osascript - "$HOST_PID" "$width" "$height" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  set targetWidth to item 2 of argv as integer
  set targetHeight to item 3 of argv as integer
  tell application "System Events"
    set targetProcess to first application process whose unix id is targetPID
    set frontmost of targetProcess to true
    tell window 1 of targetProcess
      set size to {targetWidth, targetHeight}
    end tell
  end tell
end run
APPLESCRIPT
    then
      return 0
    fi
    sleep 0.1
  done
  printf 'native automation could not resize the chooser to %sx%s\n' \
    "$width" "$height" >&2
  return 1
}

screencapture -x -l "$WINDOW" "$OUTPUT/01-initial.png"

set_native_size 940 590
screencapture -x -l "$WINDOW" "$OUTPUT/02-horizontal.png"

set_native_size 940 720
screencapture -x -l "$WINDOW" "$OUTPUT/03-both-axes.png"

/usr/bin/touch "$ROOT/enter-full-screen"
FULL_WINDOW=""
for _ in $(jot 100 1); do
  FULL_LINE="$(grep '^FULLSCREEN ' "$ROOT/ready.txt" | tail -1 || true)"
  if [ -n "$FULL_LINE" ]; then
    FULL_WINDOW="$(printf '%s\n' "$FULL_LINE" | awk '{for(i=1;i<=NF;i++) if($i ~ /^window=/){sub(/^window=/,"",$i); print $i}}')"
    break
  fi
  sleep 0.1
done
[ -n "$FULL_WINDOW" ] || {
  printf 'window did not enter native full screen\n' >&2
  exit 1
}
screencapture -x -l "$FULL_WINDOW" "$OUTPUT/04-full-screen.png"

/usr/bin/touch "$ROOT/exit-full-screen"
RESTORED_WINDOW=""
for _ in $(jot 100 1); do
  RESTORED_LINE="$(grep '^RESTORED ' "$ROOT/ready.txt" | tail -1 || true)"
  if [ -n "$RESTORED_LINE" ]; then
    RESTORED_WINDOW="$(printf '%s\n' "$RESTORED_LINE" | awk '{for(i=1;i<=NF;i++) if($i ~ /^window=/){sub(/^window=/,"",$i); print $i}}')"
    break
  fi
  sleep 0.1
done
[ -n "$RESTORED_WINDOW" ] || {
  printf 'window did not leave native full screen\n' >&2
  exit 1
}
screencapture -x -l "$RESTORED_WINDOW" "$OUTPUT/05-restored.png"

python3 - "$OUTPUT" "$READY_WIDTH" "$READY_HEIGHT" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
rows = []
for path in sorted(output.glob("*.png")):
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit(f"not a PNG: {path}")
    rows.append({
        "file": path.name,
        "bytes": len(data),
        "sha256": sha256(data).hexdigest(),
    })
if len(rows) != 5 or any(row["bytes"] < 10_000 for row in rows):
    raise SystemExit(f"incomplete visual evidence: {rows}")
(output / "evidence.json").write_text(
    json.dumps({
        "schema": "shadowsync-beta-native-smoke/v1",
        "initialFrame": {
            "width": float(sys.argv[2]),
            "height": float(sys.argv[3]),
        },
        "nativeAutomation": "System Events AX",
        "screenshots": rows,
    }, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

printf 'beta-v0.1-native-smoke: PASS evidence=%s\n' "$OUTPUT"
