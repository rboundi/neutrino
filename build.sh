#!/bin/bash
# Builds Neutrino.app into ./build.
#   ./build.sh            build the app
#   ./build.sh --install  also copy it to /Applications and link the `neutrino` command
#   ./build.sh --release  also create a signed, notarized .zip and .dmg in ./build
#
# Signing uses the "Developer ID Application" identity from the keychain when there is one,
# otherwise an ad-hoc signature. Notarization (--release only) uses the notarytool keychain
# profile named in $NOTARY_PROFILE (default: mdreader-notary).
# The version comes from $VERSION, else the latest git tag (v1.2.3), else 1.0.0.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$( (git describe --tags --abbrev=0 2>/dev/null || true) | sed 's/^v//')}"
VERSION="${VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Neutrino.app"
MODE="${1:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mdreader-notary}"

# Building for Intel as well needs full Xcode; the Command Line Tools only build for this Mac.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCH_FLAGS=(--arch arm64 --arch x86_64)
echo "==> Compiling"
if ! swift build -c release "${ARCH_FLAGS[@]}" 2>/dev/null; then
  echo "    universal build unavailable, building for this Mac only"
  ARCH_FLAGS=()
  swift build -c release
fi
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Neutrino" "$APP/Contents/MacOS/Neutrino"
strip -x "$APP/Contents/MacOS/Neutrino"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
# AppIcon.icns is the icon for macOS before 26; Assets.car holds the layered one for 26 and later.
cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
cp Resources/neutrino "$APP/Contents/Resources/neutrino"
chmod +x "$APP/Contents/Resources/neutrino"
# The lists of published syntaxes and themes, so the app can offer them before it has been online.
cp syntaxes/index.json "$APP/Contents/Resources/syntaxes.json"
cp themes/index.json "$APP/Contents/Resources/themes.json"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  echo "==> Signing as $IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Neutrino.entitlements --sign "$IDENTITY" "$APP"
else
  IDENTITY="-"
  echo "==> Signing (ad-hoc)"
  codesign --force --options runtime --entitlements Resources/Neutrino.entitlements --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Done: $APP v$VERSION ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/Neutrino"))"

notarize() {
  echo "==> Notarizing $(basename "$1")"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [[ "$MODE" == "--release" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    echo "error: --release needs a Developer ID Application certificate in the keychain" >&2
    exit 1
  fi

  # Notarize the app itself and staple the ticket, so it opens offline too.
  ZIP="build/Neutrino-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

  # Disk image with the usual "drag to Applications" layout, signed and notarized as well.
  DMG="build/Neutrino-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Neutrino $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"

  spctl --assess --type execute "$APP"
  spctl --assess --type open --context context:primary-signature "$DMG"
  echo "==> $ZIP  sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  echo "==> $DMG  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi

# Keep build copies out of Finder's "Open With" list; only the installed app should appear there.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
"$LSREGISTER" -u "$PWD/build/dmg/Neutrino.app" 2>/dev/null || true

if [[ "$MODE" == "--install" ]]; then
  rm -rf /Applications/Neutrino.app
  cp -R "$APP" /Applications/
  # Register with Launch Services so "Open With" picks it up immediately.
  "$LSREGISTER" -f /Applications/Neutrino.app
  echo "==> Installed to /Applications/Neutrino.app"
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [[ -w "$dir" ]]; then
      ln -sf /Applications/Neutrino.app/Contents/Resources/neutrino "$dir/neutrino"
      echo "==> Linked $dir/neutrino"
      break
    fi
  done
fi
