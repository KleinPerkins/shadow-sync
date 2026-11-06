#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
unset SDKROOT SWIFT_EXEC CC CXX CFLAGS CPPFLAGS LDFLAGS DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1

# Signed coordinator/Sparkle own production installation and updates.
# Refuse before reading source metadata or inspecting any installed paths.
case "${1:-}" in
  ""|--apply|--repair|--uninstall|--source-identity|--build-release-check)
    printf 'Source-built production installation and release attestation are retired.\n' >&2
    exit 64
    ;;
  --doctor)
    if [ "$#" -ne 3 ] || [ "$2" != --test-root ]; then
      printf 'Source-built live inspection is retired; an isolated fixture root is required.\n' >&2
      exit 64
    fi
    ;;
esac

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
NAME="shadow-sync"
log() { printf '[install:%s] %s\n' "$NAME" "$*"; }
fail() { printf '[install:%s] FAIL: %s\n' "$NAME" "$*" >&2; return 1; }

canonical_test_root() {
  /usr/bin/python3 -I "$SRC/scripts/verify-fixture-root.py" "$1"
}

stage_m1() {
  local test_root scratch="$2"
  test_root="$(canonical_test_root "$1")"
  case "$scratch" in /*) ;; *) fail "scratch path must be absolute" ;; esac
  case "$scratch/" in "$test_root"/*) ;; *) fail "scratch path must stay inside the test root" ;; esac
  case "/$scratch/" in */../*|*/./*) fail "scratch path must not contain dot components" ;; esac
  [ ! -e "$scratch" ] && [ ! -L "$scratch" ] || fail "scratch path must be fresh"

  local home output built app_parent app_target plist_parent plist_target executable
  home="$test_root/home"
  output="$test_root/build-output"
  app_parent="$home/Applications"
  app_target="$app_parent/ShadowSync.app"
  plist_parent="$home/Library/LaunchAgents"
  plist_target="$plist_parent/com.kleinperkins.shadow-sync.plist"
  [ ! -e "$output" ] && [ ! -L "$output" ] || fail "build output path must be fresh"
  local descendant parent
  for descendant in "$home" "$app_parent" "$home/Library" "$plist_parent"; do
    [ ! -e "$descendant" ] && [ ! -L "$descendant" ] || {
      fail "refusing pre-existing staging descendant: $descendant"
      return 1
    }
    parent="$(dirname "$descendant")"
    [ -d "$parent" ] && [ ! -L "$parent" ] || {
      fail "staging parent is not physical: $parent"
      return 1
    }
    [ "$(cd -P "$parent" && pwd)/$(basename "$descendant")" = "$descendant" ] || {
      fail "staging parent path is not physical: $parent"
      return 1
    }
    mkdir -m 700 "$descendant"
    [ -d "$descendant" ] && [ ! -L "$descendant" ] \
      && [ "$(stat -f '%u' "$descendant")" = "$(id -u)" ] \
      && [ "$(stat -f '%Lp' "$descendant")" = 700 ] || {
        fail "could not create private staging descendant: $descendant"
        return 1
      }
  done

  built="$("$SRC/scripts/build-app.sh" --scratch-path "$scratch" --output-dir "$output" --testing)"
  [ -d "$built" ] || fail "test bundle was not built"
  [ ! -e "$app_target" ] || fail "test app target already exists"
  mv "$built" "$app_target"

  executable="$app_target/Contents/MacOS/ShadowSync"
  install -m 0600 "$SRC/Resources/com.kleinperkins.shadow-sync.plist.template" "$plist_target"
  plutil -remove ProgramArguments.0 "$plist_target"
  plutil -insert ProgramArguments.0 -string "$executable" "$plist_target"
  plutil -lint "$plist_target" >/dev/null
  log "staged M1 test app without loading launchd: $app_target"
  log "staged M1 test LaunchAgent without bootstrapping it: $plist_target"
}

doctor_test_root() {
  local test_root home app plist executable launchctl_stub rc=0
  test_root="$(canonical_test_root "$1")"
  /usr/bin/python3 -I "$SRC/scripts/verify-fixture-root.py" "$test_root" --doctor >/dev/null
  home="$test_root/home"
  app="$home/Applications/ShadowSync.app"
  plist="$home/Library/LaunchAgents/com.kleinperkins.shadow-sync.plist"
  executable="$app/Contents/MacOS/ShadowSync"
  launchctl_stub="$test_root/launchctl-stub"

  if [ ! -e "$app" ] && [ ! -L "$app" ]; then
    [ -f "$launchctl_stub" ] && [ ! -L "$launchctl_stub" ] \
      && [ -x "$launchctl_stub" ] \
      && [ "$(stat -f '%u' "$launchctl_stub")" = "$(id -u)" ] \
      && [ "$(stat -f '%Lp' "$launchctl_stub")" = 700 ] \
      && [ "$(stat -f '%l' "$launchctl_stub")" = 1 ] \
      || fail "test-root launchctl stub is unsafe"
    "$SRC/scripts/source-doctor.sh" --home "$home" --launchctl "$launchctl_stub"
    return
  fi

  local directory
  for directory in \
    "$home" "$home/Applications" "$home/Library" "$home/Library/LaunchAgents"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] \
      && [ "$(stat -f '%u' "$directory")" = "$(id -u)" ] \
      && [ "$(stat -f '%Lp' "$directory")" = 700 ] || {
        printf '  FAIL  unsafe staging directory: %s\n' "$directory"
        rc=1
      }
  done
  [ -d "$app" ] && [ ! -L "$app" ] || { printf '  FAIL  staged app missing or aliased\n'; rc=1; }
  [ -x "$executable" ] || { printf '  FAIL  staged executable missing\n'; rc=1; }
  [ -f "$plist" ] && [ ! -L "$plist" ] || { printf '  FAIL  staged LaunchAgent missing or aliased\n'; rc=1; }
  if [ "$rc" -eq 0 ]; then
    codesign --verify --strict --verbose=2 "$app" || rc=1
    plutil -lint "$app/Contents/Info.plist" >/dev/null || rc=1
    plutil -lint "$plist" >/dev/null || rc=1
    [ "$(plutil -extract ShadowSyncBuildMode raw "$app/Contents/Info.plist")" = "testing" ] || rc=1
    [ "$(plutil -extract ProgramArguments.0 raw "$plist")" = "$executable" ] || rc=1
    [ "$(plutil -extract ProgramArguments.1 raw "$plist")" = "--managed-host" ] || rc=1
    ! plutil -extract ProgramArguments.2 raw "$plist" >/dev/null 2>&1 || rc=1
    [ "$(plutil -extract RunAtLoad raw "$plist")" = "false" ] || rc=1
    [ "$(plutil -extract KeepAlive raw "$plist")" = "false" ] || rc=1
    [ "$(plutil -extract ProcessType raw "$plist")" = "Interactive" ] || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    log "test-root doctor OK"
  else
    fail "test-root doctor failed"
  fi
}

case "${1:-}" in
  --check)
    [ "$#" -eq 1 ] || { fail '--check accepts no additional arguments'; exit 2; }
    /usr/bin/python3 -I "$SRC/scripts/verify-source-contract.py"
    ;;
  --doctor)
    doctor_test_root "$3"
    ;;
  --m1-stage)
    [ "$#" -eq 5 ] && [ "$2" = --test-root ] && [ "$4" = --scratch-path ] || {
      fail 'usage: install.sh --m1-stage --test-root ABSOLUTE_TEMP_PATH --scratch-path ABSOLUTE_PATH'
      exit 2
    }
    stage_m1 "$3" "$5"
    ;;
  -h|--help)
    [ "$#" -eq 1 ] || { fail 'help accepts no additional arguments'; exit 2; }
    printf '%s\n' 'Source-built production installation is retired.' \
      'Development fixture helpers:' \
      '       install.sh --check' \
      '       install.sh --doctor --test-root ABSOLUTE_TEMP_PATH' \
      '       install.sh --m1-stage --test-root ABSOLUTE_TEMP_PATH --scratch-path ABSOLUTE_PATH'
    ;;
  *) fail "unsupported command '$1'"; exit 2 ;;
esac
