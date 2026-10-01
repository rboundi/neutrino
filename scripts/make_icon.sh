#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift scripts/make_icon.swift "$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
sips -Z 256 "$TMP/icon_1024.png" --out docs/icon-256.png >/dev/null
echo "Resources/AppIcon.icns updated"
