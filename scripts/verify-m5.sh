#!/bin/bash
set -euo pipefail
umask 077

PRACTICAL_ONLY=0
STATUS_ITEM_GUIDANCE_ONLY=0
FOREGROUND_ONLY=0
CONFIRMATION_CLOSE_ONLY=0
OPERATION_CONTENTION_ONLY=0
if [[ "${1:-}" == "--practical-only" ]]; then
  PRACTICAL_ONLY=1
  shift
elif [[ "${1:-}" == "--status-item-guidance-only" ]]; then
  STATUS_ITEM_GUIDANCE_ONLY=1
  shift
elif [[ "${1:-}" == "--foreground-only" ]]; then
  FOREGROUND_ONLY=1
  shift
elif [[ "${1:-}" == "--confirmation-close-only" ]]; then
  CONFIRMATION_CLOSE_ONLY=1
  shift
elif [[ "${1:-}" == "--operation-contention-only" ]]; then
  OPERATION_CONTENTION_ONLY=1
  shift
fi
if [[ "$#" -ne 0 ]]; then
  printf 'usage: %s [--practical-only|--status-item-guidance-only|--foreground-only|--confirmation-close-only|--operation-contention-only]\n' "$0" >&2
  exit 64
fi

CAPABILITY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$CAPABILITY"
. "$CAPABILITY/scripts/owned-cleanup.sh"
ROOT="$(mktemp -d /private/tmp/shadow-sync-m5.XXXXXX)"

