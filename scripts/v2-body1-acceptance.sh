#!/bin/bash
set -euo pipefail
umask 077

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
SCRATCH="$(mktemp -d /private/tmp/shadow-sync-v2-body1.XXXXXX)"

cleanup() {
  local status="$1"
  trap - EXIT INT TERM
  shadow_sync_reap_owned_root_helpers "$SCRATCH" v2-body1-acceptance || status=1
  shadow_sync_remove_owned_root "$SCRATCH" v2-body1-acceptance || status=1
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BUILD_ARGS=(
  --package-path "$CAPABILITY"
  --scratch-path "$SCRATCH"
  --disable-index-store
  -Xswiftc -DSHADOW_SYNC_TESTING
)

swift build "${BUILD_ARGS[@]}" --product ShadowSync
swift build "${BUILD_ARGS[@]}" --product ShadowSyncSelfTest
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$BIN_DIR/ShadowSync"
SELF_TEST="$BIN_DIR/ShadowSyncSelfTest"

"$SELF_TEST" --app-executable "$APP" --body1-only
printf 'v2-body1-acceptance: focused runtime checks passed\n'

"$CAPABILITY/install.sh" --check

PRODUCTION_SCRATCH="$SCRATCH/production-swift"
PRODUCTION_OUTPUT="$SCRATCH/production-output"
"$CAPABILITY/scripts/build-app.sh" \
  --scratch-path "$PRODUCTION_SCRATCH" \
  --output-dir "$PRODUCTION_OUTPUT" \
  >"$SCRATCH/production-app-path.txt"
PRODUCTION_APP="$(cat "$SCRATCH/production-app-path.txt")"
PRODUCTION_BINARY="$PRODUCTION_APP/Contents/MacOS/ShadowSync"

[ "$(plutil -extract ShadowSyncBuildMode raw \
  "$PRODUCTION_APP/Contents/Info.plist")" = production ]
codesign --verify --strict --verbose=2 "$PRODUCTION_APP"

/usr/bin/nm -gj "$PRODUCTION_BINARY" >"$SCRATCH/production-symbols.txt"
if /usr/bin/grep -E \
  'SHADOW_SYNC_TESTING|M1Harness|M5Harness|M6Harness|TransportMapping|testing[A-Z]' \
  "$SCRATCH/production-symbols.txt"; then
  printf 'v2-body1-acceptance: production binary exposes a test seam\n' >&2
  exit 1
fi
if /usr/bin/nm -u "$PRODUCTION_BINARY" \
  | /usr/bin/grep -E 'URLSession|NSURLSession|libcurl|curl_easy|curl_multi'; then
  printf 'v2-body1-acceptance: production binary exposes an unapproved network client\n' >&2
  exit 1
fi
if /usr/bin/strings "$PRODUCTION_BINARY" \
  | /usr/bin/grep -E 'awa_(status|guard|lease)|--body1-only|synthetic-(fetch|update)'; then
  printf 'v2-body1-acceptance: production binary exposes agent runtime or test markers\n' >&2
  exit 1
fi
BODY1_PRODUCTION_SOURCES=(
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryModelV2.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryAuthorityStore.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/FastForwardTransactionV2.swift"
  "$CAPABILITY/Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
)
if /usr/bin/grep -E \
  'Process[[:space:]]*\(|posix_spawn|/bin/(sh|bash|zsh)' \
  "${BODY1_PRODUCTION_SOURCES[@]}"; then
  printf 'v2-body1-acceptance: Body 1 added an arbitrary process path\n' >&2
  exit 1
fi
if /usr/bin/grep -E \
  'Authorization:|Bearer[[:space:]]|token@github|password@github' \
  "${BODY1_PRODUCTION_SOURCES[@]}"; then
  printf 'v2-body1-acceptance: Body 1 source contains credential material\n' >&2
  exit 1
fi
if /usr/bin/grep -E \
  'title:[[:space:]]*"(Repair|Cleanup)|checkboxWithTitle:[[:space:]]*"(Repair|Cleanup)' \
  "$CAPABILITY/Sources/ShadowSyncApp/RepositoryCardsWindow.swift"; then
  printf 'v2-body1-acceptance: later-body repository controls leaked into Body 1\n' >&2
  exit 1
fi

printf 'v2-body1-acceptance: production build, symbol, config, and source audits passed\n'
