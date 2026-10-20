"""Packing an opacity map into the albedo's alpha channel.

Single responsibility: build the RGBA albedo the library publishes for a
material with transparency. Knows nothing about panels, manifests or the
library layout, and is handed the path it should write to.

Godot's StandardMaterial3D has no opacity slot: it reads transparency from the
alpha of its albedo texture only. An artist's material often carries its cut-out
in a separate opacity map (a decal sheet), so the export folds that map into the
albedo -- one texture instead of two, like orm_packer folds three into one --
and the manifest's alpha block says how to read it.

bpy is imported only by the functions that touch Blender data, so the packing
arithmetic can be unit-tested outside Blender (test/unit/test_alpha_packer_py.py).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np


class PackError(RuntimeError):
    """Raised when the maps cannot be packed as they stand."""


def opacity_channel(pixels: np.ndarray) -> np.ndarray:
    """One opacity value per pixel of an (n, 4) RGBA buffer.

    An opacity map is grayscale by convention, so its red channel is the mask.
    But a mask painted in alpha exports as an RGBA file with plain RGB (the
    decals of PR #409), and then the alpha is the mask: an alpha channel that is
    not fully opaque wins.
    """
    alpha = pixels[:, 3]
    if alpha.size and float(alpha.min()) < 1.0:
        return alpha.copy()
    return pixels[:, 0].copy()


def alpha_pack(rgb: np.ndarray | None, opacity: np.ndarray) -> np.ndarray:
    """An (n, 4) RGBA buffer: the colour of rgb, the opacity as alpha.

    Without rgb (a plain-coloured surface) the colour is white: albedo_color,
    which stays in the manifest, tints it in Godot as it tinted nothing before.
    """
    count = opacity.shape[0]
    packed = np.ones((count, 4), dtype=np.float32)
    if rgb is not None:
        if rgb.shape[0] != count:
            raise PackError("The albedo and the opacity map must be the same size")
        packed[:, :3] = rgb[:, :3]
    packed[:, 3] = opacity
    return packed


def pack(albedo, opacity, name: str):
    """A new, unsaved RGBA image: the albedo's colour with the opacity as alpha.

    The caller writes it (save) and removes it from bpy.data once published:
    it is an export artefact, never part of the artist's file.
    """
    import bpy

    width, height = opacity.size
    if width == 0 or height == 0:
        raise PackError(f"'{opacity.name}' has no pixels: is its file missing?")
    if albedo is not None and tuple(albedo.size) != (width, height):
        raise PackError(
            f"The albedo ({albedo.size[0]}x{albedo.size[1]}) and the opacity map "
            f"({width}x{height}) must be the same size to be packed"
        )

    rgb = _read_pixels(albedo) if albedo is not None else None
    pixels = alpha_pack(rgb, opacity_channel(_read_pixels(opacity)))

    packed = bpy.data.images.new(name, width, height, alpha=True, float_buffer=False)
    packed.colorspace_settings.name = "sRGB"
    packed.pixels.foreach_set(pixels.ravel())
    return packed


def save(image, target: Path) -> None:
    """Write the packed image as an RGBA PNG."""
    image.filepath_raw = str(target)
    image.file_format = "PNG"
    try:
        image.save()
    except (RuntimeError, OSError) as error:
        raise PackError(f"Cannot write '{target.name}': {error}") from error


def _read_pixels(image) -> np.ndarray:
    """An image's stored values as an (n, 4) buffer.

    Read as Non-Color, as orm_packer does: the bytes are copied, not
    converted, so the published albedo keeps exactly the colours of its source.
    """
    original = image.colorspace_settings.name
    try:
        image.colorspace_settings.name = "Non-Color"
        buffer = np.empty(len(image.pixels), dtype=np.float32)
        image.pixels.foreach_get(buffer)
    finally:
        image.colorspace_settings.name = original
    return buffer.reshape(-1, 4)
