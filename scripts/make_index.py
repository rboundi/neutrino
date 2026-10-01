#!/usr/bin/env python3
"""Rebuilds syntaxes/index.json and themes/index.json from the files next to them.
Run it after adding or changing a syntax or a theme: scripts/make_index.py"""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent


def build(folder, key, required, optional=()):
    entries = []
    for path in sorted((root / folder).glob("*.json")):
        if path.name == "index.json":
            continue
        item = json.loads(path.read_text())
        if item["id"] != path.stem:
            raise SystemExit(f"{folder}/{path.name}: id must be \"{path.stem}\"")
        entry = {name: item[name] for name in required}
        entry.update({name: item[name] for name in optional if name in item})
        entries.append(entry)
    entries.sort(key=lambda entry: entry["name"].lower())
    lines = ",\n".join("    " + json.dumps(entry, ensure_ascii=False) for entry in entries)
    (root / folder / "index.json").write_text('{\n  "' + key + '": [\n' + lines + "\n  ]\n}\n")
    print(f"{len(entries)} {key}")


build("syntaxes", "syntaxes", ("id", "name", "version", "extensions"), ("filenames", "firstLine"))
build("themes", "themes", ("id", "name", "version", "dark"))
