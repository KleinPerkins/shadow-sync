#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
ROOT="$(mktemp -d /private/tmp/shadowsync-beta-v03-build6.XXXXXX)"

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  shadow_sync_reap_owned_root_helpers "$ROOT" beta-v03-build6 || result=1
  shadow_sync_remove_owned_root "$ROOT" beta-v03-build6 || result=1
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
BIN="$(swift build "${BUILD[@]}" --show-bin-path)/ShadowSync"
"$BIN" --shadow-sync-beta-v03-build6-cancel-reopen
