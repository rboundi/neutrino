<p align="center">
  <img src="docs/icon-256.png" width="128" alt="Neutrino icon">
</p>

<h1 align="center">Neutrino</h1>

<p align="center">A small code editor for the Mac. Tabs, syntax colouring and regex find and replace. Free and open source.</p>

<p align="center">
  <img src="docs/screenshot-dark.png" width="760" alt="Neutrino with four tabs, a Swift file and the find bar showing a regex search">
</p>

## Features

**Editing**
- Tabs, using the standard macOS window tabs: drag to reorder, drag out to a new window, <kbd>⌘</kbd><kbd>T</kbd> for a new one
- Line numbers, line wrapping, current line highlight, invisible characters
- Indentation is kept on new lines; brackets and quotes are closed as you type
- Spaces or tabs, with any tab width. Makefiles and Go files always use tabs
- Multiple cursors: <kbd>⌘</kbd><kbd>D</kbd> selects the next occurrence, <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>↓</kbd> adds a cursor above or below, <kbd>⌘</kbd>-click adds one anywhere, <kbd>⌥</kbd>-drag selects a column. <kbd>Esc</kbd> goes back to one
- Line commands: move up and down, duplicate, delete, join, sort, remove duplicates, shift left and right, comment and uncomment, change case
- The bracket matching the one beside the caret is highlighted; <kbd>⇧</kbd><kbd>⌘</kbd><kbd>M</kbd> jumps to it
- **Filter Through Command** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd>) sends the selection, or the whole text, through a shell command such as `sort -u` or `jq .` and replaces it with the output
- Go to line (<kbd>⌘</kbd><kbd>L</kbd>) and go to symbol (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd>): the functions, classes and headings of the document
- `.editorconfig` files are followed for indent style, indent size, trailing spaces and the final line break
- A file's encoding, byte order mark and line endings are kept when saving. Change them, or reopen with another encoding, from the status bar
- Changes are saved automatically a few seconds after you stop typing and when you switch to another window or app. macOS keeps earlier versions (**File → Revert to Saved**)
- With **Settings → General → Save changes automatically** off, files are only written when you save. Unsaved text is still recovered after a crash
- Files changed by another app are reloaded when there are no unsaved changes
- **File → Compare with Saved** shows what differs from the file on disk, as a diff
- Optionally remove trailing spaces and end the file with a line break when saving
- Text size buttons in the status bar; the size you pick is used for every document from then on

**Find and replace** (<kbd>⌘</kbd><kbd>F</kbd>)
- Plain text or regular expressions, match case, whole words
- Matches are highlighted and counted as you type
- Search the document, the selection, or all open documents
- **Find All** lists every match with its line; click one to go there. **Copy Matches** copies the matched text
- **Replace All** is a single undo step
- In regex replacements: `$1` or `\1` for groups, `${name}` for named groups, `$0` for the whole match, `\U…\E` and `\L…\E` to change case, `\u` and `\l` for one character, `\n` and `\t`
- Recent searches in the search field's menu

**Syntaxes**
- None are built in. Install the ones you use from **Settings → Syntaxes** or from the syntax menu in the status bar
- A syntax is loaded when a document uses it and unloaded when the last such document closes
- Available: C, C++, C#, CSS, Diff, Dockerfile, Go, HTML, INI, Java, JavaScript, JSON, Kotlin, Lua, Makefile, Markdown, PHP, Python, Ruby, Rust, Shell, SQL, Swift, TOML, TypeScript, XML, YAML
- A syntax is one JSON file. See [docs/syntaxes.md](docs/syntaxes.md) to write your own

**Themes**
- Light, dark or system appearance with the built-in colours
- More themes in **Settings → Appearance**, downloaded when you install them: Dracula, GitHub Light, Monokai, Nord, One Dark, Solarized Dark, Solarized Light
- A theme is one JSON file. See [docs/themes.md](docs/themes.md)

