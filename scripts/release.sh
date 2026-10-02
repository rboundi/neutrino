#!/bin/bash
# Publishes a release from this Mac: builds the universal app, signs and notarizes it,
# tags the commit, creates the GitHub release and updates the Homebrew cask.
#   scripts/release.sh 1.1.0
# Needs the Developer ID Application certificate and the "mdreader-notary" notarytool
# profile in the keychain (see CONTRIBUTING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="rboundi/neutrino"
TAP="rboundi/homebrew-tap"
VERSION="${1:?usage: scripts/release.sh <version>}"
VERSION="${VERSION#v}"
TAG="v$VERSION"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3"
[[ "$(git branch --show-current)" == main ]] || fail "switch to main first"
# Untracked files count too: a source file that was never committed would still be compiled in.
[[ -z "$(git status --porcelain)" ]] || fail "commit, stash or remove your changes first: $(git status --porcelain | head -3)"
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "push main first"
# A tag left by a run that stopped before the release was published is taken up again.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || fail "$TAG already exists on another commit"
  ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || fail "$TAG is already released"
fi
CI=$(gh run list --repo "$REPO" --workflow ci.yml --commit "$(git rev-parse HEAD)" --json conclusion -q '.[0].conclusion')
[[ "$CI" == success ]] || fail "CI hasn't passed for this commit (status: ${CI:-no run})"

VERSION="$VERSION" ./build.sh --release
ZIP="build/Neutrino-$VERSION.zip"
DMG="build/Neutrino-$VERSION.dmg"

# Version-less copies give a permanent link to the newest release:
# https://github.com/rboundi/neutrino/releases/latest/download/Neutrino.dmg
cp "$DMG" build/Neutrino.dmg
cp "$ZIP" build/Neutrino.zip

echo "==> Publishing $TAG"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Neutrino $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" build/Neutrino.dmg build/Neutrino.zip --repo "$REPO" \
  --title "Neutrino $VERSION" --generate-notes \
  --notes "Universal build for macOS 13 or later. Download the .dmg and drag Neutrino to Applications."

echo "==> Updating the Homebrew cask"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh repo clone "$TAP" "$TMP/tap" -- -q
mkdir -p "$TMP/tap/Casks"
sed -e '/^#/d' \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    packaging/homebrew/neutrino.rb > "$TMP/tap/Casks/neutrino.rb"
git -C "$TMP/tap" add Casks/neutrino.rb
git -C "$TMP/tap" diff --cached --quiet || {
  git -C "$TMP/tap" commit -q -m "neutrino $VERSION"
  git -C "$TMP/tap" push -q
}

echo "==> Released: https://github.com/$REPO/releases/tag/$TAG"
