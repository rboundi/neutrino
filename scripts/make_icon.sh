#!/bin/bash
# Rebuilds the app icon from Resources/AppIcon.icon, the layered Icon Composer document.
# Writes Resources/Assets.car (the layered icon for macOS 26 and later), Resources/AppIcon.icns
# (for earlier systems) and docs/icon-256.png. Needs Xcode 26 or later.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift scripts/make_icon_layers.swift >/dev/null
xcrun actool Resources/AppIcon.icon --compile "$TMP" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 13.0 --output-partial-info-plist "$TMP/partial.plist" >/dev/null
cp "$TMP/Assets.car" "$TMP/AppIcon.icns" Resources/
"$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon.icon \
  --export-image --output-file docs/icon-256.png --platform macOS --rendition Default \
  --width 256 --height 256 --scale 1 >/dev/null
echo "Resources/Assets.car, Resources/AppIcon.icns and docs/icon-256.png updated"
