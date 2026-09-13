"""
Roads — one layer per road type: highway / road / path / trail / railway.
=========================================================================

The road type used to be a per-feature ``road_type`` field on a single
``roads`` table; it is now the layer itself, stored as the ``road_type``
custom property that export_roads.py reads.  Per-type defaults (width, lanes…)
are QGIS default values, so the artist can still override them per feature.

Widths MUST stay in sync with export/planet/roads.py HALF_WIDTH_M (and
RoadTerrain.HALF_WIDTH_M on the Godot side): ``width`` here is the TOTAL width.

A railway is different: it has no width / surface / sidewalk / lighting.  Its
only geometry parameter is ``tracks``; the ballast bed width is DERIVED from it
at export (export/planet/roads.py railway_half_width_m) and again in Godot
(RailwaySettings.railway_half_width_m).
"""

from .model import Category, Layer, Field, Widget, ValueMap, Range

CATEGORY = Category("roads", "roads", description="Roads and paths")

SURFACES = [
    ("Asphalt — paved, smooth", "asphalt"),
    ("Concrete — paved, rigid", "concrete"),
    ("Gravel — loose stones", "gravel"),
    ("Dirt — packed earth", "dirt"),
    ("Grass — grass/earth mix", "grass"),
    ("Sand — sandy track", "sand"),
    ("Stone — cobblestone or flagstone", "stone"),
]

# slug: (description, colour, symbol width, width_m, lanes, speed_limit, surface, sidewalk, lighting)
ROAD_TYPES = {
    "highway": ("Multi-lane, high-speed, asphalt",       "#505050", "3.0", 12.0, 4, 120, "asphalt", 0, 1),
    "road":    ("Standard two-lane, paved surface",       "#8c8278", "2.0",  6.0, 2,  60, "asphalt", 1, 1),
    "path":    ("Narrow pedestrian / vehicle track",      "#b4a078", "1.2",  2.0, 0,  20, "gravel",  0, 0),
    "trail":   ("Unpaved footpath, follows the terrain",  "#78643c", "0.8",  1.0, 0,   5, "dirt",    0, 0),
}

# Road types that may carry a grade limit.  Left NULL, the road hugs the
# terrain; set, Godot builds it on a profile limited to that slope with
# cuttings, tunnels and viaducts — the same machinery as the railway.
GRADED_TYPES = ("highway", "road")

MAX_SLOPE_FIELD = Field(
    "max_slope_degrees", "integer",
    "Max slope in degrees — empty: follows the terrain; set: grade-limited "
    "profile with cuttings, tunnels and viaducts",
    widget=Widget("Range", {"Min": 1, "Max": 45, "Step": 1, "AllowNull": True}),
)


def _road_fields(width, lanes, speed, surface, sidewalk, lighting, graded=False):
    return (
        Field("name", "string", "Road name"),
        Field("width", "double", "Total width in metres", default=str(width),
              widget=Range(0.5, 60.0, 0.5)),
        Field("lanes", "integer", "Number of lanes", default=str(lanes),
              widget=Range(0, 12, 1)),
        Field("surface", "string", "Surface type", default=f"'{surface}'",
              widget=ValueMap(SURFACES)),
        Field("speed_limit", "integer", "Speed limit in km/h", default=str(speed),
              widget=Range(0, 300, 5)),
        Field("has_sidewalk", "integer", "0 or 1", default=str(sidewalk),
              widget=Range(0, 1, 1)),
        Field("has_lighting", "integer", "0 or 1", default=str(lighting),
              widget=Range(0, 1, 1)),
        *((MAX_SLOPE_FIELD,) if graded else ()),
    )


for _slug, (_desc, _color, _sym_w, *_defaults) in ROAD_TYPES.items():
    CATEGORY.add(Layer(
        _slug, "LineString", _road_fields(*_defaults, graded=_slug in GRADED_TYPES),
        color=_color,
        description=_desc,
        properties={"road_type": _slug},
        direction_marker=True,
        symbol={"width": _sym_w, "capstyle": "round", "joinstyle": "round"},
    ))


CATEGORY.add(Layer(
    "railway", "LineString", (
        Field("name", "string", "Line name"),
        Field("tracks", "integer",
              "Number of tracks — the ballast bed width is derived from it "
              "(1 → 3.44 m, 2 → 6.88 m)",
              default="1", widget=Range(1, 8, 1)),
        Field("speed_limit", "integer", "Line speed in km/h", default="160",
              widget=Range(0, 400, 5)),
    ),
    color="#3c3c50",
    description="Railway — ballast bed with one or more tracks",
    properties={"road_type": "railway"},
    direction_marker=True,
    symbol={"width": "1.6", "capstyle": "round", "joinstyle": "round"},
    # The QGIS library's rail-and-sleepers line; the simple symbol is the fallback.
    style_symbol="topo railway",
))
