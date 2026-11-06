#!/bin/bash
set -euo pipefail
umask 077
umask 077

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
ROOT="$(mktemp -d /private/tmp/shadow-sync-verify.XXXXXX)"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if ! shadow_sync_reap_owned_root_helpers "$ROOT" verify-m1; then
    status=1
  fi
  shadow_sync_remove_owned_root "$ROOT" verify-m1 || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$CAPABILITY/install.sh" --check
bash -n "$CAPABILITY/scripts/v3-preflight-acceptance.sh"
swift test \
  --package-path "$CAPABILITY" \
  --scratch-path "$ROOT/swift-package-gate" \
  --disable-index-store
printf 'verify-m1: SwiftPM compile/package gate passed (zero registered runtime tests)\n'

"$CAPABILITY/scripts/m1-core-tests.sh"
"$CAPABILITY/scripts/m1-native-e2e.sh"
printf 'verify-m1: compile gate, v3 architecture matrix, executable runtime gate, and native E2E passed\n'
