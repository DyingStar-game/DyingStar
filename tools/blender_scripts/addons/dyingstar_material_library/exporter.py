"""Writing a material into the library layout.

Single responsibility: take an extraction result plus the artist's metadata,
and produce the folder the library expects — renamed maps and a manifest.
Knows nothing about panels, operators or node trees.

Nothing here mutates the artist's own file: images are copied out, never moved
or renamed in place.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import bpy

from . import preferences

MANIFEST_NAME = "material.json"
MATERIAL_PREFIX = "mat_"
TEXTURE_PREFIX = "tex_"

# Order the manifest keys so generated files read the same as hand-written ones.
_MAP_ORDER = (
    "albedo",
    "normal",
    "orm",
    "ao",
    "roughness",
    "metallic",
    "height",
    "emissive",
    "opacity",
)

_SLUG_INVALID = re.compile(r"[^a-z0-9]+")


class ExportError(RuntimeError):
    """Raised when the material cannot be written to the library."""


def slugify(name: str) -> str:
    """Turn a Blender material name into a valid library id.

    The id is the pipeline's join key: it is the material name inside the
    generated library .blend, the folder name, and what the Godot resolver
    looks for. It therefore derives from the material's own name, never from
    the free-text display name.
    """
    slug = _SLUG_INVALID.sub("_", name.strip().lower()).strip("_")
    if not slug:
        raise ExportError("Material name produces an empty identifier")
    if not slug.startswith(MATERIAL_PREFIX):
        slug = MATERIAL_PREFIX + slug
    return slug


def descriptor_from_id(material_id: str) -> str:
    """Strip the mat_ prefix to build texture file names."""
    return material_id[len(MATERIAL_PREFIX):]


@dataclass
class ExportResult:
    """What an export actually published.

    An export can legitimately write no texture at all: a material appended
    from the library points its image nodes at the library files themselves,
    so correcting only its metadata copies nothing. Without these counts that
    case is indistinguishable, on screen, from an export that published every
    map, which is how an edit made to a file the material does not read goes
    unnoticed.
    """

    folder: Path
    version: int
    published: list[str] = field(default_factory=list)
    already_in_place: list[str] = field(default_factory=list)

    def summary(self) -> str:
        return (
            f"{self.folder.name} v{self.version}: "
            f"{len(self.published)} map(s) published, "
            f"{len(self.already_in_place)} already in the library"
        )


def _copy_image(image: bpy.types.Image, target: Path) -> bool:
    """Write an image to the library as a real PNG.

    Source files that are already PNG are copied byte for byte. Anything else
    (JPEG from a texture library, TIFF from a scan) is re-encoded, because the
    schema and the Godot import pipeline both expect PNG. Re-encoding does not
    recover quality already lost to JPEG, it only stops further loss.

    Returns whether anything was written, so the caller can tell an export that
    published from one that had nothing to publish.
    """
    source = Path(bpy.path.abspath(image.filepath)) if image.filepath else None

    if source is not None and source.is_file() and source.suffix.lower() == ".png":
        # Re-exporting a material appended from the library points the image at
        # the very file about to be written: material_builder loads its maps
        # straight from the material folder. Nothing to copy, and copy2 would
        # raise SameFileError, which callers do not expect.
        if source.resolve() == target.resolve():
            return False
        shutil.copy2(source, target)
        return True

    # Blender writes using the datablock's file_format, so it has to be set.
    # Restore it afterwards: the artist's own image must come out unchanged.
    original_format = image.file_format
    try:
        image.file_format = "PNG"
        image.save(filepath=str(target))
    except (RuntimeError, OSError) as error:
        raise ExportError(f"Cannot write '{image.name}': {error}") from error
    finally:
        image.file_format = original_format

    return True


def _digest_maps(folder: Path, map_files: dict[str, str]) -> dict[str, str]:
    """Content hash of the maps currently on disk, keyed by role.

    Roles missing from the folder are simply absent, so a map that appears or
    disappears shows up as a difference just like a map whose pixels changed.
    """
    digests: dict[str, str] = {}
    for role, file_name in map_files.items():
        path = folder / file_name
        if path.is_file():
            digests[role] = hashlib.sha256(path.read_bytes()).hexdigest()
    return digests


def _next_version(previous: dict, before: dict, after: dict) -> int:
    """The version a re-export should publish under.

    Download URLs are derived from the id, the version and the resolution, so
    the version has to move whenever the binaries do — otherwise a URL that was
    already handed out starts serving different pixels. A re-export that only
    corrects metadata keeps its version: nothing downstream needs to refetch.
    """
    current = previous.get("delivery", {}).get("version")
    if not isinstance(current, int) or current < 1:
        return 1
    return current if before == after else current + 1


def _build_manifest(
    material_id: str,
    metadata: dict,
    map_files: dict[str, str],
) -> dict:
    """Assemble the manifest in the canonical key order."""
    manifest = {
        "id": material_id,
        "display_name": metadata["display_name"],
        "tags": metadata["tags"],
        "physical_size_m": list(metadata["physical_size_m"]),
        "license": metadata["license"],
        "author": metadata["author"],
        "ai_generated": False,
    }

    notes = metadata.get("notes", "").strip()
    if notes:
        manifest["notes"] = notes

    manifest["delivery"] = {"type": "hosted", "version": metadata.get("version", 1)}
    manifest["maps"] = {
        name: map_files[name] for name in _MAP_ORDER if name in map_files
    }

    return manifest


def export(
    material_name: str,
    images: dict[str, bpy.types.Image],
    metadata: dict,
    materials_dir: Path | None = None,
) -> Path:
    """Write a material folder into the library.

    Args:
        material_name: the material's name in Blender. This is what travels in
            the glTF and what Godot matches against, so it — not the display
            name — determines the library id.
        images: map role -> image datablock, as produced by map_extractor.
        metadata: display_name, tags, physical_size_m, license, author, notes.
        materials_dir: injectable target, defaults to the project layout.

    Returns:
        An ExportResult: the folder that was written, the version it was
        published under, and which maps were actually copied.

    Raises:
        ExportError: on an invalid name, a missing map or an unwritable file.
    """
    if "albedo" not in images or "normal" not in images:
        raise ExportError("A library material needs at least an albedo and a normal map")

    target_root = materials_dir or preferences.materials_dir()
    if target_root is None:
        raise ExportError(
            "Repository root not set (Preferences > Add-ons > Dying Star)"
        )

    material_id = slugify(material_name)
    descriptor = descriptor_from_id(material_id)

    folder = target_root / material_id
    folder.mkdir(parents=True, exist_ok=True)

    # Hash what is already published before overwriting it, so the version can
    # be moved only when the binaries actually change.
    previous = load_manifest(material_id) if find_manifest(material_id) else {}
    before = _digest_maps(folder, previous.get("maps", {}))

    map_files: dict[str, str] = {}
    published: list[str] = []
    already_in_place: list[str] = []
    for role, image in images.items():
        if image is None:
            continue
        file_name = f"{TEXTURE_PREFIX}{descriptor}_{role}.png"
        if _copy_image(image, folder / file_name):
            published.append(role)
        else:
            already_in_place.append(role)
        map_files[role] = file_name

    after = _digest_maps(folder, map_files)
    version = _next_version(previous, before, after)

    manifest = _build_manifest(material_id, dict(metadata, version=version), map_files)
    manifest_path = folder / MANIFEST_NAME
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    return ExportResult(
        folder=folder,
        version=version,
        published=published,
        already_in_place=already_in_place,
    )


def find_manifest(material_id: str) -> Path | None:
    """Locate an already-published material's manifest, if there is one."""
    root = preferences.materials_dir()
    if root is None:
        return None

    manifest = root / material_id / MANIFEST_NAME
    return manifest if manifest.is_file() else None


def load_manifest(material_id: str) -> dict:
    """Read back a published manifest so the panel can be pre-filled.

    Raises:
        ExportError: when the manifest is absent or unreadable.
    """
    manifest_path = find_manifest(material_id)
    if manifest_path is None:
        raise ExportError(f"'{material_id}' is not in the library yet")

    try:
        with manifest_path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ExportError(f"Cannot read {manifest_path}: {error}") from error
