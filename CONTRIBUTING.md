# Contributing

Neutrino is a code editor for single files. For larger changes, open an issue first.

## Setup

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). The tests need Xcode.

```bash
./build.sh                # builds build/Neutrino.app
open build/Neutrino.app
swift test
```

## Where things live

- **Core** (`Sources/NeutrinoCore/`): the tokenizer, search and replace, encodings, the line index and the text transforms. No UI.
- **App** (`Sources/Neutrino/`): AppKit and TextKit 1, with SwiftUI for the Settings pages. No third-party packages.
- **Syntaxes** (`syntaxes/`) and **themes** (`themes/`): one JSON file each. The formats are in [docs/syntaxes.md](docs/syntaxes.md) and [docs/themes.md](docs/themes.md). Run `scripts/make_index.py` after adding or changing one.
- **Icon** (`Resources/AppIcon.icon`): an Icon Composer document. Run `./scripts/make_icon.sh` after changing it (needs Xcode 26 or later) and commit the regenerated `Assets.car`, `AppIcon.icns` and `docs/icon-256.png`.

## Guidelines

- Add a test in `Tests/` for changes in Core.
- Syntaxes and themes are downloaded when installed, not bundled with the app.
- In code that runs on every edit, use `mutableString` instead of `string`, which copies the text.
- `swift build` should have no warnings.

## Releasing

```bash
scripts/release.sh 1.5.0
```

The script checks that `main` is pushed and CI passed, builds a universal app, signs it with the Developer ID certificate, notarizes and staples the app and the .dmg, tags the commit, publishes the GitHub release and updates the Homebrew cask.

It needs:
- Xcode
- a **Developer ID Application** certificate in the keychain
- a notarytool profile named `mdreader-notary`:
  `xcrun notarytool store-credentials mdreader-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>`
