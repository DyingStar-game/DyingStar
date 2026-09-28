"""
Volcanoes, lava flows and fumaroles — where and how, never the relief itself.
===============================================================================

Like the mountains (layers/mountains.py), these layers only describe the
INTENT; Godot generates the relief, the lava crust and the vents at runtime as
a deterministic function of the position, identically on the client, the
server, the collision and the road / rail profiles.  export_volcanoes.py turns
them into parts/volcanoes.dsmpart, lava_flows.dsmpart and fumaroles.dsmpart.

None of them is a biome: the rock under a volcano, a flow or a fumarole field
stays the rock of the ground (a rock_type zone, the planet's corundum), so a
volcano on a blue corundum plateau is blue — several blues, deeper up the
flanks and in the crater — and its lava a darker crust of that same rock.

``volcano`` (POI)
    The summit point.  Pick a ``type`` and leave the other fields NULL, or set
    them to override the preset:

        stratovolcano  steep concave cone, summit crater, radial gullies
        shield         very broad and flat, wide shallow caldera
        caldera        low ring around a large collapsed basin
        cinder_cone    small straight cone with a crater
        lava_dome      bulging dome, no crater

    ``flank_exponent``: 0.5 convex (dome, shield), 1 straight cone, 2 concave
    (strato).  Only 0.5 / 1 / 1.5 / 2 / 3 are kept — other values are snapped.

``lava_flow`` (Lines)
    Drawn FROM THE SOURCE DOWNHILL: the drawing direction is the flow
    direction.  Lava never flows uphill: its surface follows the lowest ground
    met so far along the line, and wherever the terrain rises above it a
    channel is cut through (the exporter warns when the end of a line is
    higher than its start).  ``state``: active (glowing cracks), cooling,
    solid (a frozen flow you can walk on).

``fumarole_field`` (Region)
    Godot scatters vents over the polygon at ``density`` vents per km², each
    with a smoke plume and a stain of ``gas`` deposits on the rock.

``fumarole_vent`` (POI)
    One vent placed by hand.

The preset values live in export/planet/volcanoes.py (PRESETS): the exporter
fills the NULL fields from them, so Godot never needs the table.

Biome indices 26 (active_volcano), 30 (fumarole), 86 (lava_river),
94 (lava_dome) and 107 (fumarole_field) belonged to the biome layers these
replace — never reuse them.  ``fumarole_field`` keeps its PostGIS table;
migrate_volcanic_layers.py copies the others into the new tables.
"""

from .model import Category, Layer, Field, Widget, ValueMap

CATEGORY = Category("volcanoes", "volcanoes",
                    description="Procedural volcanoes, lava flows and fumaroles")

TYPES = [
    ("Stratovolcano — steep cone, summit crater", "stratovolcano"),
    ("Shield — very broad, gentle slopes", "shield"),
    ("Caldera — collapsed summit basin", "caldera"),
    ("Cinder cone — small cone with a crater", "cinder_cone"),
    ("Lava dome — bulging, no crater", "lava_dome"),
    ("Custom — every field set by hand", "custom"),
]

EXPONENTS = [
    ("0.5 — convex (dome, shield)", "0.5"),
    ("1 — straight cone", "1"),
    ("1.5 — slightly concave", "1.5"),
    ("2 — concave (stratovolcano)", "2"),
    ("3 — very concave", "3"),
]

ACTIVITIES = [
    ("Dormant — no plume", "dormant"),
    ("Fuming — summit plume", "fuming"),
    ("Active — plume, glowing lava lake", "active"),
]

LAVA_STATES = [
    ("Active — molten, glowing cracks", "active"),
    ("Cooling — dark crust, faint glow", "cooling"),
    ("Solid — frozen flow, walkable", "solid"),
]

GASES = [
    ("Steam — white plume, pale deposits", "steam"),
    ("Sulfur — yellow deposits", "sulfur"),
    ("CO2 — faint plume, reddish oxides", "co2"),
    ("Chlorine — green-white deposits", "chlorine"),
]


def _opt(minimum, maximum, step):
    """A Range that accepts NULL (= take the preset value)."""
    return Widget("Range", {"Min": minimum, "Max": maximum, "Step": step, "AllowNull": True})


