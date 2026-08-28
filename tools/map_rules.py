"""PBR map validation rules.

Single responsibility: judge maps. Says nothing about how they were read.

Depends only on numpy, which both CPython and Blender's embedded interpreter
provide. Pillow and bpy live in the adapters (pillow_loader.py on the command
line, bpy_loader.py inside the addon), so a rule is written once and enforced
identically wherever it runs.

Pixel values are only ever compared to each other, never to absolute
thresholds: a rule must give the same verdict whether the adapter hands over
0-255 integers or 0-1 floats.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

import numpy as np

# --- Configuration -----------------------------------------------------------

# BCn / S3TC texture compression works on 4x4 pixel blocks. A texture whose
# dimensions are not a multiple of 4 cannot be block-compressed on the GPU.
COMPRESSION_BLOCK_SIZE = 4

# Maps that carry a single scalar value. Storing them with three or four
# channels wastes bytes for no visual gain.
GRAYSCALE_MAPS = frozenset({"ao", "roughness", "metallic", "height", "opacity"})


@dataclass(frozen=True)
class RulesConfig:
    """Injectable thresholds, so the same rules can be tuned per pipeline."""

    # Pixels per real-world metre. Resolution alone says nothing about how
    # detailed a material looks: the same 1024 map is twice as fine on a one
    # metre tile as on a two metre one.
    target_texel_density: int = 1024
    # How far a material may sit from the target before it is worth reporting.
    texel_density_tolerance: float = 0.25
    # Height maps below this bit depth band visibly when used for displacement.
    recommended_height_bit_depth: int = 16
    # Below this absolute correlation, the normal/height comparison is
    # considered inconclusive rather than wrong.
    normal_correlation_threshold: float = 0.3


@dataclass(frozen=True)
class Issue:
    severity: str  # "error" or "warning"
    code: str
    message: str


@dataclass(frozen=True)
class MapSample:
    """One map, described in terms every adapter can produce.

    Attributes:
        name: the PBR role ("albedo", "roughness", ...), not the file name.
        width, height: in pixels.
        channel_count: 1, 3 or 4 as stored in the source.
        bits_per_channel: 8 or 16.
        pixels: (height, width, channel_count) array, or None when the adapter
            was asked for metadata only. Rules that need pixels are skipped
            rather than failing.
    """

    name: str
    width: int
    height: int
    channel_count: int
    bits_per_channel: int
    pixels: np.ndarray | None = None

    @property
    def size(self) -> tuple[int, int]:
        return self.width, self.height

    @property
    def is_grayscale(self) -> bool:
        return self.channel_count == 1

    def alpha(self) -> np.ndarray | None:
        if self.pixels is None or self.channel_count < 4:
            return None
        return self.pixels[..., 3]

    def color_channels(self) -> np.ndarray | None:
        if self.pixels is None:
            return None
        return self.pixels[..., : min(3, self.channel_count)]


# --- Individual rules --------------------------------------------------------


def _dominant_size(samples: Sequence[MapSample]) -> tuple[int, int]:
    """The size shared by most maps, which stands for the material's own."""
    sizes: dict[tuple[int, int], list[str]] = {}
    for sample in samples:
        sizes.setdefault(sample.size, []).append(sample.name)
    return max(sizes, key=lambda size: len(sizes[size]))


def _check_dimensions(samples: Sequence[MapSample], config: RulesConfig) -> list[Issue]:
    """Consistent across maps, then GPU-compressible.

    Resolution is a property of the material, not of each map, so it is
    reported once. Only a genuine mismatch names the maps involved.

    Squareness is deliberately not required. Bark stretched vertically is a
    sound authoring choice, the manifest already accepts a non-square tile
    through physical_size_m, and the texel density rule judges each axis on its
    own, so a shape that really is wrong is reported there.
    """
    if not samples:
        return []

    issues: list[Issue] = []
    sizes: dict[tuple[int, int], list[str]] = {}
    for sample in samples:
        sizes.setdefault(sample.size, []).append(sample.name)

    if len(sizes) > 1:
        detail = "; ".join(
            f"{width}x{height}: {', '.join(sorted(names))}"
            for (width, height), names in sorted(sizes.items())
        )
        issues.append(
            Issue("error", "size_mismatch", f"maps have different sizes ({detail})")
        )

    # Judge the dominant size: the mismatch above already names the outliers.
    width, height = _dominant_size(samples)

    if width % COMPRESSION_BLOCK_SIZE or height % COMPRESSION_BLOCK_SIZE:
        issues.append(
            Issue(
                "error",
                "not_block_aligned",
                f"{width}x{height} is not a multiple of {COMPRESSION_BLOCK_SIZE}, "
                f"so it cannot be GPU-compressed. Re-export at 1024 or 2048.",
            )
        )

    return issues


def _check_color_modes(samples: Sequence[MapSample], _: RulesConfig) -> list[Issue]:
    """Grayscale maps must be stored as grayscale; nobody needs a dead alpha.

    Both problems come from the same export setting, so the maps affected are
    listed together rather than reported one by one.
    """
    stored_as_color: list[str] = []
    dead_alpha: list[str] = []

    for sample in samples:
        if sample.name in GRAYSCALE_MAPS and not sample.is_grayscale:
            stored_as_color.append(sample.name)

        alpha = sample.alpha()
        if alpha is not None and alpha.min() == alpha.max():
            dead_alpha.append(sample.name)

    issues: list[Issue] = []

    if stored_as_color:
        issues.append(
            Issue(
                "warning",
                "grayscale_stored_as_color",
                f"{', '.join(sorted(stored_as_color))}: single-channel data stored "
                f"in colour mode. Convert to grayscale to divide their weight by 3 or 4.",
            )
        )

    if dead_alpha:
        issues.append(
            Issue(
                "warning",
                "useless_alpha",
                f"{', '.join(sorted(dead_alpha))}: constant alpha channel, drop it",
            )
        )

    return issues


