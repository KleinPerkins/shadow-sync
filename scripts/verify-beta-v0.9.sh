#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
ROOT="$(mktemp -d /private/tmp/shadowsync-beta-v09.XXXXXX)"

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  shadow_sync_reap_owned_root_helpers "$ROOT" beta-v09 || result=1
  if ! shadow_sync_remove_owned_root "$ROOT" beta-v09; then
    # Finder can race native capture teardown by writing one metadata file
    # after the first owned-root removal. Remove only that owned residue and
    # retry the same guarded root cleanup.
    /bin/rm -f "$ROOT/swift/out/.DS_Store"
    shadow_sync_remove_owned_root "$ROOT" beta-v09 || result=1
  fi
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
swift build "${BUILD[@]}" --product ShadowSync
swift build "${BUILD[@]}" --product ShadowSyncSelfTest
BIN="$(swift build "${BUILD[@]}" --show-bin-path)"
mkdir -m 700 "$ROOT/appkit"
(
  cd "$CAPABILITY"
  "$BIN/ShadowSyncSelfTest" \
    --app-executable "$BIN/ShadowSync" \
    --beta-v09-focused-only
  "$BIN/ShadowSync" \
    --shadow-sync-body3-layout-regression \
    "$ROOT/appkit"
  SHADOW_SYNC_PREBUILT_EXECUTABLE="$BIN/ShadowSync" \
    "$CAPABILITY/scripts/beta-v0.9-native-smoke.sh" \
      --output-dir "$ROOT/native"
)
printf 'verify-beta-v0.9: PASS\n'
