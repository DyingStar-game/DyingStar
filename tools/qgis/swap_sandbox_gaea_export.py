#!/usr/bin/env python3
"""Rename an existing planet export after Sandbox and Gaea swapped slots.

Sandbox moved in to 0.55 AU and became the third planet; Gaea took the fourth. The export
directories are named by SLOT (tarsis_<n>), so the two worlds' data has to swap names with them.

Nothing is regenerated. The body's name lives in the path and in one "planet_name" field per
manifest -- never inside the chunks -- so this is a rename and a two-line edit, not a re-export.
It exists so nobody is blocked waiting for a republished archive; once the new export.tar.gz is
out, a fresh download needs none of this.

Usage, from the repo root:
    python tools/qgis/swap_sandbox_gaea_export.py --dry-run    # show what would move
    python tools/qgis/swap_sandbox_gaea_export.py              # do it

Close Godot first: on Windows a directory cannot be renamed while an open file lives inside it,
and heights.pack is memory-mapped by both the editor and the dedicated server.
"""

import argparse
import json
import os
import re
import sys

EXPORT_DIR = os.path.join("assets", "qgis", "export")
# The swap is a pure exchange of the leading planet index, suffixes untouched:
#   tarsis_4_chunks <-> tarsis_3_chunks, tarsis_4_2_chunks -> tarsis_3_2_chunks, and so on.
PATTERN = re.compile(r"^tarsis_(3|4)(_.*)?$")
TEMP_PREFIX = "_swapping_"


def swapped(name):
    """The new name for an export entry, or None if it is not one of the two planets."""
    m = PATTERN.match(name)
    if m is None:
        return None
    return "tarsis_%s%s" % ("4" if m.group(1) == "3" else "3", m.group(2) or "")


def already_done(root):
    """True when Sandbox's data already sits under tarsis_3.

    Sandbox is the only body with a terrainmodifier.pack, which makes it recognisable whatever
    its directory is called -- more reliable than trusting a manifest somebody may have edited.
    """
    sandbox = os.path.join(root, "tarsis_3_chunks", "terrainmodifier.pack")
    return os.path.exists(sandbox)


def manifest_name(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f).get("planet_name")
    except (OSError, ValueError):
        return None


def rewrite_manifest(path, new_name, dry_run):
    """Set planet_name, preserving the file's formatting (a full json.dump would reflow it)."""
    if not os.path.exists(path):
        return False
    with open(path, encoding="utf-8") as f:
        text = f.read()
    fixed = re.sub(r'("planet_name"\s*:\s*")[^"]*(")', r"\g<1>%s\g<2>" % new_name, text, count=1)
    if fixed == text:
        return False
    if not dry_run:
        with open(path, "w", encoding="utf-8") as f:
            f.write(fixed)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print the moves, change nothing")
    parser.add_argument("--export-dir", default=EXPORT_DIR, help="defaults to %s" % EXPORT_DIR)
    args = parser.parse_args()

    root = args.export_dir
    if not os.path.isdir(root):
        sys.exit("No export directory at %s -- run this from the repo root." % root)

    if already_done(root):
        print("Already swapped: Sandbox's data is under tarsis_3. Nothing to do.")
        return

    moves = [(n, swapped(n)) for n in sorted(os.listdir(root)) if swapped(n)]
    if not moves:
        sys.exit("Found no tarsis_3* or tarsis_4* entries in %s." % root)

    print("%d entr%s to swap:" % (len(moves), "y" if len(moves) == 1 else "ies"))
    for old, new in moves:
        print("  %-34s -> %s" % (old, new))
    if args.dry_run:
        print("\nDry run: nothing changed.")
        return

    # Every source collides with a destination, so go through a temporary namespace.
    for old, _ in moves:
        os.rename(os.path.join(root, old), os.path.join(root, TEMP_PREFIX + old))
    for old, new in moves:
        os.rename(os.path.join(root, TEMP_PREFIX + old), os.path.join(root, new))

    for _, new in moves:
        if not new.endswith("_chunks"):
            continue
        body = new[: -len("_chunks")]
        if rewrite_manifest(os.path.join(root, new, "manifest.json"), body, args.dry_run):
            print("  manifest %s -> planet_name %s" % (new, body))
    for loose in ("tarsis_3_poi.json", "tarsis_4_poi.json"):
        path = os.path.join(root, loose)
        if os.path.exists(path):
            rewrite_manifest(path, loose[: -len("_poi.json")], args.dry_run)

    print("\nDone. Reload the project in Godot so it re-imports the paths.")


if __name__ == "__main__":
    main()
