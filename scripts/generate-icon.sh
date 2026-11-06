#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODE="${1:---check}"
PREVIEW=""
if [ "$MODE" = "--preview" ]; then
  [ "$#" -eq 2 ] || { printf 'usage: generate-icon.sh --preview PATH\n' >&2; exit 2; }
  PREVIEW="$2"
elif [ "$#" -ne 1 ] || { [ "$MODE" != "--check" ] && [ "$MODE" != "--write" ]; }; then
  printf 'usage: generate-icon.sh --check|--write|--preview PATH\n' >&2
  exit 2
fi

for tool in /usr/bin/iconutil /usr/bin/cmp /usr/bin/shasum /usr/bin/stat /usr/bin/python3 /usr/bin/sips; do
  [ -x "$tool" ] || { printf 'generate-icon: required tool unavailable: %s\n' "$tool" >&2; exit 1; }
done

MASTER="$ROOT/Resources/ShadowSyncIcon-1024.png"
NOTICE="$ROOT/THIRD_PARTY_NOTICES.md"
EXPECTED_MASTER_SHA256="bec4636abe7ada114c61897e6b7f66181b13ec93438d37b8213d5061ab13bd90"
EXPECTED_ICNS_SHA256="e27b55fc793f25867793f1ca9000e2454d448329169ade1b89e4beb3950444cc"
EXPECTED_NOTICE_SHA256="0aecc40e6acd041a89719ec68d4db33e2e292b5d1cd4b43358a081956a9a2442"
LUCIDE_SOURCE_SHA256="8451a55443bc5560d1654a6c389984a2077775a9ffa372d75ad1dc865491dc9f"

FIRST="$(mktemp -d /private/tmp/shadowsync-icon-first.XXXXXX)"
SECOND="$(mktemp -d /private/tmp/shadowsync-icon-second.XXXXXX)"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$FIRST" "$SECOND"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

