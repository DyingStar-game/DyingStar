"""Blender adapter: turn bpy images into MapSample objects.

Single responsibility: read images through Blender's API. Judges nothing — the
rules live in tools/map_rules.py and are shared with the command-line
validator.

Two modes matter here. The panel redraws constantly, so it asks for metadata
only; reading the pixel buffer of a 4K map on every redraw would freeze the
interface. The export operator asks for pixels, once.
"""

from __future__ import annotations

import numpy as np

from . import shared_rules

# Blender reports bits per pixel across all channels, from which both the
# channel count and the per-channel depth follow.
_DEPTH_INFO = {
    8: (1, 8),
    16: (1, 16),
    24: (3, 8),
    32: (4, 8),
    48: (3, 16),
    64: (4, 16),
    96: (3, 32),
    128: (4, 32),
}


def _describe(image) -> tuple[int, int]:
    """Channel count and bit depth, falling back to RGBA 8-bit."""
    return _DEPTH_INFO.get(image.depth, (4, 8))


def _read_pixels(image, channel_count: int) -> np.ndarray | None:
    """Copy the pixel buffer into a (height, width, channels) array.

    Blender always exposes four float channels regardless of what the file
    holds, so the array is trimmed to the real channel count. Values are
    whatever Blender's buffer contains; the rules only compare them to each
    other, so no conversion is needed.
    """
    width, height = image.size
    if width == 0 or height == 0:
        return None

    try:
        buffer = np.empty(width * height * 4, dtype=np.float32)
        image.pixels.foreach_get(buffer)
    except (RuntimeError, ValueError, AttributeError):
        return None

    # Blender stores rows bottom-up; the rules compare a vertical gradient, so
    # the orientation must match what the file-based loader produces.
    array = buffer.reshape((height, width, 4))[::-1]
    return array[..., :channel_count]


def build_samples(
    images: dict,
    with_pixels: bool = False,
) -> tuple[list, list]:
    """Describe a set of bpy images for the shared rules.

    Args:
        images: PBR role -> bpy Image, as produced by map_extractor.
        with_pixels: read the pixel buffers. Slow; leave False for UI redraws.

    Returns:
        The samples, and an issue per image that could not be described.

    Raises:
        shared_rules.RulesUnavailable: when the rules module is unreachable.
    """
    rules = shared_rules.load()

    samples = []
    issues = []

    for name, image in images.items():
        if image is None:
            issues.append(
                rules.Issue("error", "map_missing", f"{name}: no image assigned")
            )
            continue

        width, height = image.size
        if width == 0 or height == 0:
            issues.append(
                rules.Issue("error", "map_unreadable", f"{name}: image has no data")
            )
            continue

        channel_count, bits = _describe(image)
        samples.append(
            rules.MapSample(
                name=name,
                width=width,
                height=height,
                channel_count=channel_count,
                bits_per_channel=bits,
                pixels=_read_pixels(image, channel_count) if with_pixels else None,
            )
        )

    return samples, issues
