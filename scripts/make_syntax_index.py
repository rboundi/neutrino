#!/usr/bin/env python3
"""Rebuilds syntaxes/index.json from the syntax files next to it.
Run it after adding or changing a syntax: scripts/make_syntax_index.py"""
import json
import pathlib

folder = pathlib.Path(__file__).resolve().parent.parent / "syntaxes"
entries = []
for path in sorted(folder.glob("*.json")):
    if path.name == "index.json":
        continue
    syntax = json.loads(path.read_text())
    if syntax["id"] != path.stem:
        raise SystemExit(f"{path.name}: id must be \"{path.stem}\"")
    entry = {key: syntax[key] for key in ("id", "name", "version", "extensions")}
    for key in ("filenames", "firstLine"):
        if key in syntax:
            entry[key] = syntax[key]
    entries.append(entry)

entries.sort(key=lambda entry: entry["name"].lower())
lines = ",\n".join("    " + json.dumps(entry, ensure_ascii=False) for entry in entries)
(folder / "index.json").write_text('{\n  "syntaxes": [\n' + lines + "\n  ]\n}\n")
print(f"{len(entries)} syntaxes")