CATEGORY.add(Layer(
    "volcano", "Point",
    color="#8a2a1a",
    description="Volcano summit — Godot builds the cone and the crater (see layers/volcanoes.py)",
    terrain_modifier=True,
    properties={"ds_kind": "volcano"},
    fields=[
        Field("name", "string", "(Optional) Volcano name"),
        Field("type", "string", "Volcano preset — NULL fields below take its values",
              widget=ValueMap(TYPES), default="'stratovolcano'"),
        Field("base_diameter_m", "double", "Diameter at the foot (m)",
              widget=_opt(100, 200000, 50)),
        Field("height_m", "double", "Height of the rim above the surrounding ground (m)",
              widget=_opt(5, 12000, 5)),
        Field("crater_diameter_m", "double", "Summit crater / caldera diameter (m), 0 = none",
              widget=_opt(0, 50000, 10)),
        Field("crater_depth_m", "double", "Crater depth below the rim (m)",
              widget=_opt(0, 3000, 5)),
        Field("floor_frac", "double", "Share of the crater that is a flat floor, 0–0.95",
              widget=_opt(0.0, 0.95, 0.05)),
        Field("flank_exponent", "string", "Flank curve (see the layer description)",
              widget=ValueMap(EXPONENTS)),
        Field("roughness", "double", "Flank bumpiness, share of the height (0–0.5)",
              widget=_opt(0.0, 0.5, 0.01)),
        Field("gullies", "double", "Radial ravines, 0 = none, 1 = deep",
              widget=_opt(0.0, 1.0, 0.05)),
        Field("irregularity", "double", "Lobed outline of the foot, 0 = a circle",
              widget=_opt(0.0, 0.5, 0.05)),
        Field("has_lava_lake", "integer", "1 = the crater holds a lava lake",
              widget=_opt(0, 1, 1), default="0"),
        Field("lake_fill_m", "double", "Lava lake surface above the crater floor (m)",
              widget=_opt(0, 1000, 1)),
        Field("activity", "string", "Plume / lake glow",
              widget=ValueMap(ACTIVITIES), default="'dormant'"),
        Field("seed", "integer", "Noise seed — change it to reshuffle the gullies and lobes",
              widget=_opt(0, 1000000, 1)),
        Field("impurity_intensity", "double",
              "Ore / colour richness: NULL = from the position (0.6-1.4), 0 = sterile, 2 = twice",
              widget=_opt(0.0, 2.0, 0.05)),
    ],
))

CATEGORY.add(Layer(
    "lava_flow", "LineString",
    color="#cc5000",
    description="Lava flow — drawn from the source downhill; never climbs",
    terrain_modifier=True,
    direction_marker=True,
    properties={"ds_kind": "lava_flow"},
    symbol={"width": "1.6"},
    fields=[
        Field("name", "string", "(Optional) Flow name"),
        Field("state", "string", "active / cooling / solid",
              widget=ValueMap(LAVA_STATES), default="'active'"),
        Field("width_start_m", "double", "Width at the source (m)",
              widget=_opt(2, 2000, 1)),
        Field("width_end_m", "double", "Width at the end (m)",
              widget=_opt(2, 2000, 1)),
        Field("depth_m", "double", "Lava surface below its banks (m)",
              widget=_opt(0.5, 50, 0.5)),
        Field("seed", "integer", "Crust pattern seed",
              widget=_opt(0, 1000000, 1)),
    ],
))

CATEGORY.add(Layer(
    "fumarole_field", "Polygon",
    color="#a08a60",
    description="Area Godot scatters fumarole vents over at the given density",
    properties={"ds_kind": "fumarole_field"},
    symbol={"style": "dense6", "outline_width": "0.4", "outline_color": "#6a5a30"},
    fields=[
        Field("name", "string", "(Optional) Field name"),
        Field("density", "double", "Vents per km²", widget=_opt(0.1, 500, 0.1)),
        Field("radius", "double", "Typical vent radius (m)", widget=_opt(0.5, 200, 0.5)),
        Field("intensity", "double", "Emission intensity 0.0-1.0", widget=_opt(0.0, 1.0, 0.05)),
        Field("gas", "string", "Dominant gas — plume colour and deposits",
              widget=ValueMap(GASES), default="'sulfur'"),
        Field("plume_height_m", "double", "Plume height (m)", widget=_opt(1, 500, 1)),
        Field("stain", "double", "Deposit stain on the rock, 0 = none, 1 = strong",
              widget=_opt(0.0, 1.0, 0.05)),
        Field("seed", "integer", "Scatter seed", widget=_opt(0, 1000000, 1)),
    ],
))

CATEGORY.add(Layer(
    "fumarole_vent", "Point",
    color="#8a7a5a",
    description="One fumarole vent placed by hand",
    properties={"ds_kind": "fumarole_vent"},
    fields=[
        Field("name", "string", "(Optional) Vent name"),
        Field("radius", "double", "Vent radius (m)", widget=_opt(0.5, 200, 0.5)),
        Field("intensity", "double", "Emission intensity 0.0-1.0", widget=_opt(0.0, 1.0, 0.05)),
        Field("gas", "string", "Dominant gas — plume colour and deposits",
              widget=ValueMap(GASES), default="'sulfur'"),
        Field("plume_height_m", "double", "Plume height (m)", widget=_opt(1, 500, 1)),
        Field("stain", "double", "Deposit stain on the rock around it, 0–1",
              widget=_opt(0.0, 1.0, 0.05)),
    ],
))
