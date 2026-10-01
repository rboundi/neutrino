# Contributing

Neutrino edits single files. Project sidebars, plugins that run code, language servers and a built-in terminal are out of scope. For larger changes, open an issue first.

## Setup

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). The tests need Xcode.

```bash
./build.sh                # builds build/Neutrino.app
open build/Neutrino.app
swift test
```

## Where things live

- **Core** (`Sources/NeutrinoCore/`): the tokenizer, search and replace, encodings and the line index. No UI. Changes here need a test.
- **App** (`Sources/Neutrino/`): AppKit and TextKit 1, with SwiftUI for the Settings pages. No third-party packages.
- **Syntaxes** (`syntaxes/`): one JSON file per language. The format is in [docs/syntaxes.md](docs/syntaxes.md). After adding or changing one, run `scripts/make_index.py`.
- **Themes** (`themes/`): one JSON file per theme. The format is in [docs/themes.md](docs/themes.md).
- **Icon** (`Resources/AppIcon.icon`): a layered Icon Composer document. Run `./scripts/make_icon.sh` after changing it; it needs Xcode 26 or later.

## Guidelines

- Nothing is loaded before it is needed. Syntaxes and themes stay out of the app bundle.
- Avoid `NSTextView.string` and `NSTextStorage.string` in code that runs on every edit; they copy the text. Use `mutableString`.
- `swift build` should have no warnings.
- Syntax files are data. The app never runs code it downloads.

## Releasing

Releases are built and notarized on the maintainer's Mac, so no Apple credentials are stored on GitHub:

```bash
scripts/release.sh 1.0.0
```

The script checks that `main` is pushed and CI passed, builds a universal app, signs it with the Developer ID certificate, notarizes and staples the app and the .dmg, tags the commit, publishes the GitHub release and updates the Homebrew cask.

It needs, on that Mac:
- Xcode (for the Intel slice)
- a **Developer ID Application** certificate in the keychain
- a notarytool profile named `mdreader-notary` (shared with MDReader), or another one named in `$NOTARY_PROFILE`:
  `xcrun notarytool store-credentials mdreader-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>`
