#!/usr/bin/env python3
"""Validate one or every material of the library.

Single responsibility: orchestrate the three validation layers and report.
The layers themselves live elsewhere (material.schema.json, tags.json,
image_rules.py).

Usage:
    python tools/validate.py                        # every material
    python tools/validate.py <path/to/material>     # a single one

Exit code is 1 when at least one error is found. Warnings never block.

Dependencies: jsonschema, pillow, numpy
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# The rule and loader modules sit next to this script.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from jsonschema import Draft202012Validator

from map_rules import Issue, RulesConfig, inspect
from pillow_loader import load_maps

REPO_ROOT = Path(__file__).resolve().parent.parent

# Layout follows the documented file structure:
# developer.dyingstar-game.com/docs/creativeConcept/files_structure/
# Shared materials live game-side: their maps are referenced by the .tres
# resources and must survive the build, which wipes assets_blender/.
SCHEMA_PATH = REPO_ROOT / "tools" / "schema" / "material.schema.json"
TAGS_PATH = REPO_ROOT / "tools" / "schema" / "tags.json"
MATERIALS_DIR = REPO_ROOT / "assets" / "_universe" / "_shared" / "materials"

MANIFEST_NAME = "material.json"
PREVIEW_NAME = "preview.jpg"

# Map files sit next to the manifest, matching the flat layout used elsewhere
# in the project (no intermediate folder).
MAPS_SUBDIR = "."

# jsonschema embeds the offending instance in its messages, which is unusable
# on a large object. Cap it: the path already says where the problem is.
MAX_SCHEMA_MESSAGE_LENGTH = 140

# orm packs ao, roughness and metallic into one file. Declaring both forms
# leaves the addon no way to know which one is authoritative.
PACKED_MAP = "orm"
UNPACKED_MAPS = ("ao", "roughness", "metallic")

# Shared material ids are mat_<family>_<descriptor>. The family segment is read
# at runtime to pick footstep sounds, so it comes from a closed vocabulary.
MATERIAL_PREFIX = "mat_"
FAMILY_CATEGORY = "family"


def _load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def _flatten_tags(vocabulary: dict) -> set[str]:
    """Collapse the category structure of tags.json into a flat lookup set."""
    return {
        tag
        for category in vocabulary["categories"].values()
        for tag in category
    }


def _family_tags(vocabulary: dict) -> set[str]:
    """The families a material name may declare."""
    return set(vocabulary["categories"].get(FAMILY_CATEGORY, []))


def _check_family_segment(manifest: dict, families: set[str]) -> list[Issue]:
    """The id must be mat_<family>_<descriptor>, with a known family.

    A runtime script picks footstep sounds by reading this segment. An unknown
    or missing family produces no sound at all, and nothing reports it at
    runtime, so it has to be caught here.
    """
    material_id = manifest.get("id", "")
    if not material_id.startswith(MATERIAL_PREFIX):
        return []  # the schema pattern already rejects this

    parts = material_id[len(MATERIAL_PREFIX):].split("_")
    if len(parts) < 2 or not parts[0]:
        return [
            Issue(
                "error",
                "missing_family",
                f"id: '{material_id}' has no family segment. "
                f"Expected {MATERIAL_PREFIX}<family>_<descriptor>.",
            )
        ]

    family = parts[0]
    if family not in families:
        return [
            Issue(
                "error",
                "unknown_family",
                f"id: '{family}' is not a known family. "
                f"Valid values: {', '.join(sorted(families))}.",
            )
        ]

    if family not in manifest.get("tags", []):
        return [
            Issue(
                "warning",
                "family_not_tagged",
                f"tags: '{family}' is in the name but not in the tags, "
                f"so the material lands in the wrong Asset Browser catalog.",
            )
        ]

    return []


def _check_schema(manifest: dict, validator: Draft202012Validator) -> list[Issue]:
    issues: list[Issue] = []
    for error in validator.iter_errors(manifest):
        location = ".".join(str(part) for part in error.absolute_path) or "(root)"
        message = error.message
        if len(message) > MAX_SCHEMA_MESSAGE_LENGTH:
            message = f"{message[:MAX_SCHEMA_MESSAGE_LENGTH]}..."
        issues.append(Issue("error", "schema", f"{location}: {message}"))
    return issues


def _check_map_consistency(manifest: dict) -> list[Issue]:
    """A material declares either a packed ORM or separate channels, never both."""
    maps = manifest.get("maps", {})
    if PACKED_MAP not in maps:
        return []

    conflicting = [name for name in UNPACKED_MAPS if name in maps]
    if not conflicting:
        return []

    return [
        Issue(
            "error",
            "packed_map_conflict",
            f"maps: '{PACKED_MAP}' cannot coexist with {', '.join(conflicting)}. "
            f"Keep either the packed map or the separate channels.",
        )
    ]


def _check_tags(manifest: dict, known_tags: set[str]) -> list[Issue]:
    unknown = [tag for tag in manifest.get("tags", []) if tag not in known_tags]
    if not unknown:
        return []
    return [
        Issue(
            "error",
            "unknown_tag",
            f"tags: {', '.join(unknown)} not in the vocabulary. "
            f"Add them to tools/schema/tags.json in a dedicated commit if they are legitimate.",
        )
    ]


def _check_folder_layout(folder: Path, manifest: dict) -> list[Issue]:
    """The id is the folder name, and a preview is mandatory for PR review."""
    issues: list[Issue] = []

    declared_id = manifest.get("id")
    if declared_id and declared_id != folder.name:
        issues.append(
            Issue(
                "error",
                "id_mismatch",
                f"id '{declared_id}' does not match folder name '{folder.name}'",
            )
        )

    if not (folder / PREVIEW_NAME).is_file():
        issues.append(
            Issue("error", "preview_missing", f"{PREVIEW_NAME} is required")
        )

    return issues


def validate_material(
    folder: Path,
    validator: Draft202012Validator,
    known_tags: set[str],
    families: set[str],
    image_config: RulesConfig,
) -> list[Issue]:
    """Run every layer against a single material folder."""
    manifest_path = folder / MANIFEST_NAME
    if not manifest_path.is_file():
        return [Issue("error", "manifest_missing", f"{MANIFEST_NAME} not found")]

    try:
        manifest = _load_json(manifest_path)
    except json.JSONDecodeError as error:
        return [Issue("error", "manifest_invalid", f"{MANIFEST_NAME}: {error}")]

    issues = _check_schema(manifest, validator)
    issues.extend(_check_map_consistency(manifest))
    issues.extend(_check_tags(manifest, known_tags))
    issues.extend(_check_family_segment(manifest, families))
    issues.extend(_check_folder_layout(folder, manifest))

    # Pixel rules only make sense on hosted materials: external ones live in a
    # third-party archive we do not ship.
    if manifest.get("delivery", {}).get("type") == "hosted":
        samples, load_issues = load_maps(
            folder / MAPS_SUBDIR, manifest.get("maps", {})
        )
        issues.extend(load_issues)

        declared = manifest.get("physical_size_m")
        tile_size = (
            (float(declared[0]), float(declared[1]))
            if isinstance(declared, list) and len(declared) == 2
            else None
        )
        issues.extend(inspect(samples, image_config, tile_size))

    return issues


def _report(folder: Path, issues: list[Issue]) -> tuple[int, int]:
    errors = [issue for issue in issues if issue.severity == "error"]
    warnings = [issue for issue in issues if issue.severity == "warning"]

    if not issues:
        print(f"OK      {folder.name}")
        return 0, 0

    print(f"{'FAIL' if errors else 'WARN'}    {folder.name}")
    for issue in errors + warnings:
        print(f"          [{issue.severity}] {issue.code}: {issue.message}")

    return len(errors), len(warnings)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Dying Star PBR materials.")
    parser.add_argument(
        "folder",
        nargs="?",
        type=Path,
        help="a single material folder; defaults to every material",
    )
    arguments = parser.parse_args()

    try:
        validator = Draft202012Validator(_load_json(SCHEMA_PATH))
        vocabulary = _load_json(TAGS_PATH)
        known_tags = _flatten_tags(vocabulary)
        families = _family_tags(vocabulary)
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"Cannot load the schema or the tag vocabulary: {error}", file=sys.stderr)
        return 2

    if arguments.folder:
        folders = [arguments.folder]
    else:
        folders = sorted(
            path.parent for path in MATERIALS_DIR.glob(f"*/{MANIFEST_NAME}")
        )

    if not folders:
        print("No material found.", file=sys.stderr)
        return 2

    image_config = RulesConfig()
    total_errors = 0
    total_warnings = 0

    for folder in folders:
        errors, warnings = _report(folder, validate_material(
            folder, validator, known_tags, families, image_config
        ))
        total_errors += errors
        total_warnings += warnings

    print(
        f"\n{len(folders)} material(s), "
        f"{total_errors} error(s), {total_warnings} warning(s)"
    )
    return 1 if total_errors else 0


if __name__ == "__main__":
    sys.exit(main())
