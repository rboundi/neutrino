# Theme files

A theme is one JSON file. Neutrino reads installed themes from
`~/Library/Application Support/Neutrino/Themes`. The published ones are in the
[`themes`](../themes) folder of the repository, and the app downloads them from there.

To try a file of your own, use **Settings → Appearance → Install from File…**, then pick it
under **Colours**.

## Format

```json
{
  "id": "nord",
  "name": "Nord",
  "version": 1,
  "dark": true,
  "background": "#2E3440",
  "text": "#D8DEE9",
  "selection": "#434C5E",
  "currentLine": "#353B49",
  "lineNumbers": "#4C566A",
  "findMatch": "#6B5F2E",
  "scopes": {
    "comment": "#616E88",
    "string": "#A3BE8C",
    "keyword": "#81A1C1"
  }
}
```

| Key | Meaning |
|---|---|
| `id` | Lower-case name without spaces. The file must be named `<id>.json` |
| `name` | Name shown in Settings |
| `version` | A whole number. Raise it when you change the file, so installed copies show **Update** |
| `dark` | `true` if the window around the text should use the dark appearance |
| `background`, `text` | The page and ordinary text |
| `selection` | Background of selected text |
| `currentLine` | Background of the line with the caret |
| `lineNumbers` | Line numbers |
| `findMatch` | Background of search matches |
| `scopes` | A colour for each scope a syntax can name. Scopes left out use `text` |

Colours are written as `#RRGGBB`. The scopes are `comment`, `string`, `keyword`, `number`,
`type`, `function`, `constant`, `variable`, `tag`, `attribute`, `operator`, `heading`, `link`,
`emphasis`, `inserted` and `deleted`.

## Publishing a theme

1. Add `themes/<id>.json`.
2. Run `scripts/make_index.py` to rebuild `themes/index.json`.
3. Run `swift test`. It checks every theme file and the index.
