"""
Rocky terrain — rock blocks, ledges, buttes and strata laid over the ground.
=============================================================================

A ``rocky_terrain`` polygon makes the ground inside it rocky WITHOUT replacing
what is below: draw it over a plain, a plateau or a mountain_range and its
relief is ADDED to theirs (a biome region, by contrast, replaces the region
under it). Godot generates the relief at runtime
(scenes/planet/rock_field_relief.gd), identically on the client, the server,
the collision and the road / rail profiles. export_rocky_terrain.py turns the
layer into parts/rocky_terrain.dsmpart.

One formula makes the ground AND the cliffs: every Voronoi cell is a rock
block that terraces the ground with a phase of its own —

    on the flat      → slabs at staggered heights, separated by joints;
    on a slope       → the terrace cuts it into ledges: a cliff of blocks;
    with a dip       → the ledges tilt: inclined strata;
    with buttes      → rare raised cells, stretched along the wind: yardangs.

So draw ONE polygon over a whole escarpment: its steep face becomes a block
cliff, its top and foot become slabs.

Detail below the 25 m mesh pitch (blocks of 1-20 m, gravel) is drawn by the
terrain shader and by client-side scree, from the same record.

``ruggedness``
    flat · low · medium · rugged · very_rugged — the preset (block size, ledge
    height, joint depth, butte rate and height). NULL fields below take its
    values; set one to override it.

``style``
    slabs (default) · columnar (narrow walls, smaller blocks — for cliffs) ·
    yardang (elongated buttes along the wind) · strata (inclined ledges, dip
    8-20° unless dip_deg is set) · chalk (Seven Sisters: no ledges, soft knobs,
    a lumpy surface with wandering cracks, flint bands on the walls).

The preset values live in export/planet/rocky_terrain.py (PRESETS): the
exporter fills the NULL fields from them, so Godot never needs the table.
NULL azimuths, dip and seed are derived from the polygon's position — stable
across re-exports.
"""

from .model import Category, Layer, Field, Widget, ValueMap, STAGE_ROCKY_TERRAIN

CATEGORY = Category("rocky_terrain", "rocky terrain",
                    description="Rocky relief laid over the ground (blocks, ledges, buttes, strata)",
                    stage=STAGE_ROCKY_TERRAIN, flat=True)

RUGGEDNESS = [
    ("Flat — shader only, no relief", "flat"),
    ("Low — 3 m slabs", "low"),
    ("Medium — 8 m ledges, a few low buttes", "medium"),
    ("Rugged — 18 m ledges, buttes", "rugged"),
    ("Very rugged — 35 m ledges, tall buttes", "very_rugged"),
]

STYLES = [
    ("Slabs — staggered blocks", "slabs"),
    ("Columnar — narrow walls, smaller blocks", "columnar"),
    ("Yardang — buttes stretched along the wind", "yardang"),
    ("Strata — inclined ledges", "strata"),
    ("Chalk — lumpy white rock, wandering cracks, flint bands (Seven Sisters)", "chalk"),
]


def _opt(minimum, maximum, step):
    """A Range that accepts NULL (= take the preset value)."""
    return Widget("Range", {"Min": minimum, "Max": maximum, "Step": step, "AllowNull": True})


CATEGORY.add(Layer(
    "rocky_terrain", "Polygon",
    color="#7a6a5a",
    description="Rocky relief added over the ground (see layers/rocky_terrain.py)",
    terrain_modifier=True,
    properties={"ds_kind": "rocky_terrain"},
    symbol={"style": "dense7", "outline_width": "0.5", "outline_color": "#4a3f35"},
    fields=[
        Field("name", "string", "(Optional) Zone name"),
        Field("ruggedness", "string", "Ruggedness level — NULL fields below take its values",
              widget=ValueMap(RUGGEDNESS), default="'medium'"),
        Field("style", "string", "Rock form", widget=ValueMap(STYLES), default="'slabs'"),
        Field("cell_m", "double", "Block size (m, ≥ 75 to show in the mesh)",
              widget=_opt(10, 2000, 5)),
        Field("step_m", "double", "Ledge height (m), 0 = no ledges",
              widget=_opt(0, 200, 1)),
        Field("riser", "double", "Share of a ledge taken by its wall: 0.05 = sheer, 1 = ramp",
              widget=_opt(0.02, 1.0, 0.01)),
        Field("joint_depth_m", "double", "Depth of the groove between blocks (m)",
              widget=_opt(0, 50, 0.5)),
        Field("joint_width_m", "double", "Width of the groove between blocks (m, ≥ 25 to show)",
              widget=_opt(1, 200, 1)),
        Field("butte_rate", "double", "Share of the butte cells that rise, 0-1",
              widget=_opt(0.0, 1.0, 0.01)),
        Field("butte_height_m", "double", "Butte height (m)", widget=_opt(0, 500, 5)),
        Field("butte_cell_m", "double", "Spacing of the buttes (m)", widget=_opt(50, 5000, 10)),
        Field("butte_wall_m", "double", "Width of a butte's wall (m)", widget=_opt(1, 500, 1)),
        Field("dip_deg", "double", "Strata dip (deg), 0 = level ledges", widget=_opt(0, 60, 1)),
        Field("dip_azimuth_deg", "double", "Direction the strata dip toward (deg from north)",
              widget=_opt(0, 360, 1)),
        Field("wind_azimuth_deg", "double", "Wind direction stretching the buttes (deg from north)",
              widget=_opt(0, 360, 1)),
        Field("elongation", "double", "Butte / block stretch along the wind, 1 = round",
              widget=_opt(1.0, 8.0, 0.1)),
        Field("lump_m", "double", "Height of the soft knobs (m), chalk style",
              widget=_opt(0, 50, 0.5)),
        Field("lump_wavelength_m", "double", "Size of the soft knobs (m)",
              widget=_opt(40, 2000, 10)),
        Field("detail_m", "double", "Size of the small blocks the shader draws (m)",
              widget=_opt(0.5, 30, 0.5)),
        Field("feather_m", "double", "Fade to the ground around, inside the outline (m, min 250)",
              widget=_opt(250, 20000, 50)),
        Field("seed", "integer", "Noise seed — change it to reshuffle the blocks",
              widget=_opt(0, 1000000, 1)),
    ],
))
