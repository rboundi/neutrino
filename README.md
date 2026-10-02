<p align="center">
  <img src="docs/icon-256.png" width="128" alt="Neutrino icon">
</p>

<h1 align="center">Neutrino</h1>

<p align="center">A code editor for the Mac. Tabs, multiple cursors and regex find and replace, with syntaxes and themes installed as needed. Free and open source.</p>

<p align="center">
  <img src="docs/screenshot-dark.png" width="760" alt="Neutrino with four tabs, a Swift file and a regex search in the find bar">
</p>

## Features

**Editing**
- Native macOS tabs: drag to reorder or out to a new window
- Line numbers, line wrapping, current line highlight, invisible characters
- Auto-indent, and auto-closing brackets and quotes
- Copy and Cut take the whole line when nothing is selected; Paste and Match Indentation
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>←</kbd> / <kbd>⌃</kbd><kbd>⌥</kbd><kbd>→</kbd> move by the parts of a name such as `camelCase`
- Spaces or tabs, any tab width; change it for one document from the status bar
- Uses the indentation a file already has
- Matching bracket highlight, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>M</kbd> to jump to it
- Other occurrences of the selected word are marked
- Word completion from the document (<kbd>⌥</kbd><kbd>Esc</kbd>)
- Folding: collapse a block in JSON, HTML or any indented text from the gutter or with <kbd>⌥</kbd><kbd>⌘</kbd><kbd>←</kbd>; Fold All, or down to level 2 or 3. A reopened file is folded as it was
- CSV and TSV files as a table (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd>): sort by a column, filter the rows, copy them as Markdown or JSON, double-click a row to go to it in the text
- Lines changed since the file was opened or saved are marked beside their number
- Snippets: type an abbreviation and press <kbd>Tab</kbd>. They are kept in one text file (**Edit → Insert → Edit Snippets…**)
- In a JSON file the status bar shows where the caret is, such as `items[3].name`
- Split editor: two views of the same document, with a divider you can drag (<kbd>⌘</kbd><kbd>\</kbd>)
- Optional scrolling past the end, page guide, indent guides, marks on trailing spaces, hex colours underlined in their colour, spell checking
- Read-only lock in the status bar; a file that can't be written opens locked
- In Markdown, Return continues a list, and <kbd>⌘</kbd><kbd>B</kbd> / <kbd>⌘</kbd><kbd>I</kbd> make the selection bold or italic
- Text size buttons in the status bar; click the line and column to count lines, words and characters and to see the Unicode name of the character at the caret. With numbers selected, the click shows their sum and average

**Cursors and lines**
- Select the next occurrence with <kbd>⌘</kbd><kbd>D</kbd>, or all of them with <kbd>⌃</kbd><kbd>⌘</kbd><kbd>G</kbd>
- Add a cursor above or below with <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↓</kbd>, or anywhere with <kbd>⌘</kbd>-click
- Column selection with <kbd>⌥</kbd>-drag
- Insert Numbers types 1, 2, 3… at the cursors; <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↑</kbd> / <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↓</kbd> adds or subtracts one from the number at each
- Expand Selection (<kbd>⌃</kbd><kbd>⇧</kbd><kbd>↑</kbd>): the word, then inside the quotes or brackets, then the line
- Move, duplicate, delete, join, sort and reverse lines, sort by number, remove duplicates and blank lines, trim trailing spaces
- Align lines on a character, and rewrap a paragraph at the page guide (<kbd>⌃</kbd><kbd>Q</kbd>)
- Shift left and right, comment and uncomment, change case
- Filter the selection through a shell command such as `sort -u` or `jq .` (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd>)
- Transform: pretty-print or minify JSON, Base64 and URL encode and decode, JSON string escapes, HTML entities, indentation to spaces or tabs, Zap Gremlins (invisible characters), Straighten Quotes, SHA-256
- Evaluate Expression (<kbd>⌃</kbd><kbd>=</kbd>) replaces `1024*8+12` with its result
- Insert the date, the date and time, or a UUID

