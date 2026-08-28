"""Writing the review preview image.

Single responsibility: produce the preview.jpg that sits next to the manifest.
Knows nothing about manifests, validation or the panel.

The preview exists for pull request review: GitHub renders it inline, so a
maintainer can judge a material without cloning the repository. That is why it
is a small JPEG committed in clear, and not derived at build time.
"""

from __future__ import annotations

from pathlib import Path

import bpy

PREVIEW_NAME = "preview.jpg"

# Blender's own preview system renders at this size. Small, but it is the exact
# image the Asset Browser shows, so the artist recognises what they published.
_BLENDER_PREVIEW_MAX = 256

# The fallback crops the albedo instead. Larger, since no rendering is involved.
_FALLBACK_SIZE = 512

_JPEG_QUALITY = 90


class PreviewError(RuntimeError):
    """Raised when no preview could be produced by any means."""


def _save_pixels(name: str, width: int, height: int, pixels, target: Path) -> None:
    """Write a float RGBA buffer to disk as a JPEG."""
    image = bpy.data.images.new(name, width, height, alpha=True)
    try:
        image.pixels.foreach_set(pixels)
        image.file_format = "JPEG"
        image.filepath_raw = str(target)
        image.save(quality=_JPEG_QUALITY)
    finally:
        bpy.data.images.remove(image)


def _regenerate(material: bpy.types.Material) -> None:
    """Ask Blender to re-render the datablock's stored preview.

    preview_ensure() hands back whatever thumbnail the material already
    carries, and editing a node tree does not invalidate it. Left alone, an
    export republishes the preview of an earlier state of the material, which
    is worse than having none: it looks right, so nobody checks it.

    Blender renders previews as a background job, so a freshly requested one
    may not be ready by the time it is read. That case comes back transparent
    and falls through to the albedo, which is approximate but at least
    describes the material as it is being published.
    """
    try:
        with bpy.context.temp_override(id=material):
            bpy.ops.ed.lib_id_generate_preview()
    except (AttributeError, RuntimeError, TypeError):
        # Older Blender, or no context to override from. The stored preview is
        # then the only thing available.
        pass


def _from_blender_preview(material: bpy.types.Material, target: Path) -> bool:
    """Use the material preview Blender renders for the Asset Browser."""
    _regenerate(material)

    preview = material.preview_ensure()
    if preview is None:
        return False

    width, height = preview.image_size
    if width == 0 or height == 0:
        return False

    pixels = [0.0] * (width * height * 4)
    preview.image_pixels_float.foreach_get(pixels)

    # A preview that has not finished rendering comes back fully transparent.
    if not any(pixels[3::4]):
        return False

    _save_pixels("ds_preview_tmp", width, height, pixels, target)
    return True


def _from_albedo(albedo: bpy.types.Image, target: Path) -> bool:
    """Fall back to a downscaled albedo when no rendered preview is available.

    Less informative than a shaded sphere — it shows none of the roughness or
    metallic response — but a material with no preview at all would fail
    validation, and an approximate image is better than a blocked export.
    """
    if albedo is None or albedo.size[0] == 0:
        return False

    copy = albedo.copy()
    try:
        copy.scale(_FALLBACK_SIZE, _FALLBACK_SIZE)
        copy.file_format = "JPEG"
        copy.filepath_raw = str(target)
        copy.save(quality=_JPEG_QUALITY)
    except (RuntimeError, OSError):
        return False
    finally:
        bpy.data.images.remove(copy)

    return True


def write(
    material: bpy.types.Material,
    images: dict,
    folder: Path,
) -> tuple[Path, bool]:
    """Write preview.jpg into a material folder.

    Args:
        material: the material to preview.
        images: map role -> bpy Image, used for the fallback.
        folder: destination material folder.

    Returns:
        The written path, and whether it came from Blender's rendered preview
        rather than the albedo fallback.

    Raises:
        PreviewError: when neither route produced an image.
    """
    target = folder / PREVIEW_NAME

    if _from_blender_preview(material, target):
        return target, True

    if _from_albedo(images.get("albedo"), target):
        return target, False

    raise PreviewError(
        "No preview could be generated. Display the material in the viewport "
        "once, then export again."
    )
