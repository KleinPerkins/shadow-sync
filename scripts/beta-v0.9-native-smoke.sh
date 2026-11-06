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
mkdir -m 700 "$OUTPUT"

ROOT="$(mktemp -d /private/tmp/shadowsync-beta-v09-native.XXXXXX)"
chmod 700 "$ROOT"
HOST_PID=""

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [ -n "$HOST_PID" ]; then
    shadow_sync_reap_known_owned_root_pid "$ROOT" beta-v09-visual "$HOST_PID" \
      || result=1
  fi
  shadow_sync_reap_owned_root_helpers "$ROOT" beta-v09-visual || result=1
  shadow_sync_remove_owned_root "$ROOT" beta-v09-visual || result=1
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${SHADOW_SYNC_PREBUILT_EXECUTABLE:-}" ]; then
  EXECUTABLE="$SHADOW_SYNC_PREBUILT_EXECUTABLE"
else
  BUILD=(
    --package-path "$CAPABILITY"
    --scratch-path "$ROOT/swift"
    --disable-index-store
    -Xswiftc -DSHADOW_SYNC_TESTING
  )
  swift build "${BUILD[@]}" --product ShadowSync >/dev/null
  BIN_DIR="$(swift build "${BUILD[@]}" --show-bin-path)"
  EXECUTABLE="$BIN_DIR/ShadowSync"
fi
[ -x "$EXECUTABLE" ]

UI_ENABLED="$(osascript -e 'tell application "System Events" to get UI elements enabled')"
[ "$UI_ENABLED" = "true" ] || {
  printf 'native UI automation is not authorized for this terminal\n' >&2
  exit 1
}

set_native_size() {
  local width="$1" height="$2"
  osascript - "$HOST_PID" "$width" "$height" >/dev/null <<'APPLESCRIPT'
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
}

capture_appearance() {
  local appearance="$1" prefix="$2"
  local run_root="$ROOT/$appearance"
  mkdir -m 700 "$run_root"
  "$EXECUTABLE" \
    --shadow-sync-beta-v09-rlcc-visual-host \
    "$run_root" "$appearance" \
    >"$run_root/ready.txt" 2>"$run_root/host.stderr" &
  HOST_PID=$!
  for _ in $(jot 200 1); do
    if /usr/bin/grep -q '^READY ' "$run_root/ready.txt" 2>/dev/null; then
      break
    fi
    kill -0 "$HOST_PID" 2>/dev/null || {
      cat "$run_root/host.stderr" >&2
      printf 'v0.9 visual host exited before readiness\n' >&2
      exit 1
    }
    sleep 0.1
  done
  local ready window
  ready="$(/usr/bin/grep '^READY ' "$run_root/ready.txt" | /usr/bin/tail -1)"
  window="$(printf '%s\n' "$ready" | awk '{for(i=1;i<=NF;i++) if($i ~ /^window=/){sub(/^window=/,"",$i); print $i}}')"
  case "$window" in *[!0-9]*|"") printf 'invalid visual host window id\n' >&2; exit 1 ;; esac
  set_native_size 720 620
  screencapture -x -l "$window" "$OUTPUT/${prefix}-minimum.png"
  set_native_size 900 720
  screencapture -x -l "$window" "$OUTPUT/${prefix}-standard.png"
  set_native_size 1200 800
  screencapture -x -l "$window" "$OUTPUT/${prefix}-wide.png"
  /usr/bin/touch "$run_root/stop"
  wait "$HOST_PID"
  HOST_PID=""
}

capture_appearance aqua aqua
capture_appearance dark dark

python3 - "$OUTPUT" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
expected = {
    "aqua-minimum.png", "aqua-standard.png", "aqua-wide.png",
    "dark-minimum.png", "dark-standard.png", "dark-wide.png",
}
actual = {path.name for path in root.glob("*.png")}
if actual != expected:
    raise SystemExit("native capture set is incomplete")
rows = []
for path in sorted(root.glob("*.png")):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path.name} is not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    if width < 700 or height < 500:
        raise SystemExit(f"{path.name} is unexpectedly small")
    rows.append({
        "file": path.name,
        "sha256": sha256(data).hexdigest(),
        "width": width,
        "height": height,
    })
(root / "evidence.json").write_text(
    json.dumps(rows, sort_keys=True, indent=2) + "\n",
    encoding="utf-8",
)
PY
printf 'beta-v0.9-native-smoke: PASS\n'