**Find and replace**
- Plain text or regex, match case, whole words
- Live match count and highlighting
- Search the document, the selection or all open documents
- Find All lists every match; Copy Matches copies them
- Keep Matching Lines and Delete Matching Lines
- Replace All is one undo step
- Regex replacements: `$1`, `${name}`, `\U…\E`, `\L…\E`, `\u`, `\l`, `\n`, `\t`
- Recent searches

**Navigation**
- Go to Line (<kbd>⌘</kbd><kbd>L</kbd>), also `line:column`
- Go to Symbol (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd>): functions, classes, headings
- <kbd>⌘</kbd><kbd>1</kbd>…<kbd>⌘</kbd><kbd>9</kbd> to switch tabs, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> to reopen a closed one
- A reopened file starts where the caret was
- Open Quickly (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>O</kbd>): type part of a name to jump to a tab or a recent file
- Go to Last Edit (<kbd>⌃</kbd><kbd>-</kbd>), and back through earlier edits
- Bookmarks: <kbd>⌘</kbd><kbd>F2</kbd> marks a line, <kbd>F2</kbd> and <kbd>⇧</kbd><kbd>F2</kbd> jump between marks
- Open the path or link at the caret (<kbd>⌃</kbd><kbd>⌘</kbd><kbd>O</kbd>), including `file:line`

**Files**
- Autosave, with macOS versions. Can be turned off in Settings
- Unsaved text is recovered after a crash
- Encoding, byte order mark and line endings are preserved; change them from the status bar
- Live reload when a file changes on disk; with the caret on the last line it follows the end, like `tail -f`
- Printing keeps the syntax colours
- A file that isn't text is shown as hex
- Compare with Saved shows a diff against the file on disk; Compare with Tab and Compare with Clipboard against another open document or the clipboard
- New from Clipboard, Reveal in Finder, Copy Path, Open Terminal Here
- Save All, Duplicate, Rename, Move To, Close Other Tabs, Close Tabs to the Right
- Two tabs with the same file name show their folders
- `.editorconfig` support
- Optional trailing-space removal and final line break on save
- Quitting never asks to save: windows and unsaved text come back at the next launch. Only closing a tab asks

**Syntaxes**
- Installed from **Settings → Syntaxes** or the status bar, loaded only while in use
- C, C++, C#, CSS, Diff, Dockerfile, Go, HTML, INI, Java, JavaScript, JSON, Kotlin, Lua, Makefile, Markdown, PHP, Python, Ruby, Rust, Shell, SQL, Swift, TOML, TypeScript, XML, YAML
- Add your own as a JSON file: [docs/syntaxes.md](docs/syntaxes.md)

**Themes**
- Light, Dark or System
- Dracula, GitHub Light, Monokai, Nord, One Dark, Solarized Dark and Solarized Light from **Settings → Appearance**
- Add your own as a JSON file: [docs/themes.md](docs/themes.md)

