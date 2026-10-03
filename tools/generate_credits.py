#!/usr/bin/env python3
"""Write assets/credits.json, the list the main menu's Credits page shows, from the credit files.

Every sound, model and texture someone gave the project carries its credit in a
`.txt` beside it, with the same base name (`a_starry_night.ogg` ->
`a_starry_night.txt`); a shared material carries it in its `material.json`.
Those `.txt` files never reach a build (export_presets.cfg only takes `*.json`
among non-resources), so the game cannot read them: this script gathers them
into one JSON file that it can. Nobody edits that file by hand -- a pull
request that touches a credit gets it rewritten by .github/workflows/credits.yml.

A credit file holds one line per author, in one of two forms:

    Discord - <pseudo> - <numeric Discord id>
    <Site> - <author> - <URL> - <licence>

The first is a community member; their work is CC0 by project rule, so no
licence is written. The second is a third-party source (Freesound, Pixabay...),
whose licence must be stated because some of them require the attribution the
Credits page gives.

A `.txt` credits the file of the same base name (`truck-horn.txt` ->
`truck-horn.ogg`); when there is none, every file starting `<base>_` (a texture
set: `metal_iron_041A_4K.txt` -> `metal_iron_041A_4K_Color.jpg`, ...).

Errors, all reported before exiting with code 1:
  * a line in neither form, or a Discord id that is not a number;
  * a `.txt` that credits no file (its asset was renamed or removed);
  * one Discord id under two pseudos (the page would show the same person twice);
  * a sound with no credit file.

Usage:
    python3 tools/generate_credits.py              # rewrite assets/credits.json
    python3 tools/generate_credits.py --check      # fail if it is not up to date
    python3 tools/generate_credits.py --validate   # check the credit files only

Dependencies: none -- Python 3 standard library only, so CI needs no pip step.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT = REPO_ROOT / "assets" / "credits.json"
# Where credited work lives. Icons under ui/ and scenes/ are not credited on the page.
ROOTS = ("assets", "assets_blender")

AUDIO = {".ogg", ".mp3", ".wav", ".flac"}
# Beside an asset but never the asset itself.
NOT_ASSETS = {".txt", ".import", ".blend1", ".uid", ".md"}
# Licence and generated files that sit among the assets but credit nothing by name.
NOT_CREDITS = {"license", "license.txt", "license.md", "readme.txt", "blender_assets.cats.txt"}

# The page's sections, in its order.
CATEGORIES = ("music", "sfx", "models")
# A community member's work is CC0 by project rule.
MEMBER_LICENCE = "CC0"

DISCORD = re.compile(r"^Discord - (?P<author>.+?) - (?P<id>\S+)$")
THIRD_PARTY = re.compile(r"^(?P<site>.+?) - (?P<author>.+?) - (?P<url>https?://\S+) - (?P<license>.+)$")
URL_IN_TEXT = re.compile(r"https?://\S+")


@dataclass(frozen=True)
class Credit:
    """One author of one asset: one line of the page."""

    category: str
    asset: str
    author: str
    source: str
    id: str = ""
    url: str = ""
    license: str = ""
    # res:// path of the (first) credited file: what the Credits page plays its music from.
    path: str = ""

    def as_json(self) -> dict:
        return {
            "asset": self.asset,
            "path": self.path,
            "author": self.author,
            "source": self.source,
            "id": self.id,
            "url": self.url,
            "license": self.license,
        }


def parse_line(line: str) -> dict | None:
    """The fields of one credit line, or None when it is in neither form.

    Raises ValueError for a Discord line whose id is not a number: it is
    recognisably a Discord credit, so "not a credit line" would mislead.
    """
    line = line.strip().lstrip("﻿")
    match = DISCORD.match(line)
    if match:
        if not match["id"].isdigit():
            raise ValueError("the Discord id must be the long number, not a user name: %r" % match["id"])
        return {"source": "Discord", "author": match["author"].strip(), "id": match["id"],
                "url": "", "license": MEMBER_LICENCE}
    match = THIRD_PARTY.match(line)
    if match:
        return {"source": match["site"].strip(), "author": match["author"].strip(), "id": "",
                "url": match["url"], "license": match["license"].strip()}
    return None


def category_of(asset: Path) -> str:
    """music, sfx or models (which covers textures and materials too)."""
    if asset.suffix.lower() in AUDIO:
        return "music" if "/audio/music/" in asset.as_posix() else "sfx"
    return "models"


def credited_files(sidecar: Path, folder: list[Path]) -> list[Path]:
    """The files a credit .txt names among `folder` (its directory's files): the same base name,
    else the `<base>_` set."""
    base = sidecar.stem
    siblings = [p for p in folder if p.suffix.lower() not in NOT_ASSETS]
    exact = [p for p in siblings if p.stem == base]
    if exact:
        return sorted(exact)
    return sorted(p for p in siblings if p.name.startswith(base + "_"))


def asset_label(sidecar: Path, files: list[Path]) -> str:
    """What the page names: the file, or `<base>_*` for a set."""
    if len(files) == 1 and files[0].stem == sidecar.stem:
        return files[0].name
    exact = [p for p in files if p.stem == sidecar.stem]
    if exact:
        return exact[0].name
    return sidecar.stem + "_*"


def read_sidecar(sidecar: Path, folder: list[Path], root: Path, errors: list[str]) -> list[Credit]:
    rel = sidecar.relative_to(root).as_posix()
    files = credited_files(sidecar, folder)
    if not files:
        errors.append("%s: credits no file (no %s.* nor %s_* beside it)" % (rel, sidecar.stem, sidecar.stem))
        return []
    label = asset_label(sidecar, files)
    category = category_of(files[0])
    path = "res://" + files[0].relative_to(root).as_posix()
    credits: list[Credit] = []
    text = sidecar.read_text(encoding="utf-8")
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            fields = parse_line(line)
        except ValueError as error:
            errors.append("%s:%d: %s" % (rel, number, error))
            continue
        if fields is None:
            errors.append("%s:%d: not a credit line: %r\n    expected 'Discord - <pseudo> - <id>' "
                          "or '<Site> - <author> - <URL> - <licence>'" % (rel, number, line.strip()))
            continue
        credits.append(Credit(category=category, asset=label, path=path, **fields))
    if not credits and not any(e.startswith(rel) for e in errors):
        errors.append("%s: empty credit file" % rel)
    return credits


def read_material(manifest: Path, root: Path, errors: list[str]) -> list[Credit]:
    """A shared material's credit, from the author and licence its manifest already holds."""
    rel = manifest.relative_to(root).as_posix()
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        errors.append("%s: unreadable: %s" % (rel, error))
        return []
    author = str(data.get("author", "")).strip()
    if not author:
        errors.append("%s: no author" % rel)
        return []
    url = URL_IN_TEXT.search(str(data.get("notes", "")))
    return [Credit(category="models", asset=manifest.parent.name, author=author, source="",
                   path="res://" + manifest.parent.relative_to(root).as_posix(),
                   url=url.group(0) if url else "", license=str(data.get("license", "")))]


def is_credit_file(path: Path) -> bool:
    return path.suffix.lower() == ".txt" and path.name.lower() not in NOT_CREDITS


def tracked_files(root: Path) -> list[Path]:
    """The files under ROOTS that git tracks: the same set here as on CI, whatever else lies on disk.
    Outside a git checkout, every file."""
    try:
        listed = subprocess.run(["git", "ls-files", "-z", "--", *ROOTS], cwd=root, capture_output=True,
                                check=True).stdout.decode("utf-8")
        return sorted(root / name for name in listed.split("\0") if name)
    except (OSError, subprocess.CalledProcessError):
        return sorted(p for top in ROOTS for p in (root / top).rglob("*") if p.is_file())


def collect(root: Path = REPO_ROOT, files: list[Path] | None = None) -> tuple[list[Credit], list[str]]:
    """Every credit in `files` (default: those git tracks under ROOTS), and every problem found."""
    if files is None:
        files = tracked_files(root)
    folders: dict[Path, list[Path]] = {}
    for path in files:
        folders.setdefault(path.parent, []).append(path)
    credits: list[Credit] = []
    errors: list[str] = []
    for path in files:
        if is_credit_file(path):
            credits.extend(read_sidecar(path, folders[path.parent], root, errors))
        elif path.name == "material.json":
            credits.extend(read_material(path, root, errors))
        elif path.suffix.lower() in AUDIO and path.with_suffix(".txt") not in folders[path.parent]:
            errors.append("%s: no credit file (%s.txt)" % (path.relative_to(root).as_posix(), path.stem))
    errors.extend(pseudo_conflicts(credits))
    return credits, errors


def pseudo_conflicts(credits: list[Credit]) -> list[str]:
    """One Discord id written under two pseudos: one name per person on the page."""
    seen: dict[str, set[str]] = {}
    for credit in credits:
        if credit.source == "Discord":
            seen.setdefault(credit.id, set()).add(credit.author)
    return ["Discord id %s is written under several pseudos: %s -- use one"
            % (id_, ", ".join(sorted(names))) for id_, names in sorted(seen.items()) if len(names) > 1]


def render(credits: list[Credit]) -> str:
    """The JSON text, stable for a given set of credits: no date, fixed order, LF."""
    out: dict[str, list[dict]] = {category: [] for category in CATEGORIES}
    for credit in sorted(set(credits), key=lambda c: (c.asset.lower(), c.asset, c.author.lower(), c.source)):
        out[credit.category].append(credit.as_json())
    return json.dumps(out, indent="\t", ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail if assets/credits.json is not up to date")
    mode.add_argument("--validate", action="store_true", help="check the credit files only, write nothing")
    args = parser.parse_args(argv)

    credits, errors = collect()
    if errors:
        print("%d credit problem(s):" % len(errors), file=sys.stderr)
        for error in errors:
            print("  " + error, file=sys.stderr)
        return 1
    if args.validate:
        print("%d credits, all well formed." % len(credits))
        return 0
    text = render(credits)
    current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.is_file() else ""
    if args.check:
        if current != text:
            print("assets/credits.json is out of date: run  python3 tools/generate_credits.py", file=sys.stderr)
            return 1
        print("assets/credits.json is up to date (%d credits)." % len(credits))
        return 0
    if current != text:
        OUTPUT.write_text(text, encoding="utf-8", newline="\n")
        print("assets/credits.json written (%d credits)." % len(credits))
    else:
        print("assets/credits.json already up to date (%d credits)." % len(credits))
    return 0


if __name__ == "__main__":
    sys.exit(main())
