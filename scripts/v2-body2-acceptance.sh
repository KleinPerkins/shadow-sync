#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$CAPABILITY/scripts/owned-cleanup.sh"
SCRATCH="$(mktemp -d /private/tmp/shadow-sync-v2-body2.XXXXXX)"
export SWIFTPM_MODULECACHE_OVERRIDE="$SCRATCH/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-module-cache"

cleanup() {
  local status="$1"
  trap - EXIT INT TERM
  shadow_sync_reap_owned_root_helpers "$SCRATCH" v2-body2-acceptance || status=1
  shadow_sync_remove_owned_root "$SCRATCH" v2-body2-acceptance || status=1
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BUILD_ARGS=(
  --package-path "$CAPABILITY"
  --scratch-path "$SCRATCH/testing"
  --disable-index-store
  -Xswiftc -DSHADOW_SYNC_TESTING
)
swift build "${BUILD_ARGS[@]}" --product ShadowSync
swift build "${BUILD_ARGS[@]}" --product ShadowSyncSelfTest
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$BIN_DIR/ShadowSync"
SELF_TEST="$BIN_DIR/ShadowSyncSelfTest"

"$SELF_TEST" --app-executable "$APP" --body2-only
printf 'v2-body2-acceptance: DM2-T05/T06/T07/T14 focused checks passed\n'

"$CAPABILITY/scripts/build-app.sh" \
  --scratch-path "$SCRATCH/production-swift" \
  --output-dir "$SCRATCH/production-output" \
  >"$SCRATCH/production-app-path.txt"
PRODUCTION_APP="$(cat "$SCRATCH/production-app-path.txt")"
PRODUCTION_BINARY="$PRODUCTION_APP/Contents/MacOS/ShadowSync"

[ "$(plutil -extract ShadowSyncBuildMode raw \
  "$PRODUCTION_APP/Contents/Info.plist")" = production ]
codesign --verify --strict --verbose=2 "$PRODUCTION_APP"
/usr/bin/nm -gj "$PRODUCTION_BINARY" >"$SCRATCH/production-symbols.txt"
if /usr/bin/grep -E \
  'SHADOW_SYNC_TESTING|DM2Body2|TransportMapping|testing[A-Z]' \
  "$SCRATCH/production-symbols.txt"; then
  printf 'v2-body2-acceptance: production binary exposes a test seam\n' >&2
  exit 1
fi
if /usr/bin/nm -u "$PRODUCTION_BINARY" \
  | /usr/bin/grep -E \
    'URLSession|NSURLSession|libcurl|curl_easy|curl_multi'; then
  printf 'v2-body2-acceptance: unapproved network client found\n' >&2
  exit 1
fi
if /usr/bin/strings "$PRODUCTION_BINARY" \
  | /usr/bin/grep -E \
    -- '--body2-|synthetic-(fetch|update)|testingExecutablePath'; then
  printf 'v2-body2-acceptance: production test marker found\n' >&2
  exit 1
fi

PRODUCTION_SOURCES=(
  "$CAPABILITY/Sources/ShadowSyncCore/GitSafety.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/ProcessRunner.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryModelV2.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryLifecycle.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/RepositoryMaintenance.swift"
  "$CAPABILITY/Sources/ShadowSyncCore/ReadOnlyGitHubCLIAdapter.swift"
  "$CAPABILITY/Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
)
GH_ADAPTER="$CAPABILITY/Sources/ShadowSyncCore/ReadOnlyGitHubCLIAdapter.swift"
EXPECTED_FIELDS='number,url,state,isDraft,headRefName,headRefOid,isCrossRepository,updatedAt,closedAt,mergedAt'

[ "$(grep -c '"/opt/homebrew/bin/gh"' "$GH_ADAPTER")" -eq 1 ]
[ "$(grep -c '"/usr/local/bin/gh"' "$GH_ADAPTER")" -eq 1 ]
grep -Fq '"pr", "list"' "$GH_ADAPTER"
grep -Fq '"--limit", "100"' "$GH_ADAPTER"
grep -Fq "\"$EXPECTED_FIELDS\"" "$GH_ADAPTER"
grep -Fq '"GH_PROMPT_DISABLED": "1"' "$GH_ADAPTER"
grep -Fq '"GH_PAGER": "cat"' "$GH_ADAPTER"
if grep -E \
  'GH_TOKEN|GITHUB_TOKEN|"(api|search|run|workflow|issue|repo|release)"' \
  "$GH_ADAPTER"; then
  printf 'v2-body2-acceptance: GitHub adapter grammar widened\n' >&2
  exit 1
fi
if grep -E \
  'URLSession|NWConnection|Network\.framework|CFNetwork|/usr/bin/(curl|wget)|/opt/homebrew/bin/(curl|wget)' \
  "${PRODUCTION_SOURCES[@]}"; then
  printf 'v2-body2-acceptance: unapproved network path found\n' >&2
  exit 1
fi
if grep -E \
  '"worktree",[[:space:]]*"remove"|"branch",[[:space:]]*"-(d|D)"|"update-ref",[[:space:]]*"-d"|remote",[[:space:]]*"set-head"' \
  "${PRODUCTION_SOURCES[@]}"; then
  printf 'v2-body2-acceptance: cleanup or origin/HEAD mutation found\n' >&2
  exit 1
fi
if grep -E 'Process[[:space:]]*\(|/bin/(sh|bash|zsh)' \
  "${PRODUCTION_SOURCES[@]}"; then
  printf 'v2-body2-acceptance: arbitrary process path found\n' >&2
  exit 1
fi
[ "$(grep -l 'posix_spawn(' "${PRODUCTION_SOURCES[@]}" | wc -l | tr -d ' ')" -eq 3 ]
grep -Fq 'posix_spawn(' "$CAPABILITY/Sources/ShadowSyncCore/GitSafety.swift"
grep -Fq 'posix_spawn(' "$CAPABILITY/Sources/ShadowSyncCore/ProcessRunner.swift"
grep -Fq 'posix_spawn(' "$GH_ADAPTER"
if grep -E '\.package[[:space:]]*\(' "$CAPABILITY/Package.swift"; then
  printf 'v2-body2-acceptance: third-party dependency found\n' >&2
  exit 1
fi

bash -n "$CAPABILITY/scripts/v2-body2-acceptance.sh"
bash -n "$CAPABILITY/scripts/verify-m6.sh"
printf 'v2-body2-acceptance: production build and boundary audits passed\n'