**Other**
- `neutrino` command: `neutrino main.c`, `neutrino main.c:42` or `git diff | neutrino`
- Open in Neutrino in the Services menu, for files selected in Finder
- Preview Markdown in [MDReader](https://github.com/rboundi/mdreader) (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>P</kbd>)
- Weekly check for new versions on GitHub (can be turned off)

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
| Find in open documents | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| Use Selection for Find | <kbd>⌘</kbd><kbd>E</kbd> |
| Go to Line / Symbol | <kbd>⌘</kbd><kbd>L</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Go to matching bracket | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>M</kbd> |
| Select next occurrence / all occurrences | <kbd>⌘</kbd><kbd>D</kbd> / <kbd>⌃</kbd><kbd>⌘</kbd><kbd>G</kbd> |
| Move by part of a name | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>←</kbd> / <kbd>⌃</kbd><kbd>⌥</kbd><kbd>→</kbd> |
| Paste and match indentation | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>V</kbd> |
| Close other tabs / Save All | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>W</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd> |
| Add cursor above / below | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↓</kbd> |
| Split selection into lines | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>L</kbd> |
| Move line up / down | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌃</kbd><kbd>⌘</kbd><kbd>↓</kbd> |
| Duplicate / delete / join lines | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd> / <kbd>⌘</kbd><kbd>J</kbd> |
| Shift left / right | <kbd>⌘</kbd><kbd>[</kbd> / <kbd>⌘</kbd><kbd>]</kbd> |
| Comment or uncomment | <kbd>⌘</kbd><kbd>/</kbd> |
| Filter Through Command | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd> |
| Complete word | <kbd>⌥</kbd><kbd>Esc</kbd> |
| Open Quickly | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Open path or link at caret | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Go to last edit | <kbd>⌃</kbd><kbd>-</kbd> |
| Toggle / next / previous bookmark | <kbd>⌘</kbd><kbd>F2</kbd> / <kbd>F2</kbd> / <kbd>⇧</kbd><kbd>F2</kbd> |
| Expand / shrink selection | <kbd>⌃</kbd><kbd>⇧</kbd><kbd>↑</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>↓</kbd> |
| Increase / decrease number | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↑</kbd> / <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↓</kbd> |
| Rewrap paragraph | <kbd>⌃</kbd><kbd>Q</kbd> |
| New from Clipboard | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>N</kbd> |
| Reveal in Finder / Copy Path | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd> / <kbd>⌃</kbd><kbd>⌘</kbd><kbd>C</kbd> |
| Bold / italic in Markdown | <kbd>⌘</kbd><kbd>B</kbd> / <kbd>⌘</kbd><kbd>I</kbd> |
| Split editor | <kbd>⌘</kbd><kbd>\</kbd> |
| Fold / unfold | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>←</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>→</kbd> |
| Fold all / unfold all | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>←</kbd> / <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>→</kbd> |
| Evaluate expression | <kbd>⌃</kbd><kbd>=</kbd> |
| Show as table | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Preview in MDReader | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>P</kbd> |
| Reopen closed tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Show tab 1–8 / last tab | <kbd>⌘</kbd><kbd>1</kbd>…<kbd>⌘</kbd><kbd>8</kbd> / <kbd>⌘</kbd><kbd>9</kbd> |
| Bigger / smaller / default text size | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>-</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| Settings | <kbd>⌘</kbd><kbd>,</kbd> |

## Privacy

Neutrino only connects to the internet to download the syntaxes and themes you install, and to check `github.com` for new versions once a week. The update check can be turned off in Settings. There is no analytics or telemetry.

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
  TextTools.swift               Indentation detection, word count, JSON, Base64 and URL transforms
  Table.swift                   Reading CSV, and which lines a fold hides
  ChangedLines.swift            Which lines differ from the saved text
  EditingTools.swift            JSON path, snippets, arithmetic
Sources/Neutrino/
  main.swift, AppDelegate.swift App entry, launch and quit
  MainMenu.swift                Menu bar
  Document.swift                An open file: reading, writing, reloading
  EditorWindowController.swift  Window layout, colours, settings
  EditorPane.swift              One view of the text with its line numbers; two when split
  EditorFind.swift              Find and replace
  EditorCommands.swift          Shell filter and the symbol menu
  EditorTextView.swift          Text view: cursors, line commands, brackets, invisibles, line numbers
  FindBar.swift                 Find bar and the Find All list
  OpenQuickly.swift             Panel for jumping to a tab or a recent file
  DelimitedTableView.swift      A CSV file shown as a table
  HexView.swift                 A binary file shown as hex
  SnippetStore.swift            The snippets file
  StatusBar.swift               Status bar and its menus
  PackageFolder.swift           Installing and removing downloaded files
  SyntaxStore.swift             Loading and unloading syntaxes
  Theme.swift                   Colours and the theme in use
  SettingsView.swift            Settings window
  UpdateChecker.swift           Release check
syntaxes/                       Published syntax files and their index
themes/                         Published theme files and their index
Resources/                      Info.plist, icon, the neutrino command
scripts/                        Icon builder, index builder, release script
Tests/                          Tests for NeutrinoCore and every syntax and theme file
```

AppKit and TextKit 1, with no third-party packages. Only the text on screen is coloured, and only the edited part is rescanned.

## Development

```bash
./build.sh                    # builds build/Neutrino.app
open build/Neutrino.app
swift test                    # needs Xcode
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for adding syntaxes and for releases.

## License

MIT. See [LICENSE](LICENSE).
