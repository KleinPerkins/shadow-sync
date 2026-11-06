#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH SDKROOT SWIFT_EXEC CC CXX CFLAGS CPPFLAGS LDFLAGS
unset DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRATCH=""
OUTPUT=""
MODE="production"
SOURCE_REVISION="0000000000000000000000000000000000000000"
SOURCE_INPUT_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
RELEASE_CONTRACT_SHA256=""

usage() {
  cat <<'EOF'
usage: build-app.sh --scratch-path ABSOLUTE_PATH --output-dir ABSOLUTE_PATH [--testing]
                    [--source-revision SHA1 --source-input-sha256 SHA256
                     --release-contract-sha256 SHA256]

Builds and ad-hoc signs one ShadowSync.app. Both build paths are caller-owned; SwiftPM never
writes .build or .swiftpm state into the source directory. The release-contract
digest is computed from Resources/release-contract.json; a supplied digest is an
assertion and must match. This development bundle is not a signed distribution.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scratch-path)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SCRATCH="$2"
      shift 2
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --testing)
      MODE="testing"
      shift
      ;;
    --source-revision)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SOURCE_REVISION="$2"
      shift 2
      ;;
    --source-input-sha256)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SOURCE_INPUT_SHA256="$2"
      shift 2
      ;;
    --release-contract-sha256)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      RELEASE_CONTRACT_SHA256="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'build-app: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -f "$ROOT/Resources/release-contract.json" ] && [ ! -L "$ROOT/Resources/release-contract.json" ] || {
  printf 'build-app: standalone release contract is missing or aliased\n' >&2; exit 2
}
COMPUTED_RELEASE_CONTRACT_SHA256="$(/usr/bin/shasum -a 256 "$ROOT/Resources/release-contract.json" | awk '{print $1}')"
[ -z "$RELEASE_CONTRACT_SHA256" ] || [ "$RELEASE_CONTRACT_SHA256" = "$COMPUTED_RELEASE_CONTRACT_SHA256" ] || {
  printf 'build-app: release-contract digest does not match standalone source\n' >&2; exit 2
}
RELEASE_CONTRACT_SHA256="$COMPUTED_RELEASE_CONTRACT_SHA256"
[ "$(uname -m)" = arm64 ] || { printf 'build-app: only arm64 is supported\n' >&2; exit 2; }