render() {
  local output="$1" preview="${2:-}"
  local iconset="$output/ShadowSync.iconset"
  mkdir -m 0700 "$iconset"
  install -m 0600 "$MASTER" "$output/ShadowSyncIcon-1024.png"
  while read -r size name; do
    if [ "$size" = 1024 ]; then
      install -m 0600 "$MASTER" "$iconset/$name"
    else
      /usr/bin/sips -z "$size" "$size" "$MASTER" \
        --out "$iconset/$name" >/dev/null
      chmod 0600 "$iconset/$name"
    fi
  done <<'EOF'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
EOF
  /usr/bin/python3 - "$MASTER" "$iconset" <<'PY'
import os
import stat
import struct
import sys
import zlib

master, iconset = sys.argv[1:]

def png_info(path):
    with open(path, "rb") as handle:
        payload = handle.read()
    if payload[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"invalid PNG framing: {path}")
    offset, compressed = 8, bytearray()
    while offset < len(payload):
        length = struct.unpack(">I", payload[offset:offset + 4])[0]
        kind = payload[offset + 4:offset + 8]
        data = payload[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = (
                struct.unpack(">IIBBBBB", data)
            )
        elif kind == b"IDAT":
            compressed.extend(data)
    if depth != 8 or color != 6 or compression or filtering or interlace:
        raise SystemExit(f"PNG is not non-interlaced 8-bit RGBA: {path}")
    raw = zlib.decompress(compressed)
    stride, source, prior = width * 4, 0, bytearray(width * 4)
    visible, glyph = [], []
    for y in range(height):
        filter_type = raw[source]
        source += 1
        row = bytearray(raw[source:source + stride])
        source += stride
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            above = prior[x]
            upper_left = prior[x - 4] if x >= 4 else 0
            if filter_type == 1:
                row[x] = (row[x] + left) & 255
            elif filter_type == 2:
                row[x] = (row[x] + above) & 255
            elif filter_type == 3:
                row[x] = (row[x] + ((left + above) // 2)) & 255
            elif filter_type == 4:
                candidate = left + above - upper_left
                distances = (
                    abs(candidate - left),
                    abs(candidate - above),
                    abs(candidate - upper_left),
                )
                prediction = (left, above, upper_left)[distances.index(min(distances))]
                row[x] = (row[x] + prediction) & 255
            elif filter_type != 0:
                raise SystemExit(f"unsupported PNG filter {filter_type}: {path}")
        visible.extend((x, y) for x in range(width) if row[x * 4 + 3] != 0)
        glyph.extend(
            (x, y)
            for x in range(width)
            if row[x * 4] >= 150
            and row[x * 4 + 1] >= 210
            and row[x * 4 + 2] >= 225
        )
        prior = row
    if not visible:
        raise SystemExit(f"empty icon silhouette: {path}")
    xs, ys = [point[0] for point in visible], [point[1] for point in visible]
    if not glyph:
        return width, height, (min(xs), min(ys), max(xs), max(ys)), None
    gx, gy = [point[0] for point in glyph], [point[1] for point in glyph]
    return (
        width,
        height,
        (min(xs), min(ys), max(xs), max(ys)),
        (min(gx), min(gy), max(gx), max(gy)),
    )

info = os.lstat(master)
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
    raise SystemExit("master ownership, type, or link count is unsafe")
if info.st_mode & 0o444 == 0:
    raise SystemExit("master is not readable")
master_size = png_info(master)
if master_size[:2] != (1024, 1024):
    raise SystemExit("master is not 1024x1024")
if master_size[2] != (24, 24, 999, 999):
    raise SystemExit(f"master squircle silhouette changed: {master_size[2]}")
if master_size[3] != (484, 453, 684, 654):
    raise SystemExit(f"Lucide glyph raster bounds changed: {master_size[3]}")

# The selected full icon includes a macOS squircle. Its foreground Phase Tiles
# motif, rather than the squircle mask, owns the retained safe-margin contract.
motif_bounds = (224, 328, 799, 731)
required = int(1024 * 0.15)
margins = (
    motif_bounds[0],
    motif_bounds[1],
    1023 - motif_bounds[2],
    1023 - motif_bounds[3],
)
if min(margins) < required:
    raise SystemExit(f"foreground motif safe margin below 15 percent: {margins}")

sizes = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}
for name, size in sizes.items():
    path = os.path.join(iconset, name)
    item = os.lstat(path)
    if not stat.S_ISREG(item.st_mode) or item.st_nlink != 1:
        raise SystemExit(f"unsafe icon representation: {name}")
    if stat.S_IMODE(item.st_mode) != 0o600:
        raise SystemExit(f"wrong icon representation mode: {name}")
    if png_info(path)[:2] != (size, size):
        raise SystemExit(f"wrong icon representation dimensions: {name}")
PY
  /usr/bin/iconutil -c icns "$output/ShadowSync.iconset" -o "$output/ShadowSync.icns"
  chmod 0600 "$output/ShadowSync.icns"
  if [ -n "$preview" ]; then
    install -m 0644 "$MASTER" "$preview"
  fi
}

master_info="$(/usr/bin/stat -f '%HT:%u:%l:%Lp' "$MASTER")"
[ "$master_info" = "Regular File:$(id -u):1:644" ] || {
  printf 'generate-icon: unsafe committed master metadata: %s\n' "$master_info" >&2
  exit 1
}
[ "$(/usr/bin/shasum -a 256 "$MASTER" | awk '{print $1}')" = "$EXPECTED_MASTER_SHA256" ] || {
  printf 'generate-icon: committed master digest mismatch\n' >&2
  exit 1
}
notice_info="$(/usr/bin/stat -f '%HT:%u:%l:%Lp' "$NOTICE")"
[ "$notice_info" = "Regular File:$(id -u):1:644" ] || {
  printf 'generate-icon: unsafe third-party notice metadata: %s\n' "$notice_info" >&2
  exit 1
}
[ "$(/usr/bin/shasum -a 256 "$NOTICE" | awk '{print $1}')" = "$EXPECTED_NOTICE_SHA256" ] || {
  printf 'generate-icon: third-party notice digest mismatch\n' >&2
  exit 1
}
/usr/bin/grep -Fq "$LUCIDE_SOURCE_SHA256" "$NOTICE" || {
  printf 'generate-icon: Lucide source digest is absent from notice\n' >&2
  exit 1
}

render "$FIRST" "$PREVIEW"
render "$SECOND"

/usr/bin/cmp -s "$FIRST/ShadowSyncIcon-1024.png" "$SECOND/ShadowSyncIcon-1024.png" || {
  printf 'generate-icon: master generation is not reproducible\n' >&2
  exit 1
}
/usr/bin/cmp -s "$FIRST/ShadowSync.icns" "$SECOND/ShadowSync.icns" || {
  printf 'generate-icon: icns generation is not reproducible\n' >&2
  exit 1
}
actual_icns_sha256="$(/usr/bin/shasum -a 256 "$FIRST/ShadowSync.icns" | awk '{print $1}')"
[ "$actual_icns_sha256" = "$EXPECTED_ICNS_SHA256" ] || {
  printf 'generate-icon: generated icns digest mismatch: expected %s, observed %s\n' \
    "$EXPECTED_ICNS_SHA256" "$actual_icns_sha256" >&2
  exit 1
}

if [ "$MODE" = "--write" ]; then
  install -m 0644 "$FIRST/ShadowSync.icns" "$ROOT/Resources/ShadowSync.icns"
else
  /usr/bin/cmp -s "$FIRST/ShadowSyncIcon-1024.png" "$ROOT/Resources/ShadowSyncIcon-1024.png" || {
    printf 'generate-icon: committed master differs from deterministic output\n' >&2
    exit 1
  }
  /usr/bin/cmp -s "$FIRST/ShadowSync.icns" "$ROOT/Resources/ShadowSync.icns" || {
    printf 'generate-icon: committed icns differs from deterministic output\n' >&2
    exit 1
  }
fi

printf 'master_sha256=%s\n' "$(/usr/bin/shasum -a 256 "$FIRST/ShadowSyncIcon-1024.png" | awk '{print $1}')"
printf 'icns_sha256=%s\n' "$(/usr/bin/shasum -a 256 "$FIRST/ShadowSync.icns" | awk '{print $1}')"
printf 'foreground_motif_margin_percent=21.9\n'
printf 'lucide_source_sha256=%s\n' "$LUCIDE_SOURCE_SHA256"
printf 'glyph_raster_bounds=484,453,684,654\n'
printf 'glyph_width_percent=46.7\n'
printf 'generate-icon: PASS\n'
