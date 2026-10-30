"""
StarGrotte caves: one point per cave entrance, read by export_cave_sites.py.
===========================================================================

The point is the entrance; its fields are the cave's AUTHORED parameters
(CavePlacement + CaveProfile in scenes/planet/cave/).  The values fitted to the
relief (mouth depth, network offset, porch, light shafts) are not here: they
are computed by tools/stargrot/fit_cave_items.tscn on the current terrain,
which writes the file imported into the persistence (one networked "cave" prop
per point).

Not the ``cave`` biome layer (layers/biomes/rocky_landform.py), nor the
``caves.dsmpart`` terrain modifier reserved in link_modifiers.py.
"""

from .model import Category, Layer, Field, ValueMap, Range, STAGE_FINAL

CATEGORY = Category("caves", None, description="StarGrotte caves (no sub-group)",
                    stage=STAGE_FINAL)

ENTRANCE_TYPES = [
    ("Ramp — porch on a slope or a cliff", "ramp"),
    ("Shaft — doline", "shaft"),
    ("Hangar — giant porch", "hangar"),
]

NETWORK_STYLES = [
    ("Auto — drawn by the seed", "auto"),
    ("Branchwork — trunk with tributaries", "branchwork"),
    ("Maze — fissures on a joint grid", "maze"),
    ("Anastomotic — braided low tubes", "anastomotic"),
    ("Spongework — many small linked cavities", "spongework"),
    ("Ramiform — big chambers, radiating branches", "ramiform"),
    ("Shafts — a cascade of pits", "shafts"),
]

DEFAULT_LIBRARY = "res://scenes/planet/cave/libraries/cave_rock_sculpted_open.tres"
LIBRARIES = [(path.rsplit("/", 1)[1].removesuffix(".tres"), path) for path in (
    DEFAULT_LIBRARY,
    "res://scenes/planet/cave/libraries/cave_rock_sculpted.tres",
    "res://scenes/planet/cave/libraries/cave_rock_open.tres",
    "res://scenes/planet/cave/libraries/cave_rock.tres",
    "res://scenes/planet/cave/libraries/cave_sand_open.tres",
    "res://scenes/planet/cave/libraries/cave_sand.tres",
    "res://scenes/planet/cave/libraries/cave_ice_open.tres",
    "res://scenes/planet/cave/libraries/cave_ice.tres",
)]

CAVE_SVG = "symbol/poi_cave.svg"    # bundled with QGIS (svg/symbol/)
CAVE_SIZE_MM = 6


def _cave_symbol(color):
    """The QGIS cave pictogram on the entrance point."""
    from qgis.core import QgsMarkerSymbol, QgsSvgMarkerSymbolLayer, QgsSymbolLayerUtils, QgsProject
    from qgis.PyQt.QtGui import QColor

    cave = QgsSvgMarkerSymbolLayer(QgsSymbolLayerUtils.svgSymbolNameToPath(
        CAVE_SVG, QgsProject.instance().pathResolver()), CAVE_SIZE_MM)
    cave.setFillColor(color)
    cave.setStrokeColor(QColor("black"))
    sym = QgsMarkerSymbol()
    sym.changeSymbolLayer(0, cave)
    return sym


def _cave_labels(layer):
    """The cave's name right of its icon; settings already on the layer are kept."""
    from qgis.core import QgsPalLayerSettings, QgsVectorLayerSimpleLabeling, QgsUnitTypes
    current = layer.labeling() if layer.labelsEnabled() else None
    if isinstance(current, QgsVectorLayerSimpleLabeling):
        settings = QgsPalLayerSettings(current.settings())
    else:
        settings = QgsPalLayerSettings()
        settings.fieldName = "name"
    settings.placement = QgsPalLayerSettings.Placement.OverPoint
    settings.quadOffset = QgsPalLayerSettings.QuadrantPosition.QuadrantRight
    settings.xOffset = CAVE_SIZE_MM / 2 + 1
    settings.offsetUnits = QgsUnitTypes.RenderUnit.RenderMillimeters
    layer.setLabeling(QgsVectorLayerSimpleLabeling(settings))
    layer.setLabelsEnabled(True)
    layer.triggerRepaint()


def _num(name, kind, comment, default, low, high, step):
    return Field(name, kind, comment, widget=Range(low, high, step), default=str(default))