case "$SCRATCH" in /*) ;; *) printf 'build-app: --scratch-path must be absolute\n' >&2; exit 2 ;; esac
case "$OUTPUT" in /*) ;; *) printf 'build-app: --output-dir must be absolute\n' >&2; exit 2 ;; esac
[ "$SCRATCH" != "$OUTPUT" ] || { printf 'build-app: scratch and output paths must differ\n' >&2; exit 2; }
case "$SOURCE_REVISION" in
  *[!0-9a-f]*|"") printf 'build-app: source revision must be lowercase hexadecimal\n' >&2; exit 2 ;;
esac
[ "${#SOURCE_REVISION}" -eq 40 ] || { printf 'build-app: source revision must contain 40 hexadecimal characters\n' >&2; exit 2; }
for digest in "$SOURCE_INPUT_SHA256" "$RELEASE_CONTRACT_SHA256"; do
  case "$digest" in
    *[!0-9a-f]*|"") printf 'build-app: release digests must be lowercase hexadecimal\n' >&2; exit 2 ;;
  esac
  [ "${#digest}" -eq 64 ] || { printf 'build-app: release digests must contain 64 hexadecimal characters\n' >&2; exit 2; }
done

create_private_directory() {
  local path="$1" label="$2" parent canonical_parent mode
  case "$path" in
    /private/tmp/*) ;;
    *) printf 'build-app: %s must be below /private/tmp\n' "$label" >&2; exit 2 ;;
  esac
  case "/$path/" in
    */../*|*/./*) printf 'build-app: %s contains dot components\n' "$label" >&2; exit 2 ;;
  esac
  [ ! -e "$path" ] && [ ! -L "$path" ] || {
    printf 'build-app: %s must be a fresh path: %s\n' "$label" "$path" >&2
    exit 1
  }
  parent="$(dirname "$path")"
  [ -d "$parent" ] && [ ! -L "$parent" ] || {
    printf 'build-app: %s parent must be a physical directory\n' "$label" >&2
    exit 1
  }
  canonical_parent="$(cd -P "$parent" && pwd)"
  [ "$path" = "$canonical_parent/$(basename "$path")" ] || {
    printf 'build-app: %s parent path is not physical\n' "$label" >&2
    exit 1
  }
  [ "$(stat -f '%u' "$parent")" = "$(id -u)" ] || {
    printf 'build-app: %s parent is not caller-owned\n' "$label" >&2
    exit 1
  }
  mode="$(stat -f '%Lp' "$parent")"
  [ $((8#$mode & 077)) -eq 0 ] || {
    printf 'build-app: %s parent is not private\n' "$label" >&2
    exit 1
  }
  mkdir -m 700 "$path"
  [ -d "$path" ] && [ ! -L "$path" ] \
    && [ "$(stat -f '%u' "$path")" = "$(id -u)" ] \
    && [ "$(stat -f '%Lp' "$path")" = 700 ] || {
      printf 'build-app: failed to create private %s\n' "$label" >&2
      exit 1
    }
}

create_private_directory "$SCRATCH" "scratch path"
create_private_directory "$OUTPUT" "output directory"
BUILD_ARGS=(
  --package-path "$ROOT"
  --scratch-path "$SCRATCH"
  --configuration release
  --disable-index-store
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/shadow-sync-source"
  -Xswiftc -debug-prefix-map -Xswiftc "$SCRATCH=/shadow-sync-build"
  -Xlinker -rpath -Xlinker /usr/lib/swift
  -Xlinker -rpath -Xlinker @loader_path
  -Xlinker -reproducible
)
if [ "$MODE" = "testing" ]; then
  BUILD_ARGS+=(-Xswiftc -DSHADOW_SYNC_TESTING)
fi

swift build "${BUILD_ARGS[@]}" --product ShadowSync >&2
swift build "${BUILD_ARGS[@]}" --product ShadowSyncLifecycleCoordinator >&2
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
SOURCE_BINARY="$BIN_DIR/ShadowSync"
COORDINATOR_BINARY="$BIN_DIR/ShadowSyncLifecycleCoordinator"
for SOURCE_BINARY in "$SOURCE_BINARY" "$COORDINATOR_BINARY"; do
[ -x "$SOURCE_BINARY" ] || { printf 'build-app: executable missing after build: %s\n' "$SOURCE_BINARY" >&2; exit 1; }
[ "$(lipo -archs "$SOURCE_BINARY")" = "$(uname -m)" ] || {
  printf 'build-app: executable architecture does not match the producing host\n' >&2
  exit 1
}
MIN_OS="$(otool -l "$SOURCE_BINARY" | awk '/LC_BUILD_VERSION/{seen=1; next} seen && /minos/{print $2; exit}')"
[ "$MIN_OS" = "26.0" ] || {
  printf 'build-app: executable minimum OS is %s, expected 26.0\n' "${MIN_OS:-missing}" >&2
  exit 1
}

done
SOURCE_BINARY="$BIN_DIR/ShadowSync"

STAGE="$(mktemp -d "$OUTPUT/.shadow-sync-app.XXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "${STAGE:-}" ] && [ -d "$STAGE" ] && [ ! -L "$STAGE" ]; then
    rm -rf -- "$STAGE"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
APP="$STAGE/ShadowSync.app"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
install -m 0755 "$SOURCE_BINARY" "$CONTENTS/MacOS/ShadowSync"
install -m 0755 "$COORDINATOR_BINARY" "$CONTENTS/Helpers/ShadowSyncLifecycleCoordinator"
for BUNDLE_BINARY in "$CONTENTS/MacOS/ShadowSync" "$CONTENTS/Helpers/ShadowSyncLifecycleCoordinator"; do
/usr/bin/strip -S "$BUNDLE_BINARY"
RPATHS="$(
  /usr/bin/otool -l "$BUNDLE_BINARY" \
    | awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}'
)"
[ "$(printf '%s\n' "$RPATHS" | wc -l | tr -d ' ')" = 2 ] \
  && [ "$(printf '%s\n' "$RPATHS" | grep -Fxc '/usr/lib/swift')" = 1 ] \
  && [ "$(printf '%s\n' "$RPATHS" | grep -Fxc '@loader_path')" = 1 ] || {
    printf 'build-app: linker did not emit the required runpath set\n' >&2
    exit 1
  }
for runpath in /usr/lib/swift @loader_path; do
  /usr/bin/install_name_tool -delete_rpath "$runpath" "$BUNDLE_BINARY"
done
/usr/bin/install_name_tool \
  -add_rpath /usr/lib/swift \
  -add_rpath @loader_path \
  "$BUNDLE_BINARY"
RPATHS="$(
  /usr/bin/otool -l "$BUNDLE_BINARY" \
    | awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}'
)"
[ "$RPATHS" = "$(printf '/usr/lib/swift\n@loader_path')" ] || {
    printf 'build-app: executable runpaths are not canonical\n' >&2
    exit 1
  }
done
install -m 0644 "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
install -m 0644 "$ROOT/Resources/release-contract.json" "$CONTENTS/Resources/release-contract.json"
install -m 0644 "$ROOT/Resources/command-graphs.json" "$CONTENTS/Resources/command-graphs.json"
[ "$(/usr/bin/shasum -a 256 "$CONTENTS/Resources/release-contract.json" | awk '{print $1}')" = "$RELEASE_CONTRACT_SHA256" ] || {
  printf 'build-app: copied release contract changed\n' >&2; exit 1
}
install -m 0644 \
  "$ROOT/Resources/com.kleinperkins.shadow-sync.plist.template" \
  "$CONTENTS/Resources/com.kleinperkins.shadow-sync.plist.template"
install -m 0644 \
  "$ROOT/Resources/ShadowSync.icns" \
  "$CONTENTS/Resources/ShadowSync.icns"
install -m 0644 \
  "$ROOT/THIRD_PARTY_NOTICES.md" \
  "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
[ "$(/usr/bin/shasum -a 256 "$ROOT/Resources/ShadowSync.icns" | awk '{print $1}')" \
  = "$(/usr/bin/shasum -a 256 "$CONTENTS/Resources/ShadowSync.icns" | awk '{print $1}')" ] || {
  printf 'build-app: copied icon digest mismatch\n' >&2
  exit 1
}
[ "$(/usr/bin/shasum -a 256 "$ROOT/THIRD_PARTY_NOTICES.md" | awk '{print $1}')" \
  = "$(/usr/bin/shasum -a 256 "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md" | awk '{print $1}')" ] || {
  printf 'build-app: copied third-party notice digest mismatch\n' >&2
  exit 1
}
ICON_CHECK="$STAGE/ShadowSync.iconset"
/usr/bin/iconutil -c iconset \
  "$CONTENTS/Resources/ShadowSync.icns" \
  -o "$ICON_CHECK"
for icon in \
  icon_16x16.png icon_16x16@2x.png \
  icon_32x32.png icon_32x32@2x.png \
  icon_128x128.png icon_128x128@2x.png \
  icon_256x256.png icon_256x256@2x.png \
  icon_512x512.png icon_512x512@2x.png; do
  [ -s "$ICON_CHECK/$icon" ] || {
    printf 'build-app: icon representation missing: %s\n' "$icon" >&2
    exit 1
  }
done

plutil -replace ShadowSyncBuildMode -string "$MODE" "$CONTENTS/Info.plist"
plutil -replace ShadowSyncSourceRevision -string "$SOURCE_REVISION" "$CONTENTS/Info.plist"
plutil -replace ShadowSyncSourceInputSHA256 -string "$SOURCE_INPUT_SHA256" "$CONTENTS/Info.plist"
plutil -replace ShadowSyncReleaseContractSHA256 -string "$RELEASE_CONTRACT_SHA256" "$CONTENTS/Info.plist"
plutil -replace ShadowSyncArchitecture -string "$(uname -m)" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null
[ "$(plutil -extract CFBundleIdentifier raw "$CONTENTS/Info.plist")" = "com.kleinperkins.shadow-sync" ]
[ "$(plutil -extract CFBundleExecutable raw "$CONTENTS/Info.plist")" = "ShadowSync" ]
[ "$(plutil -extract CFBundleIconFile raw "$CONTENTS/Info.plist")" = "ShadowSync.icns" ]
[ "$(plutil -extract LSMinimumSystemVersion raw "$CONTENTS/Info.plist")" = "26.0" ]
[ "$(plutil -extract LSUIElement raw "$CONTENTS/Info.plist")" = "false" ]
[ "$(plutil -extract NSPrincipalClass raw "$CONTENTS/Info.plist")" = "NSApplication" ]
[ "$(plutil -extract ShadowSyncReleaseSchema raw "$CONTENTS/Info.plist")" = "shadow-sync-release/v2" ]
[ "$(plutil -extract ShadowSyncSourceRevision raw "$CONTENTS/Info.plist")" = "$SOURCE_REVISION" ]
[ "$(plutil -extract ShadowSyncSourceInputSHA256 raw "$CONTENTS/Info.plist")" = "$SOURCE_INPUT_SHA256" ]
[ "$(plutil -extract ShadowSyncReleaseContractSHA256 raw "$CONTENTS/Info.plist")" = "$RELEASE_CONTRACT_SHA256" ]
[ "$(plutil -extract ShadowSyncArchitecture raw "$CONTENTS/Info.plist")" = "$(uname -m)" ]
[ "$(plutil -extract ShadowSyncBuildMode raw "$CONTENTS/Info.plist")" = "$MODE" ]

codesign --force --sign - --timestamp=none \
  --identifier com.kleinperkins.shadow-sync.lifecycle-coordinator \
  "$CONTENTS/Helpers/ShadowSyncLifecycleCoordinator"
codesign --force --sign - --timestamp=none \
  --identifier com.kleinperkins.shadow-sync "$APP"
/usr/bin/xattr -cr "$APP"
find "$APP" -type d -exec chmod 0700 {} +
find "$APP" -type f -exec chmod 0600 {} +
chmod 0700 "$CONTENTS/MacOS/ShadowSync" "$CONTENTS/Helpers/ShadowSyncLifecycleCoordinator"
codesign --verify --strict --verbose=2 "$CONTENTS/Helpers/ShadowSyncLifecycleCoordinator"
codesign --verify --strict --verbose=2 "$APP"

DEST="$OUTPUT/ShadowSync.app"
if [ -L "$DEST" ]; then
  printf 'build-app: refusing symlink output target: %s\n' "$DEST" >&2
  exit 1
fi
[ ! -e "$DEST" ] || {
  printf 'build-app: refusing existing output target: %s\n' "$DEST" >&2
  exit 1
}
mv "$APP" "$DEST"
/usr/bin/xattr -cr "$DEST"
codesign --verify --strict --verbose=2 "$DEST"
/usr/bin/sandbox-exec \
  -p '(version 1) (allow default) (deny network*)' \
  "$DEST/Contents/MacOS/ShadowSync" --check >/dev/null
printf '%s\n' "$DEST"