cleanup() {
  local status="$1"
  trap - EXIT INT TERM
  if ! shadow_sync_reap_owned_root_helpers "$ROOT" verify-m5; then
    printf 'verify-m5: fixture process leaked before cleanup\n' >&2
    status=1
  fi
  shadow_sync_remove_owned_root "$ROOT" verify-m5 || status=1
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$CONFIRMATION_CLOSE_ONLY" -eq 0 ]]; then
  "$CAPABILITY/install.sh" --check
fi
"$CAPABILITY/scripts/build-app.sh" \
  --scratch-path "$ROOT/swift" \
  --output-dir "$ROOT/output" \
  --testing >/dev/null

EXECUTABLE="$ROOT/output/ShadowSync.app/Contents/MacOS/ShadowSync"
test -x "$EXECUTABLE"
bash -n "$CAPABILITY/scripts/v3-preflight-acceptance.sh"
V3_BUILD=(
  --package-path "$CAPABILITY"
  --scratch-path "$ROOT/v3-swift"
  --disable-index-store
  -Xswiftc -DSHADOW_SYNC_TESTING
)
swift build "${V3_BUILD[@]}" --product ShadowSyncSelfTest
V3_BIN="$(swift build "${V3_BUILD[@]}" --show-bin-path)"
for selector in \
  --dm3-t04-only --dm3-t11-only --dm3-t12-only --dm3-t14-only; do
  "$V3_BIN/ShadowSyncSelfTest" \
    --app-executable "$EXECUTABLE" "$selector"
done

run_channel() {
  local mode="$1" request="$2" output="$3" timeout="$4"
  SHADOW_SYNC_EXECUTABLE="$EXECUTABLE" \
  SHADOW_SYNC_MODE="$mode" \
  SHADOW_SYNC_REQUEST="$request" \
  SHADOW_SYNC_OUTPUT="$output" \
  SHADOW_SYNC_TIMEOUT="$timeout" \
  python3 <<'PY'
import json
import os
import signal
import socket
import subprocess
import sys

parent, child = socket.socketpair()
process = subprocess.Popen(
    [
        "/usr/bin/sandbox-exec",
        "-p",
        "(version 1) (allow default) (deny network*)",
        os.environ["SHADOW_SYNC_EXECUTABLE"],
        os.environ["SHADOW_SYNC_MODE"],
        str(child.fileno()),
    ],
    pass_fds=(child.fileno(),),
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=False,
    start_new_session=True,
)
child.close()
timeout = int(os.environ["SHADOW_SYNC_TIMEOUT"])
try:
    parent.sendall(os.environ["SHADOW_SYNC_REQUEST"].encode() + b"\n")
    parent.settimeout(timeout)
    line = parent.makefile("rb", buffering=0).readline()
    status = process.wait(timeout=timeout)
except (TimeoutError, socket.timeout, subprocess.TimeoutExpired):
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)
    raise SystemExit("M5 AppKit channel timed out and was drained")
finally:
    parent.close()
stderr = process.stderr.read().decode(errors="replace")
if status != 0:
    raise SystemExit(f"M5 AppKit channel failed ({status}): {stderr}")
if stderr:
    sys.stderr.write(stderr)
if not line:
    raise SystemExit(f"M5 AppKit channel returned no response: {stderr}")
result = json.loads(line)
with open(os.environ["SHADOW_SYNC_OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(result, handle, sort_keys=True)
    handle.write("\n")
PY
}

if [[ "$OPERATION_CONTENTION_ONLY" -eq 1 ]]; then
  OPERATION_CONTENTION_REQUEST="$(
    python3 - "$ROOT" <<'PY'
import json
import sys
print(json.dumps({
    "schema": "shadow-sync-m5-operation-contention/v1",
    "testRoot": sys.argv[1],
}, separators=(",", ":")))
PY
  )"
  OPERATION_CONTENTION_OUTPUT="$ROOT/operation-contention.json"
  run_channel \
    "--shadow-sync-m5-operation-contention-channel" \
    "$OPERATION_CONTENTION_REQUEST" \
    "$OPERATION_CONTENTION_OUTPUT" \
    20
  python3 - "$OPERATION_CONTENTION_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["schema"] == "shadow-sync-m5-operation-contention-result/v1", result
assert result["lifecyclePassed"] is True, result
print("verify-m5: operation contention lifecycle passed")
PY
  printf 'verify-m5: operation-contention PASS\n'
  exit 0
fi

if [[ "$CONFIRMATION_CLOSE_ONLY" -eq 1 ]]; then
  CONFIRMATION_CLOSE_REQUEST="$(
    python3 - "$ROOT" <<'PY'
import json
import sys
print(json.dumps({
    "schema": "shadow-sync-m5-confirmation-close/v1",
    "testRoot": sys.argv[1],
}, separators=(",", ":")))
PY
  )"
  CONFIRMATION_CLOSE_OUTPUT="$ROOT/confirmation-close.json"
  run_channel \
    "--shadow-sync-m5-confirmation-close-channel" \
    "$CONFIRMATION_CLOSE_REQUEST" \
    "$CONFIRMATION_CLOSE_OUTPUT" \
    20
  python3 - "$CONFIRMATION_CLOSE_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["schema"] == "shadow-sync-m5-confirmation-close-result/v1", result
for field in [
    "closeClearsSession",
    "retryStartsRun",
    "hiddenCardRemainsOpen",
    "reactivationReusesCard",
    "hiddenOnboardingRemainsOpen",
    "onboardingReactivationReuses",
    "dismissedCanonicalRootCommitStaysClosed",
    "savedCanonicalRootRefreshFailureRecovers",
    "dismissedSavedCanonicalRootReconciles",
    "concurrentCanonicalRootCommitIsRejected",
    "discoveryActivationShowsProgress",
    "discoveryActivationPresentsOnce",
    "onboardingFailurePreservesOnboarding",
    "dismissedFailureReportsAndReconciles",
    "quitRejectsAuthorityAdmission",
    "quitCompletionGenerationIsolated",
    "quitCompletionExactlyOnce",
]:
    assert result[field] is True, (field, result)
print("verify-m5: confirmation-close authority lifecycle passed")
PY
  printf 'verify-m5: confirmation-close PASS\n'
  exit 0
fi

if [[ "$STATUS_ITEM_GUIDANCE_ONLY" -eq 1 ]]; then
  STATUS_ITEM_REQUEST="$(
    python3 - "$ROOT" <<'PY'