CATEGORY.add(Layer(
    "cave_site", "Point", (
        Field("name", "string", "Cave name, shown in game and in the admin panel"),
        Field("placement_id", "string",
              "Stable cave id, unique on the planet: keep it when editing, it is the prop's identity",
              default="concat('qgis-', @planet_name, '-', substr(uuid(), 2, 8))"),
        _num("heading_deg", "double", "Entrance heading around the local vertical (deg)", 0.0, -180.0, 180.0, 1.0),
        Field("seed", "integer", "Geometry and dressing seed: another value = another cave",
              default="rand(1, 2147483646)"),
        _num("ramp_length_m", "double", "Maximum entrance approach length (m)", 20.0, 20.0, 1600.0, 1.0),
        _num("cover_m", "double", "Minimum rock cover above the network (m)", 3.0, 1.0, 100.0, 0.5),
        Field("profile_id", "string", "Profile identifier (cache identity)", default="'rock'"),
        _num("generator_version", "integer", "Cave generator version (8 or 9)", 9, 8, 9, 1),
        Field("asset_library", "string", "Walls, floors and decorations",
              widget=ValueMap(LIBRARIES), default=f"'{DEFAULT_LIBRARY}'"),
        Field("entrance_type", "string", "Entrance kind", widget=ValueMap(ENTRANCE_TYPES), default="'ramp'"),
        Field("network_style", "string", "Cave pattern", widget=ValueMap(NETWORK_STYLES), default="'auto'"),
        _num("length_m", "double", "Network extent along the heading (m)", 100.0, 80.0, 1000.0, 1.0),
        _num("tunnel_width_m", "double", "Nominal gallery width (m)", 5.0, 2.0, 80.0, 0.25),
        _num("tunnel_height_m", "double", "Nominal gallery height (m)", 4.5, 2.0, 60.0, 0.25),
        _num("chamber_count", "integer", "Authored chamber count", 2, 1, 12, 1),
        _num("depth_m", "double", "Interior drop the chambers spread over (m)", 8.0, 0.0, 480.0, 0.5),
        _num("level_count", "integer", "Tiers the network descends through", 1, 1, 4, 1),
        _num("chamber_width_m", "double", "Size scale of the largest chambers (m)", 18.0, 6.0, 320.0, 1.0),
        _num("chamber_height_m", "double", "Reference chamber height (m)", 10.0, 4.0, 160.0, 1.0),
        _num("branch_count", "integer", "Secondary branches", 3, 0, 8, 1),
        _num("pillar_count", "integer", "Rock pillars in the chambers", 3, 0, 12, 1),
        _num("bridge_count", "integer", "Natural rock bridges", 1, 0, 3, 1),
        _num("crawl_count", "integer", "Generator 8 only: terminal low passages", 2, 0, 4, 1),
        _num("roughness", "double", "Wall and floor relief (0..1)", 0.4, 0.0, 1.0, 0.05),
        _num("bend", "double", "Gallery meander (0..1)", 0.5, 0.0, 1.0, 0.05),
        _num("entrance_width_m", "double", "Mouth width (m)", 5.0, 0.5, 100.0, 0.1),
        _num("entrance_height_m", "double", "Mouth height (m)", 4.5, 0.5, 60.0, 0.1),
        _num("exit_open", "integer", "1 = a second surface opening at the far end", 0, 0, 1, 1),
        _num("exit_width_m", "double", "Second opening width (m)", 3.0, 1.2, 100.0, 0.1),
        _num("exit_height_m", "double", "Second opening height (m)", 2.5, 2.0, 60.0, 0.1),
        _num("shaft_length_m", "double", "Longest reach of the exit's bowl (m)", 16.0, 6.0, 120.0, 1.0),
        _num("walkable_target", "double", "Share of the floor reachable on foot (0.2..0.95)", 0.7, 0.2, 0.95, 0.05),
        _num("entrance_noise", "double", "Seeded erosion of the entrance outline (0..1)", 0.55, 0.0, 1.0, 0.05),
        _num("gallery_noise", "double", "Generator 9: gallery erosion (0..1)", 0.6, 0.0, 1.0, 0.05),
        _num("light_shafts", "integer", "Generator 9: natural light shafts", 1, 0, 4, 1),
    ),
    color="#c08040",
    description="StarGrotte cave entrances (read by export_cave_sites.py)",
    properties={"ds_kind": "cave_site"},
    symbol_factory=_cave_symbol,
    labeling=_cave_labels,
))
