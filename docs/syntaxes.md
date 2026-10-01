# Syntax files

A syntax is one JSON file. Neutrino reads installed syntaxes from
`~/Library/Application Support/Neutrino/Syntaxes`. The published ones are in the
[`syntaxes`](../syntaxes) folder of the repository, and the app downloads them from there.

To try a file of your own, use **Settings → Syntaxes → Install from File…**. The file is checked
when it is installed; a rule that isn't a valid regular expression is reported with its number.

## Format

```json
{
  "id": "lua",
  "name": "Lua",
  "version": 1,
  "extensions": ["lua"],
  "lineComment": "--",
  "blockComment": ["--[[", "]]"],
  "rules": [
    {"scope": "comment", "match": "--.*"},
    {"scope": "string", "begin": "\"", "end": "\"", "escape": "\\\\", "multiline": false},
    {"scope": "keyword", "words": ["and", "break", "do", "else", "end"]},
    {"scope": "number", "match": "\\b\\d+\\b"}
  ]
}
```

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | Lower-case name without spaces. The file must be named `<id>.json` |
| `name` | yes | Name shown in menus |
| `version` | yes | A whole number. Raise it when you change the file, so installed copies show **Update** |
| `extensions` | yes | File extensions, lower case, without the dot |
| `filenames` | no | Whole file names, such as `Makefile` |
| `firstLine` | no | Regular expression tested against the first line, for scripts without an extension |
| `lineComment` | no | Marker used by **Comment or Uncomment** |
| `blockComment` | no | Start and end markers, used when there is no `lineComment` |
| `caseInsensitive` | no | `true` to ignore case in every rule |
| `indentWithTabs` | no | `true` for languages that need tab characters |
| `rules` | yes | The rules, in order of priority |

## Rules

Each rule has a `scope` and one of three forms:

- `"match"`: a regular expression.
- `"begin"` and `"end"`: regular expressions for the two ends of a region, such as a string or a
  block comment. `"escape"` is a regular expression for the escape character inside it.
  With `"multiline": false` the region stops at the end of the line. A region that is never
  closed runs to the end of the file, or of the line.
- `"words"`: a list of whole words, matched literally.

Scopes: `comment`, `string`, `keyword`, `number`, `type`, `function`, `constant`, `variable`,
`tag`, `attribute`, `operator`, `heading`, `link`, `emphasis`, `inserted`, `deleted`.

## How rules are applied

The text is read once from start to end. At each position the first rule that matches wins, and
reading continues after that match. So a `//` inside a string is not a comment, as long as the
string rule matches first, and earlier rules take priority over later ones at the same position.

Regular expressions use the ICU syntax of `NSRegularExpression`. `^` and `$` match at line
boundaries. Use `(?:…)` for grouping. For a backreference, name the group:
`(?<quote>['"]).*?\k<quote>`. Numbered backreferences such as `\1` don't work, because all
rules are joined into one expression.

## Publishing a syntax

1. Add `syntaxes/<id>.json`.
2. Run `scripts/make_syntax_index.py` to rebuild `syntaxes/index.json`.
3. Run `swift test`. It compiles every syntax file and checks the index.