def _check_constant_maps(samples: Sequence[MapSample], _: RulesConfig) -> list[Issue]:
    """A map with a single value everywhere carries no information."""
    issues: list[Issue] = []

    for sample in samples:
        channels = sample.color_channels()
        if channels is None:
            continue
        if channels.min() == channels.max():
            issues.append(
                Issue(
                    "warning",
                    "constant_map",
                    f"{sample.name}: uniform value, remove it from the material",
                )
            )

    return issues


def _check_height_precision(
    samples: Sequence[MapSample], config: RulesConfig
) -> list[Issue]:
    """8-bit height maps band when used for real displacement."""
    height = _by_name(samples, "height")
    if height is None or height.bits_per_channel >= config.recommended_height_bit_depth:
        return []

    return [
        Issue(
            "warning",
            "height_low_precision",
            f"height: {height.bits_per_channel}-bit. "
            f"{config.recommended_height_bit_depth}-bit is recommended for displacement.",
        )
    ]


def _check_normal_handedness(
    samples: Sequence[MapSample], config: RulesConfig
) -> list[Issue]:
    """Detect DirectX (-Y) normal maps by comparing them to the height map.

    The green channel encodes the surface slope along the vertical axis. In the
    OpenGL convention used by Blender and Godot, it correlates positively with
    the height gradient taken along increasing row index. A DirectX map, being
    vertically flipped, correlates negatively.

    Only the sign of the correlation is used, so the adapter's value range and
    any monotonic transform applied to it are irrelevant.
    """
    normal = _by_name(samples, "normal")
    height = _by_name(samples, "height")

    if normal is None or height is None:
        return []
    if normal.pixels is None or height.pixels is None:
        return []
    if normal.size != height.size:
        return []  # already reported by _check_dimensions
    if normal.channel_count < 3:
        return [
            Issue(
                "error",
                "normal_not_rgb",
                f"normal: stored with {normal.channel_count} channel(s). "
                f"A tangent-space normal map needs three.",
            )
        ]

    green = normal.pixels[..., 1].astype(np.float32)
    heights = height.pixels[..., 0].astype(np.float32)
    gradient = np.gradient(heights, axis=0)

    if green.std() == 0 or gradient.std() == 0:
        return []

    correlation = float(np.corrcoef(green.ravel(), gradient.ravel())[0, 1])

    if correlation <= -config.normal_correlation_threshold:
        return [
            Issue(
                "error",
                "normal_directx",
                f"normal: DirectX convention detected (correlation {correlation:+.2f}). "
                f"Invert the green channel to get OpenGL (+Y).",
            )
        ]

    if correlation < config.normal_correlation_threshold:
        return [
            Issue(
                "warning",
                "normal_inconclusive",
                f"normal: cannot confirm the convention (correlation {correlation:+.2f}), "
                f"check it by hand.",
            )
        ]

    return []


def _by_name(samples: Sequence[MapSample], name: str) -> MapSample | None:
    for sample in samples:
        if sample.name == name:
            return sample
    return None


# --- Entry point -------------------------------------------------------------

def _check_texel_density(
    samples: Sequence[MapSample],
    config: RulesConfig,
    physical_size_m: tuple[float, float] | None,
) -> list[Issue]:
    """Detail per real-world metre, so materials match when laid side by side.

    This replaces the old resolution floor, which judged the wrong thing: a
    1024 map covering one metre and the same map covering two both cleared it,
    while being twice as fine as each other. The ratio is what the eye sees.

    It stands outside the uniform rule list because it needs the tile size,
    which lives in the manifest rather than in the pixels.
    """
    if not samples or physical_size_m is None:
        return []

    tile_width, tile_height = physical_size_m
    if tile_width <= 0 or tile_height <= 0:
        return []

    width, height = _dominant_size(samples)
    target = config.target_texel_density
    issues: list[Issue] = []

    for axis, pixels, metres in (("width", width, tile_width), ("height", height, tile_height)):
        density = pixels / metres
        if abs(density - target) <= target * config.texel_density_tolerance:
            continue
        issues.append(
            Issue(
                "warning",
                "texel_density_off_target",
                f"{axis}: {density:.0f} px/m against a {target} px/m target. "
                f"A {metres:g} m tile wants {round(target * metres)} px.",
            )
        )

    return issues


_RULES = (
    _check_dimensions,
    _check_color_modes,
    _check_constant_maps,
    _check_height_precision,
    _check_normal_handedness,
)


def inspect(
    samples: Sequence[MapSample],
    config: RulesConfig | None = None,
    physical_size_m: tuple[float, float] | None = None,
) -> list[Issue]:
    """Run every rule against a set of maps.

    Rules needing pixel data are skipped silently when the adapter provided
    metadata only, so a caller can trade completeness for speed. The texel
    density rule is skipped the same way when no tile size is supplied.
    """
    config = config or RulesConfig()
    issues: list[Issue] = []
    for rule in _RULES:
        issues.extend(rule(samples, config))
    issues.extend(_check_texel_density(samples, config, physical_size_m))
    return issues
