"""
Procedural mountains — where and how, never the relief itself.
================================================================

Drawing 50 m contours by hand for every massif is too slow, and heights.pack
cannot carry cliffs anyway.  These two layers only describe the INTENT; Godot
generates the relief at runtime as a deterministic function of the position
(scenes/planet/mountain_relief.gd), identically on the client, the server, the
collision and the road / rail profiles, down to the finest vertex pitch.
export_mountains.py turns them into parts/mountains.dsmpart and ridges.dsmpart.

``mountain_range`` (Region)
    A polygon with a noise style.  The relief is feathered to zero over
    ``feather_m`` INSIDE the edge, so draw the outline where the massif should
    END, not where the peaks are.  Overlapping ranges add up.  Pick a ``style``
    preset and leave the other fields NULL, or set them to override it:

        rolling   soft hills, no crest                (fbm, exponent 1)
        hills     rounder, taller                     (fbm, exponent 1.5)
        alpine    sharp crests, deep valleys          (ridged, exponent 1.5)
        mesa      flat tops, banded cliffs            (terraces 150 m)
        cliffs    near-vertical walls, giant steps    (terraces 250 m, ridged)

``ridge`` (Lines)
    A crest line: full ``height_m`` on the line, down to zero ``width_m`` away
    on each flank, tapered to nothing at both ends.  ``sharpness`` goes from a
    rounded bell (0) to a knife edge (1); ``asymmetry`` makes one flank longer
    — the LEFT of the drawing direction is the gentle side when it is
    positive (same convention as the cliff layer: high side on the left).
    Overlaps a range or another ridge additively.

The preset values live in export/planet/mountains.py (PRESETS): the exporter
fills the NULL fields from them, so Godot never needs the table.
"""

from .model import Category, Layer, Field, Widget, ValueMap, Range

CATEGORY = Category("mountains", "mountains",
                    description="Procedural mountains (ranges and ridges)")

STYLES = [
    ("Rolling — soft hills, no crest", "rolling"),
    ("Hills — rounder, taller", "hills"),
    ("Alpine — sharp crests, deep valleys", "alpine"),
    ("Mesa — flat tops, banded cliffs", "mesa"),
    ("Cliffs — near-vertical walls, giant steps", "cliffs"),
    ("Custom — every field set by hand", "custom"),
]

RIDGE_STYLES = [
    ("Soft — rounded crest", "soft"),
    ("Sharp — knife edge", "sharp"),
    ("Escarpment — one steep face, one long slope", "escarpment"),
    ("Stepped — terraced flanks", "stepped"),
    ("Custom — every field set by hand", "custom"),
]


def _opt(minimum, maximum, step):
    """A Range that accepts NULL (= take the preset value)."""
    return Widget("Range", {"Min": minimum, "Max": maximum, "Step": step, "AllowNull": True})


CATEGORY.add(Layer(
    "mountain_range", "Polygon",
    color="#8b6b4a",
    description="Massif footprint with a procedural relief style (see layers/mountains.py)",
    terrain_modifier=True,
    properties={"ds_kind": "mountain_range"},
    symbol={"style": "b_diagonal", "outline_width": "0.6", "outline_color": "#5a4630"},
    fields=[
        Field("name", "string", "(Optional) Massif name"),
        Field("style", "string", "Relief preset — NULL fields below take its values",
              widget=ValueMap(STYLES), default="'alpine'"),
        Field("lift_m", "double", "Plateau lift under the whole massif (m)",
              widget=_opt(0, 5000, 10)),
        Field("amplitude_m", "double", "Peak amplitude of the noise above the lift (m)",
              widget=_opt(10, 8000, 10)),
        Field("wavelength_m", "double", "Size of the largest forms (m)",
              widget=_opt(500, 100000, 100)),
        Field("octaves", "integer", "Number of detail layers stacked on wavelength_m: 1 = the large forms only, "
              "each extra layer is half the size of the previous one (12 = down to wavelength/2048; layers the grid "
              "cannot hold are dropped)",
              widget=_opt(1, 12, 1)),
        Field("persistence", "double", "Amplitude ratio between detail levels, 0.2–0.8",
              widget=_opt(0.2, 0.8, 0.05)),
        Field("ridge", "double", "0 = rolling, 1 = sharp crests",
              widget=_opt(0.0, 1.0, 0.05)),
        Field("exponent", "double", "Peak sharpening: 1 = linear, 2–3 = flat lowlands + spikes",
              widget=_opt(0.5, 3.0, 0.5)),
        Field("terrace_step_m", "double", "Terrace height (m), 0 = none",
              widget=_opt(0, 1000, 10)),
        Field("terrace_width", "double", "Share of each step taken by the wall, 0.02–1",
              widget=_opt(0.02, 1.0, 0.02)),
        Field("warp", "double", "Domain warp in wavelengths, 0 = none, 0.3 = organic",
              widget=_opt(0.0, 1.0, 0.05)),
        Field("feather_m", "double", "Fade to the plain, inside the outline (m, min 250)",
              widget=_opt(250, 20000, 50)),
        Field("seed", "integer", "Noise seed — change it to reshuffle the peaks",
              widget=_opt(0, 1000000, 1)),
    ],
))

CATEGORY.add(Layer(
    "ridge", "LineString",
    color="#6b4a2b",
    description="Crest line — high on the line, down to zero one width away on each flank",
    terrain_modifier=True,
    direction_marker=True,
    properties={"ds_kind": "ridge"},
    symbol={"width": "1.4"},
    fields=[
        Field("name", "string", "(Optional) Ridge name"),
        Field("style", "string", "Crest preset — NULL fields below take its values",
              widget=ValueMap(RIDGE_STYLES), default="'sharp'"),
        Field("height_m", "double", "Crest height above the ground (m)",
              widget=_opt(10, 5000, 10)),
        Field("width_m", "double", "Crest-to-foot distance of a flank (m)",
              widget=_opt(50, 20000, 50)),
        Field("sharpness", "double", "0 = rounded bell, 1 = knife edge",
              widget=_opt(0.0, 1.0, 0.05)),
        Field("roughness", "double", "Height variation along the crest, 0–0.9",
              widget=_opt(0.0, 0.9, 0.05)),
        Field("warp_m", "double", "Crest wander (m), 0 = straight",
              widget=_opt(0, 2000, 10)),
        Field("asymmetry", "double", "-0.9…0.9: positive = long LEFT flank, steep right",
              widget=_opt(-0.9, 0.9, 0.1)),
        Field("terrace_step_m", "double", "Terrace height (m), 0 = none",
              widget=_opt(0, 1000, 10)),
        Field("terrace_width", "double", "Share of each step taken by the wall, 0.02–1",
              widget=_opt(0.02, 1.0, 0.02)),
        Field("seed", "integer", "Noise seed", widget=_opt(0, 1000000, 1)),
    ],
))