import json
import sys
print(json.dumps({
    "schema": "shadow-sync-m5-status-item-guidance/v1",
    "testRoot": sys.argv[1],
}, separators=(",", ":")))
PY
  )"
  STATUS_ITEM_OUTPUT="$ROOT/status-item-guidance.json"
  run_channel \
    "--shadow-sync-m5-status-item-guidance-channel" \
    "$STATUS_ITEM_REQUEST" \
    "$STATUS_ITEM_OUTPUT" \
    20
  python3 - "$STATUS_ITEM_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["schema"] == "shadow-sync-m5-status-item-guidance-result/v1", result
for field in [
    "publicVisibilityClassification",
    "delayedHiddenPresentation",
    "pendingUntilWindow",
    "singlePresentation",
    "guidanceThenForegroundFailure",
    "foregroundFailureThenGuidance",
    "dismissClearsOwnedForegroundFailure",
    "dismissPreservesUnrelatedInlineStatus",
    "dismissPreservesOtherForegroundOwner",
    "dismissPreservesNewForegroundOwner",
    "dismissRestoresShortcutUnavailableHelp",
    "visibleBeforePresentationCancelsGuidance",
    "repeatedOrderingNoDuplicate",
    "visibleNoImpact",
    "exactCopy",
]:
    assert result[field] is True, (field, result)
print("verify-m5: hidden status-item guidance passed")
PY
  if rg -n \
    'AXUIElement|AXIsProcessTrusted|CGWindowList|StatusKit|ControlCenter|trackedApplications|group\.com\.apple\.controlcenter|SkyLight|SLS[A-Z]' \
    "$CAPABILITY/Sources/ShadowSyncApp/AppDelegate.swift" \
    "$CAPABILITY/Sources/ShadowSyncApp/StatusItemGuidance.swift"; then
    printf 'verify-m5: hidden status-item guidance uses a prohibited runtime API\n' >&2
    exit 1
  fi
  if rg -n '\.autosaveName[[:space:]]*=' \
    "$CAPABILITY/Sources/ShadowSyncApp/AppDelegate.swift" \
    "$CAPABILITY/Sources/ShadowSyncApp/StatusItemGuidance.swift"; then
    printf 'verify-m5: hidden status-item guidance changed persistence identity\n' >&2
    exit 1
  fi
  printf 'verify-m5: status-item guidance PASS\n'
  exit 0
fi

if [[ "$PRACTICAL_ONLY" -eq 1 ]]; then
  PRACTICAL_REQUEST="$(
    python3 - "$ROOT" <<'PY'
import json
import sys
print(json.dumps({
    "schema": "shadow-sync-m5-practical-ui/v1",
    "testRoot": sys.argv[1],
}, separators=(",", ":")))
PY
  )"
  PRACTICAL_OUTPUT="$ROOT/practical-ui.json"
  run_channel \
    "--shadow-sync-m5-practical-ui-channel" \
    "$PRACTICAL_REQUEST" \
    "$PRACTICAL_OUTPUT" \
    20
  python3 - "$PRACTICAL_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["schema"] == "shadow-sync-m5-practical-ui-result/v1", result
for field in [
    "disabledRowsAndReasons",
    "eligibleBlockedCounts",
    "selectionExcludesBlocked",
    "keyboardExcludesBlocked",
    "reviewExcludesBlocked",
    "runRowsShowCompactLocation",
    "menuLabelsAndShortcut",
    "chooserInitialAndRestoredGeometry",
    "chooserBothAxisResize",
    "chooserZoomAndFullScreen",
    "menuShortcutFlowEquivalence",
    "originRowsConsolidated",
    "canonicalChoiceRequiredWhenSelected",
    "canonicalChoiceIndependentFromDefaults",
    "validSaveReopenAndContinue",
    "statusSectionsCollapsed",
]:
    assert result[field] is True, (field, result)
