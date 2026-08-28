"""Pillow adapter: turn files on disk into MapSample objects.

Single responsibility: read images. Judges nothing — the rules live in
map_rules.py and are shared with the Blender addon.

Used on the command line and in CI, where Pillow is available. Blender uses
bpy_loader.py instead, and both produce the same MapSample shape.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

from map_rules import Issue, MapSample

# Pillow mode -> (channel count, bits per channel).
_MODE_INFO = {
    "L": (1, 8),
    "I;16": (1, 16),
    "I": (1, 32),
    "RGB": (3, 8),
    "RGBA": (4, 8),
    "P": (3, 8),
}


def _describe(image: Image.Image) -> tuple[int, int]:
    """Channel count and bit depth, falling back to a safe guess."""
    return _MODE_INFO.get(image.mode, (len(image.getbands()), 8))


def _as_array(image: Image.Image, channel_count: int) -> np.ndarray:
    """Normalise to a (height, width, channels) array."""
    array = np.array(image)
    if array.ndim == 2:
        array = array[:, :, np.newaxis]
    return array[..., :channel_count] if array.shape[2] >= channel_count else array


def load_maps(
    folder: Path,
    maps: dict[str, str],
    with_pixels: bool = True,
) -> tuple[list[MapSample], list[Issue]]:
    """Open every declared map.

    Args:
        folder: directory holding the files.
        maps: PBR role -> file name.
        with_pixels: read pixel data. Set False for a metadata-only pass.

    Returns:
        The samples that could be read, and an issue per file that could not.
    """
    samples: list[MapSample] = []
    issues: list[Issue] = []

    for name, file_name in maps.items():
        path = folder / file_name

        if not path.is_file():
            issues.append(
                Issue("error", "map_missing", f"{name}: file not found ({file_name})")
            )
            continue

        try:
            with Image.open(path) as image:
                image.load()
                channel_count, bits = _describe(image)
                pixels = _as_array(image, channel_count) if with_pixels else None
                samples.append(
                    MapSample(
                        name=name,
                        width=image.width,
                        height=image.height,
                        channel_count=channel_count,
                        bits_per_channel=bits,
                        pixels=pixels,
                    )
                )
        except OSError as error:
            issues.append(
                Issue("error", "map_unreadable", f"{name}: cannot be read ({error})")
            )

    return samples, issues
