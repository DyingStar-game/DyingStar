#!/usr/bin/env python3
"""Build the Blender asset library from the material manifests.

Single responsibility: scan, orchestrate, mark as asset, save. Node tree
construction lives in material_builder.py, catalog logic in asset_catalog.py.

Run headless from the repository root:

    blender --background --python tools/build_asset_library.py

Optional arguments go after a bare -- separator:

    blender --background --python tools/build_asset_library.py -- --output my.blend

The generated .blend is an artefact: never edit it by hand, never merge it.
Regenerate it instead.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import bpy
except ImportError:  # pragma: no cover - only reachable outside Blender
    sys.exit("This script must be run by Blender: blender --background --python <this file>")

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asset_catalog import (  # noqa: E402
    catalog_path_for,
    catalog_uuid,
    family_tags_from_vocabulary,
    write_catalog_file,
)
from material_builder import MaterialBuildError, build_material  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
TAGS_PATH = REPO_ROOT / "tools" / "schema" / "tags.json"

# Materials are read from the game side: their maps are real game resources,
# referenced by .tres and shipped in the build.
MATERIALS_DIR = REPO_ROOT / "assets" / "_universe" / "_shared" / "materials"

# The generated .blend is a Blender-side tool, not a game resource. It belongs
# with the other Blender sources and is wiped at build time, as it should be.
# Its image nodes point back at MATERIALS_DIR, which survives.
LIBRARY_DIR = REPO_ROOT / "assets_blender" / "_universe" / "_shared" / "materials"
DEFAULT_OUTPUT = LIBRARY_DIR / "materials_library.blend"

MANIFEST_NAME = "material.json"


def _parse_arguments() -> argparse.Namespace:
    """Read the arguments Blender passes through after a bare -- separator."""
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

    parser = argparse.ArgumentParser(description="Build the material asset library.")
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="path of the generated .blend",
    )
    return parser.parse_args(argv)


def _load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def _mark_as_asset(
    material: "bpy.types.Material",
    manifest: dict,
    catalog_id: str,
) -> None:
    """Expose the material in the Asset Browser with its manifest metadata."""
    material.asset_mark()

    asset_data = material.asset_data
    asset_data.description = manifest.get("notes", manifest["display_name"])
    asset_data.author = manifest["author"]
    asset_data.catalog_id = catalog_id

    for tag in manifest["tags"]:
        asset_data.tags.new(tag)

    # License is not a native asset field, so it travels as a custom property.
    material["license"] = manifest["license"]

    material.asset_generate_preview()


def _build_one(
    folder: Path,
    family_tags: set[str],
) -> tuple[str, str] | None:
    """Build a single material. Returns (material name, catalog path) on success."""
    try:
        manifest = _load_json(folder / MANIFEST_NAME)
    except (OSError, json.JSONDecodeError) as error:
        print(f"SKIP  {folder.name}: unreadable manifest ({error})")
        return None

    try:
        material = build_material(manifest, folder)
    except (MaterialBuildError, KeyError) as error:
        print(f"SKIP  {folder.name}: {error}")
        return None

    catalog = catalog_path_for(manifest["tags"], family_tags)
    _mark_as_asset(material, manifest, catalog_uuid(catalog))

    print(f"OK    {material.name} -> {catalog}")
    return material.name, catalog


def main() -> int:
    arguments = _parse_arguments()

    try:
        family_tags = family_tags_from_vocabulary(_load_json(TAGS_PATH))
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"Cannot load the tag vocabulary: {error}", file=sys.stderr)
        return 2

    folders = sorted(path.parent for path in MATERIALS_DIR.glob(f"*/{MANIFEST_NAME}"))
    if not folders:
        print(f"No material found in {MATERIALS_DIR}", file=sys.stderr)
        return 2

    # Start from an empty file: the library must contain materials and nothing
    # else, and the script must be idempotent.
    bpy.ops.wm.read_factory_settings(use_empty=True)

    catalogs: set[str] = set()
    built = 0

    for folder in folders:
        result = _build_one(folder, family_tags)
        if result is None:
            continue
        catalogs.add(result[1])
        built += 1

    if not built:
        print("No material could be built.", file=sys.stderr)
        return 1

    output = arguments.output
    output.parent.mkdir(parents=True, exist_ok=True)
    write_catalog_file(output.parent, catalogs)

    # The .blend and the maps live in different folders, so paths must be
    # remapped relative to the saved file. Absolute paths would only resolve on
    # the machine that generated the library.
    bpy.ops.wm.save_as_mainfile(filepath=str(output), relative_remap=True)

    print(
        f"\n{built}/{len(folders)} material(s) built into {output}\n"
        f"Declare {output.parent} as an asset library in "
        f"Preferences > File Paths > Asset Libraries."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