print("verify-m5: practical disabled-row selection UI passed")
PY
  printf 'verify-m5: practical PASS\n'
  exit 0
fi

FOREGROUND_REQUEST="$(
  python3 - "$ROOT" <<'PY'
import json
import sys
print(json.dumps({
    "schema": "shadow-sync-m5-foreground/v1",
    "testRoot": sys.argv[1],
}, separators=(",", ":")))
PY
)"
FOREGROUND_OUTPUT="$ROOT/foreground.json"
run_channel \
  "--shadow-sync-m5-foreground-channel" \
  "$FOREGROUND_REQUEST" \
  "$FOREGROUND_OUTPUT" \
  20
python3 - "$FOREGROUND_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["schema"] == "shadow-sync-m5-foreground-result/v1", result
for field in [
    "legacyAsyncOrderingRejected",
    "callbackSynchronousOnMain",
    "activationReachedBeforeReturn",
    "realityGateCompletedBeforeReturn",
    "firstShortcutActivated",
    "repeatedShortcutActivated",
    "sameWindowReused",
    "currentSpaceBehavior",
    "inFlightDuplicateWaitedForReality",
    "onboardingRetiresCompletedRun",
    "onboardingRetiresHistoricalViewer",
    "onboardingOwnsForeground",
    "surfaceRoutingCoherent",
    "collisionBlockerRegistered",
    "collisionSurfaced",
    "collisionReleaseThenInvocationSucceeded",
    "shortcutHandlerIsolationPassed",
    "productionShortcutDefaultsPreserved",
    "registrationConflictPassed",
    "timingMatrixPassed",
    "foregroundObserversCleaned",
    "preflightSurfaceOrdering",
    "loadingSurfaceIsCurrent",
    "repeatedLoadingRoutesReuseSurface",
    "staleInventoryCompletionIgnored",
    "inventoryFailureIsRecoverable",
    "reusedContentReplacedByLoading",
    "staleInventoryControlsUnavailable",
    "reusedFailureIsVisible",
    "currentCompletionInstalledOnce",
    "hiddenSuccessRecovered",
    "hiddenFailureRetry",
    "pendingHiddenReshow",
    "hiddenQuitNoResurface",
    "reusedRetryConfigured",
    "staleHiddenCompletionIgnored",
    "dualWindowInventoryPriority",
    "failureSurfacePriority",
    "blockingSurfacePriority",
    "retiredSelectionRunPriority",
    "hiddenSurfaceInvocationPriority",
    "visibleBeginFailureResolved",
    "hiddenBeginFailureResolved",
    "beginFailureRetryStartsOnce",
    "beginFailureQueuedQuit",
    "beginFailureStaleGenerationIgnored",
    "beginFailureLoggingContract",
    "visibleOnboardingPrecedesCards",
    "hiddenOnboardingRemainsGated",
    "pendingOnboardingReopensFirst",
    "onboardingCancelRemainsGated",
    "onboardingConfirmationBuildsCardsOnce",
    "pendingOnboardingQuitAndStaleSafe",
    "onboardedHiddenCompletionPreserved",
    "ownedInventoryQuitLifecycle",
    "lifecycleLoggingContract",
]:
    assert result[field] is True, (field, result)
print("verify-m5: existing-window shortcut foreground and reuse passed")
PY
if rg -n -F 'activate(ignoringOtherApps:' \
  "$CAPABILITY/Sources/ShadowSyncApp" \
  --glob '*.swift' \
  --glob '!M5Harness.swift'; then
  printf 'verify-m5: production still uses deprecated AppKit activation\n' >&2
  exit 1
fi
if rg -n -F 'NSApp.activate()' \
  "$CAPABILITY/Sources/ShadowSyncApp" \
  --glob '*.swift' \
  --glob '!M5Harness.swift'; then
  printf 'verify-m5: production still relies on ineffective accessory activation\n' >&2
  exit 1
fi
if [[ "$FOREGROUND_ONLY" -eq 1 ]]; then
  printf 'verify-m5: foreground PASS\n'
  exit 0