**Markdown**
- **File → Preview in MDReader** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>P</kbd>) opens the file in [MDReader](https://github.com/rboundi/mdreader), a free Markdown reader from the same developer. It shows the rendered page and updates as you save

**Other**
- `neutrino` command: `neutrino main.c notes.txt`, `neutrino main.c:42` or `git diff | neutrino`
- Reopen a closed tab with <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd>; <kbd>⌘</kbd><kbd>1</kbd>…<kbd>⌘</kbd><kbd>8</kbd> show that tab, <kbd>⌘</kbd><kbd>9</kbd> the last
- Reopens the documents from the last session
- Weekly check for new versions on GitHub (can be turned off)

Files above 4 million characters open without colours. The whole file is held in memory, so Neutrino asks before opening one larger than 150 MB.

## Install

### Homebrew

```bash
brew install --cask rboundi/tap/neutrino
```

### Download

Download [Neutrino.dmg](https://github.com/rboundi/neutrino/releases/latest/download/Neutrino.dmg), open it and drag Neutrino to Applications. The app is signed and notarized by Apple.

### Build from source

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). With full Xcode installed, the build also includes Intel.

```bash
git clone https://github.com/rboundi/neutrino.git
cd neutrino
./build.sh --install
```

This installs the app to `/Applications` and links the `neutrino` command into `/opt/homebrew/bin` or `/usr/local/bin` if one is writable. The command can also be installed from **Neutrino → Install Command Line Tool…**.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New / Open | <kbd>⌘</kbd><kbd>N</kbd> / <kbd>⌘</kbd><kbd>O</kbd> |
| New tab | <kbd>⌘</kbd><kbd>T</kbd> |
| Save / Save As | <kbd>⌘</kbd><kbd>S</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>S</kbd> |
| Close tab | <kbd>⌘</kbd><kbd>W</kbd> |
| Next / previous tab | <kbd>⌃</kbd><kbd>Tab</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>Tab</kbd> |
| Find and Replace | <kbd>⌘</kbd><kbd>F</kbd> |
| Find next / previous | <kbd>⌘</kbd><kbd>G</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd> (or <kbd>Return</kbd> / <kbd>⇧</kbd><kbd>Return</kbd> in the search field) |
| Find All | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| Use Selection for Find | <kbd>⌘</kbd><kbd>E</kbd> |
| Go to Line / Symbol | <kbd>⌘</kbd><kbd>L</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Go to matching bracket | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>M</kbd> |
| Select next occurrence | <kbd>⌘</kbd><kbd>D</kbd> |
| Add cursor above / below | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↓</kbd> |
| Split selection into lines | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>L</kbd> |
| Move line up / down | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌃</kbd><kbd>⌘</kbd><kbd>↓</kbd> |
| Duplicate / delete / join lines | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd> / <kbd>⌘</kbd><kbd>J</kbd> |
| Shift left / right | <kbd>⌘</kbd><kbd>[</kbd> / <kbd>⌘</kbd><kbd>]</kbd> |
| Comment or uncomment | <kbd>⌘</kbd><kbd>/</kbd> |
| Filter Through Command | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd> |
| Preview in MDReader | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>P</kbd> |
| Reopen closed tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Show tab 1–8 / last tab | <kbd>⌘</kbd><kbd>1</kbd>…<kbd>⌘</kbd><kbd>8</kbd> / <kbd>⌘</kbd><kbd>9</kbd> |
| Bigger / smaller / default text size | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>-</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| Settings | <kbd>⌘</kbd><kbd>,</kbd> |

## Privacy

Neutrino connects to `raw.githubusercontent.com` to list and download syntaxes and themes when you open **Settings → Syntaxes** or **Settings → Appearance**, or install one, and to `github.com` to check for new versions once a week. The update check can be turned off in Settings. There is no analytics or telemetry.

## Project layout

```
Sources/NeutrinoCore/           No UI, covered by tests
  Syntax.swift                  Syntax files, the tokenizer, symbols
  Search.swift                  Search, replacement templates, replace all
  TextCodec.swift               Encodings and line endings
  LineIndex.swift               Line starts, kept up to date across edits
  EditorConfig.swift            Reading .editorconfig files
  UnifiedDiff.swift             Compare with Saved
  ThemeDefinition.swift         Theme files
Sources/Neutrino/
  main.swift, AppDelegate.swift App entry, launch and quit
  MainMenu.swift                Menu bar
  Document.swift                An open file: reading, writing, reloading
  EditorWindowController.swift  Window layout, colours, settings
  EditorFind.swift              Find and replace
  EditorCommands.swift          Shell filter and the symbol menu
  EditorTextView.swift          Text view: cursors, line commands, brackets, invisibles, line numbers
  FindBar.swift                 Find bar and the Find All list
  StatusBar.swift               Status bar and its menus
  PackageFolder.swift           Installing and removing downloaded files
  SyntaxStore.swift             Loading and unloading syntaxes
  Theme.swift                   Colours and the theme in use
  SettingsView.swift            Settings window
  UpdateChecker.swift           Release check
syntaxes/                       Published syntax files and their index
themes/                         Published theme files and their index
Resources/                      Info.plist, icon, the neutrino command
scripts/                        Icon generator, index builder, release script
Tests/                          Tests for NeutrinoCore and every syntax and theme file
```

The app is AppKit with TextKit 1, with no third-party packages. Colours are applied only to the text on screen, and after an edit only the changed part is scanned again.

## Development

```bash
./build.sh                    # builds build/Neutrino.app
open build/Neutrino.app
swift test                    # needs Xcode
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for adding syntaxes and for releases.

## License

MIT. See [LICENSE](LICENSE).