fi

UI_REQUEST="$(
  python3 - "$ROOT" <<'PY'
import json
import sys
print(json.dumps({
    "schema": "shadow-sync-m5-ui/v1",
    "testRoot": sys.argv[1],
}, separators=(",", ":")))
PY
)"
UI_OUTPUT="$ROOT/ui.json"
run_channel "--shadow-sync-m5-ui-channel" "$UI_REQUEST" "$UI_OUTPUT" 30
python3 - "$UI_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["schema"] == "shadow-sync-m5-ui-result/v1", result
expected = {
    "exactCopySnapshots",
    "resultTaxonomyAndTransitions",
    "reducerReportTransactions",
    "controllerReportTransactions",
    "stoppingOverlayRaces",
    "stoppingControllerRaces",
    "sealedPresentationRaces",
    "operationContentionLifecycle",
    "historicalViewerLifecycleIsolation",
    "body3CorrectiveSessionOwnership",
    "originIdentityPresentation",
    "orderedNativeRows",
    "constantTimeRowMutation",
    "selectionStates",
    "routeStateMatrix",
    "partialAndFinalReopen",
    "secureLogFeedback",
    "focusAndAlertSafety",
    "adaptiveSemanticLayout",
    "mixedAndCancelledReports",
}
for field in expected:
    assert result[field] is True, (field, result)
if "accessibilitySemantics" not in result:
    raise AssertionError(
        ("accessibilitySemantics", "missing required diagnostic field", result)
    )
accessibility_semantics = result["accessibilitySemantics"]
assert type(accessibility_semantics) is bool, (
    "accessibilitySemantics",
    "expected boolean diagnostic",
    result,
)
print(
    "verify-m5: accessibilitySemantics="
    f"{str(accessibility_semantics).lower()}"
    " (diagnostic only; nonblocking canonical AppKit metadata)"
)
assert result["coreTests"] == [
    "m5-secure-log-open-success",
    "m5-secure-log-open-refusals",
    "m5-secure-log-open-identity-change",
    "m5-secure-log-open-default-app-failure",
], result
print("verify-m5: focused AppKit, presentation, routing, and secure-log tests passed")
PY

for trial in 1 2 3; do
  request="$(
    python3 - "$ROOT" "$trial" <<'PY'
import json
import sys
print(json.dumps({
    "schema": "shadow-sync-m5-latency/v1",
    "testRoot": sys.argv[1],
    "trial": int(sys.argv[2]),
    "rowCount": 100,
    "durationSeconds": 60,
    "eventIntervalMilliseconds": 25,
}, separators=(",", ":")))
PY
  )"
  output="$ROOT/latency-$trial.json"
  run_channel "--shadow-sync-m5-latency-channel" "$request" "$output" 75
  python3 - "$output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["schema"] == "shadow-sync-m5-latency-result/v1", result
assert result["rowCount"] == 100, result
assert result["durationSeconds"] == 60, result
assert result["eventIntervalMilliseconds"] == 25, result
assert result["expectedEventCount"] == 2400, result
assert result["renderedEventCount"] == 2400, result
assert result["firstSequence"] == 2, result
assert result["lastSequence"] == 2401, result
assert result["monotonic"] is True, result
assert result["noDroppedEvents"] is True, result
assert result["p95Milliseconds"] <= 250, result
assert len(result["samplesMilliseconds"]) == 2400, result
for index, sample in enumerate(result["samplesMilliseconds"], 1):
    print(
        f"verify-m5: raw trial={result['trial']} sample={index} "
        f"milliseconds={sample:.6f}"
    )
print(
    f"verify-m5: latency trial={result['trial']} "
    f"p95-ms={result['p95Milliseconds']:.6f} "
    f"max-ms={result['maximumMilliseconds']:.6f} "
    "events=2400 rows=100 interval-ms=25 duration-s=60 "
    "monotonic=true dropped=0"
)
PY
done

printf 'verify-m5: PASS\n'
