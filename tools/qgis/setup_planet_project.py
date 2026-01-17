"""
QGIS Quick Setup Script for StarDeception
==========================================
Run this in QGIS Python Console to automatically create
all the layers needed for a new planet.

Biome layers are split by **geometry type** and **property group** so that:
  - You draw rivers/canyons as LINES (not awkward thin polygons)
  - You place geysers/fumaroles as POINTS (not tiny polygons)
  - Each layer only shows properties relevant to its biomes
    (e.g. tree_type only on vegetation biomes, not ocean)

Layer structure (QGIS panel):
  • Groups (one per biome-name prefix before '-'):
      e.g. "maritime river", "forest", "icy", "rocky landform", …
      Each group contains all biome layers sharing that prefix.
  • Root level (no group):
      <planet>_contours  (Line)   — elevation contour lines
      <planet>_roads     (Line)   — roads and paths
      <planet>_poi       (Point)  — cities, stations, spawn points

Storage: PostgreSQL (PostGIS)
  Connection : "DyingStar"  (must be configured in QGIS before running)
  Schema     : PLANET_NAME  (created automatically)
  Tables     : one per layer, named after the biome type
               with hyphens replaced by underscores (e.g. maritime_river_ocean)

The export script (export_planet.py) merges all biome layers into a single
GeoJSON, buffering lines by their `width` and points by their `radius` to
produce polygons for the biome raster and color map.

Prerequisites:
    • QGIS 3.44+
    • A PostgreSQL/PostGIS connection named "DyingStar" configured in
      Layer → Data Source Manager → PostgreSQL

Usage:
    1. Open QGIS
    2. Open Python Console (Ctrl+Alt+P)
    3. Paste this script or run:
       exec(open('/path/to/StarDeception/tools/qgis/setup_planet_project.py').read())
"""

import os
from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsFeature,
    QgsGeometry,
    QgsField,
    QgsFields,
    QgsCoordinateReferenceSystem,
    QgsCoordinateTransformContext,
    QgsRectangle,
    QgsSymbol,
    QgsCategorizedSymbolRenderer,
    QgsRendererCategory,
    QgsMarkerSymbol,
    QgsLineSymbol,
    QgsFillSymbol,
    QgsEditorWidgetSetup,
    QgsDefaultValue,
    QgsProperty,
    QgsUnitTypes,
    QgsWkbTypes,
    QgsExpressionContextUtils,
    QgsDataSourceUri,
    QgsProviderRegistry,
    QgsLayerTreeGroup,
)
from qgis.PyQt.QtCore import QVariant
from qgis.PyQt.QtGui import QColor, QFont
from qgis.utils import iface


# ============================================================
# CONFIGURATION
# ============================================================
PLANET_NAME = "tarsis_8"
WORK_DIR = os.path.expanduser(
    "/datas/developpement/sources/StarDeception/StarDeception/assets/qgis"
)
EXISTING_FEATURES = os.path.expanduser(
    "/datas/developpement/sources/StarDeception/StarDeception/assets/planet_features.geojson"
)
PLANET_RADIUS_M = 1155667  # planet radius in metres (used for degree ↔ metre conversions)

# ============================================================
# BIOME CATALOGUE — Complete list of all supported biome types
# Each entry: (index, biome_type, color_hex, description, category, terrain_modifier)
# terrain_modifier=True  → modifies chunk heightmap (craters, rivers, canyons…)
# terrain_modifier=False → populate only (forests, deserts, cities…)
# ============================================================
BIOME_CATALOGUE = [
    # --- Terrestrial / Earth-like ---
    (0,  "maritime_river-ocean","#1a5276", "A vast expanse of liquid water subject to natural currents", "terrestrial", False),
    (2,  "maritime_river-lake", "#3498db", "A freshwater or saltwater basin, isolated from ocean currents", "terrestrial", False),
    (3,  "maritime_river-delta","#1a6e5c", "Alluvial wetland at the river mouth",  "terrestrial", False),
    (4,  "maritime_river-beach","#f0d9a0", "Accumulation of loose sediments (sand, gravel, pebbles) along a coastline", "terrestrial", False),
    (5,  "aride_desert-sandy_desert","#d4a437", "A hyperarid region dominated by the accumulation of quartz or silicate grains", "terrestrial", False),
    (6,  "aride_desert-rocky_desert","#a0744f", "An arid expanse characterized by bare rock slabs and stone plateaus (mesas) sculpted by erosion", "terrestrial", False),
    (7,  "aride_desert-salt_desert","#e8dcc8", "An endorheic depression where evaporation of runoff water leaves behind a crust of evaporites", "terrestrial", False),
    (8,  "meadow_steppe-meadow","#7dae52", "A temperate biome dominated by a continuous herbaceous layer and soils rich in organic matter, favored by regular but insufficient rainfall for the development of a dense forest cover", "terrestrial", False),
    (9,  "meadow_steppe-savanna","#b8a84a", "A tropical or subtropical ecosystem characterized by a dry grassy carpet dotted with isolated trees, governed by a marked water seasonality", "terrestrial", False),
    (10, "meadow_steppe-steppe","#9ca056", "Semi-arid plain covered with short grasses and shrubby plants, forming a transition zone between meadow and desert", "terrestrial", False),
    (11, "forest-temperate_forest","#2d5a1e", "Forest formation composed of deciduous trees or mixed stands, featuring a thick layer of decomposing litter", "terrestrial", False),
    (12, "forest-boreal_forest","#1e4a2a", "A vast belt of conifers adapted to cold climates, with acidic soil and reduced species biodiversity", "terrestrial", False),
    (13, "forest-tropical_forest","#1a5a10", "A high-density vegetation ecosystem characterized by a closed canopy and multiple vegetation layers. Humidity is saturated", "terrestrial", False),
    (14, "forest-dead_forest", "#5c4a3a", "Tree stand that has lost its biological viability. The woody structures survive as charred or mineralized skeletons", "terrestrial", False),
    # (15 removed — was jungle, deleted)
    (16, "wetland-swamp",     "#4a6741", "A wooded or grassy wetland where stagnant water permanently saturates the soil. Characterized by fine sedimentation and high bacterial activity", "terrestrial", False),
    (17, "wetland-mangrove",  "#3a5a30", "An amphibious coastal forest located in tropical zones. The trees have roots adapted to high salinity and muddy soil", "terrestrial", False),
    (18, "wetland-bog",       "#5a6a4a", "A wet, acidic ecosystem that accumulates undecomposed organic matter (peat). Growth is dominated by sphagnum mosses, creating a spongy soil capable of trapping significant amounts of carbon", "terrestrial", False),
    (19, "icy-tundra",        "#8fa8b5", "Polar biome defined by the absence of trees and the presence of frozen ground. Vegetation is limited to mosses, lichens, and dwarf shrubs", "terrestrial", False),
    (20, "icy-snow",           "#e8eaed", "Permanent blankets of snow ice that increase in density until they become firn ice", "terrestrial", False),
    (21, "icy-glacier",        "#c8e0f0", "Continental ice mass resulting from the crystallization of snow. Under the effect of its own weight, the ice behaves like a viscous fluid, flowing and sculpting valleys", "terrestrial", False),
    (22, "rocky_landform-raw_mountain", "#7a7a7a", "A high-altitude summit or slope located above the lichen growth limit. The landscape is dominated by exposed bedrock", "terrestrial", False),
    (23, "rocky_landform-alpine_mountain", "#6a8a5a", "A mountain zone located between the tree line and the permanent snow line. Characterized by short grasslands (alpine meadows) and flora adapted to intense UV radiation and strong winds", "terrestrial", False),
    (24, "rocky_landform-cliff", "#6e6e6e", "Rocky escarpment with a near-vertical slope resulting from tectonic processes or erosion", "terrestrial", False),
    (25, "rocky_landform-canyon", "#8a5a3a", "Deep gorge with steep walls carved by linear erosion of a watercourse in horizontal sedimentary strata", "terrestrial", False),
    (26, "volcanic_geothermal-active_volcano", "#4a2c2a", "A geological formation in the process of eruption or exhibiting significant internal magmatic activity. Characterized by emissions of tephra, gas and heat", "volcanic", False),
    (27, "volcanic_geothermal-volcanic_basalt", "#2a2a2a", "A plain of dense, dark, extrusive igneous rock. Rapid surface cooling creates a fine-grained rock, often structured into vast plateaus", "volcanic", False),
    (28, "volcanic_geothermal-lava_field", "#1a0a0a", "Extent of solidified lava exhibiting varied surface morphologies", "volcanic", False),
    (29, "volcanic_geothermal-lava_lake", "#cc3300", "A depression filled with liquid magma, kept molten by thermal convection. A semi-solid crust can form on the surface, constantly fractured by magma currents", "volcanic", False),
    (30, "volcanic_geothermal-fumarole", "#8a7a5a", "Volcanic gas emanation escaping from fissures. Composed mainly of water vapor, CO2 and sulfur compounds which often precipitate around the vent in the form of crystal", "volcanic", False),
    (31, "volcanic_geothermal-geothermal", "#6a8a6a", "A surface hydrothermal system comprising hot springs and pools saturated with dissolved minerals. The interaction between water and heat creates deposits and geysers", "volcanic", False),
    (32, "volcanic_geothermal-obsidian_field", "#0a0a1a", "A rapidly cooled lava flow that did not crystallize, forming a sharp, black volcanic glass", "volcanic", False),
    (33, "volcanic_geothermal-ash_desert", "#4a4a4a", "A thick layer of ash deposited after an explosive eruption. The landscape is monochrome, arid, and the soil is very loose", "volcanic", False),
    (34, "volcanic_geothermal-magmatic_crust", "#3a1a0a", "An unstable zone where a thin layer of solidified rock covers a shallow magma reservoir. It exhibits extremely high surface heat flow and risks of collapse", "volcanic", False),
    # (35 removed — was regolith, merged into spatial-lunar_ground)
    (36, "spatial-crater",    "#808070", "Circular structure resulting from a meteorite impact. It consists of a central depression, a raised rim and a radial ejecta field", "barren", True),
    # (37 removed — was crater_rim, now merged into spatial-crater)
    (38, "spatial-lunar_ground", "#aaaaaa", "Loose dusty surface with heavily cratered bright terrain, lunar regolith covering", "barren", False),
    (39, "spatial-lunar_pool", "#4a4a5a", "Vast plains of dark basalt occupying giant impact basins. Unlike the highlands, the lunar seas are smoother and have few large craters", "barren", False),
    # (40 removed — was ejecta_field, deleted)
    # (41 removed — was boulder_field, deleted)
    (42, "aride_desert-dusty_plain", "#b0a890", "Low-lying area covered with very fine particles (silt, clay). Susceptible to dust storms", "barren", False),
    (43, "icy-ice_plain",      "#d0e8f0", "A flat expanse of massive ice. The albedo is very high, resulting in almost total reflection of stellar radiation", "cryo", False),
    (44, "icy-ice_crevasse",   "#90b8d0", "A deep structural rupture within a glacial body or thick ice pack. The walls are vertical and reveal the stratification of the ice", "cryo", True),
    (45, "icy-ice_pick",       "#c0d8e8", "The formation of ice and hardened snow blades or needles. These structures, which can reach several meters in height, result from a sublimation process of intense solar radiation in very dry and cold air. They create a sharp, mineral labyrinth", "cryo", True),
    (46, "icy-nitrogen_ice",   "#e0e8f0", "A plain composed of solidified nitrogen, stable only at extremely low temperatures. Nitrogen ice behaves in a ductile manner, allowing internal convection currents and surface regeneration that erases impact craters", "cryo", False),
    (47, "icy-methane_lake",  "#2a4a6a", "A liquid basin composed of a mixture of light hydrocarbons, primarily methane and ethane. Stable under cryogenic pressure and temperature conditions. The liquid has very low viscosity and surface tension, resulting in extremely slow and faint waves. Shorelines are sculpted by the erosion of hydrocarbons on a base of rock-hard water ice", "cryo", False),
    (48, "icy-hydrocarbon_dune", "#5a4a3a", "Hydrocarbon sand dunes (Titan)", "cryo", False),
    (49, "icy-cryovolcanic",  "#b0c8d8", "A geological formation found in cold worlds where magma is replaced by volatiles (water, ammonia, methane) in a liquid state. Eruptions occur when internal pressure forces these liquids through the icy crust, solidifying instantly upon contact with the atmosphere or a vacuum, creating domes of molten ice", "cryo", False),
    (50, "icy-frozen_ocean",   "#8ab0c8", "A thick ice pack of water ice overlying a liquid ocean maintained by tidal heating or thermal insulation", "cryo", False),
    (51, "icy-sublimation_pit", "#c8d8e0", "A rugged terrain formed by the direct transition of CO2 ice from a solid to a gaseous state under the effect of solar radiation, creating irregular depressions", "cryo", False),
    (52, "icy-permafrost",     "#8a9a8a", "Soil whose temperature remains below 0 degrees C for years. Structured soils (frost polygons) are often found there, resulting from freeze-thaw cycles", "cryo", False),
    (53, "volcanic_geothermal-ice_geyser", "#d8e8f8", "A cryovolcanic phenomenon where plumes of water vapor, nitrogen, or methane are expelled from the depths", "cryo", True),
    (54, "aride_desert-iron_desert", "#c0603a", "A biome whose characteristic red color comes from the oxidation of iron dust. The atmosphere there is often thin and rich in dust", "martian", False),
    # (55 removed — was dust_storm, deleted)
    (56, "aride_desert-dry_river_bed", "#8a7a5a", "A former dried-up channel. The soil is composed of rounded pebbles and stratified sediments", "martian", True),
    # (57 removed — was polar_cap, deleted)
    # (58 removed — was ventifact, deleted)
    # (59 removed — was cloud_deck, deleted)
    # (60 removed — was acid_rain, deleted)
    (61, "rocky_landform-pressure_canyon", "#4a3a2a", "A deep rift where atmospheric pressure is higher than at the surface. Temperature increases with depth", "atmosphere", True),
    (62, "special-liquid_hydrocarbon_areas", "#3a5a7a", "Surface liquid at extreme pressure/temperature", "atmosphere", False),
    (63, "meadow_steppe-sulfur_plain", "#c8c030", "Yellowish expanses reminiscent of the moon Io. The ground is covered in elemental sulfur and solid sulfur dioxide", "toxic", False),
    (64, "volcanic_geothermal-sulfur_volcano", "#b8a020", "Unlike terrestrial silicate volcanoes, these spew molten sulfur whose color changes according to the temperature (from yellow to black through blood red)", "toxic", False),
    (65, "maritime_river-acid_lake", "#80a030", "Basins filled with a mixture of water and strong acids (sulfuric or hydrochloric), often located near volcanic areas", "toxic", False),
    (66, "wetland-ammonia_swamp", "#6080a0", "Humid areas where the main solvent is not pure water but a water-ammonia mixture. The ammonia acts as an antifreeze, allowing the liquid to exist at temperatures well below 0\u00b0C", "toxic", False),
    (67, "meadow_steppe-chlorinated_field", "#80c060", "Salt deserts composed of halides (such as sodium or potassium chloride). These plains are often the result of the complete evaporation of ancient salt seas", "toxic", False),
    (68, "special-radioactive_waste",  "#50a050", "Irradiated contaminated zone",         "toxic", False),
    (69, "special-tar_basin",           "#1a1a1a", "Depressions filled with heavy hydrocarbons (bitumen, asphalt). These basins are formidable natural traps", "toxic", False),
    (70, "special-brine_basin",        "#4a7a7a", "Submarine or surface lakes with such high salinity that the liquid becomes much denser than the surrounding water. These areas are often devoid of oxygen", "toxic", False),
    (71, "crystalline-crystalline_fields", "#a0c0e0", "Areas covered with macro-crystals (quartz, selenite or fluorite). These formations are generally created in giant hydrothermal cavities whose roof has been eroded, exposing perfect geometric structures", "mineral", False),
    (72, "aride_desert-metal_plain", "#8a8a9a", "A biome whose surface is composed of native metals (iron, nickel or copper) or minerals with a metallic luster (pyrite, magnetite)", "mineral", False),
    (73, "rocky_landform-cave", "#7050a0", "A natural underground network. Depending on the planet, it may be adorned with ice stalactites, limestone, or even exotic crystals", "mineral", False),
    (74, "crystalline-quartz_desert", "#d0c8b8", "Arid expanse composed of pure silica grains. Unlike classic silica sand, the surface has a vitreous and semi-translucent appearance", "mineral", False),
    (75, "volcanic_geothermal-mineral_thermal_source", "#50b0a0", "A hydrothermal water basin saturated with dissolved minerals. The cooling of the water at the surface leads to the formation of travertine terraces or siliceous frits. The basins are often vividly colored", "mineral", True),
    (76, "crystalline-salt_crystal_field", "#e0d8c8", "Massive sedimentary deposit of halites. The biome is characterized by natural cubic formations and hopper-like structures rising from the ground", "mineral", False),
    (77, "meadow_steppe-terraformed_grass", "#60c040", "Artificial grassland ecosystem whose parameters have been modified to match a specific biological standard", "artificial", False),
    (78, "forest-terraformed_forest", "#208020", "Artificial planted forest cover on previously treated soil", "artificial", False),
    (79, "urban-mining_excavation", "#5a4a3a", "Open-pit industrial excavation for mineral resource extraction. Features a stepped topography", "artificial", False),
    (80, "urban-ruins",       "#6a6060", "Urban or industrial complex in a state of advanced structural degradation", "artificial", False),
    (81, "urban-urban",        "#707070", "High-density surface of artificial structures and integrated infrastructure. The natural ground is completely sealed by synthetic or metallic coatings", "artificial", False),
    (82, "meadow_steppe-agriculture_land", "#a0c040", "Industrial agricultural production zone. Characterized by a geometric sectorization of the land", "artificial", False),
    (83, "urban-landing_pad",  "#505050", "Stabilized and reinforced platform designed to withstand the thermal and mechanical stresses of spacecraft propulsion systems", "artificial", False),
    (84, "meadow_steppe-wasteland_irradiated","#4a5a3a","Environmental wasteland with high residual radiological contamination", "artificial", False),
    (85, "maritime_river-river", "#2471a3", "A permanent watercourse flowing in a defined natural channel, fed by surface or underground sources, permanently carrying water over a significant distance", "terrestrial", True),
    (86, "volcanic_geothermal-lava_river", "#cc5000", "An active flow channel transporting molten rock (extrusive magma). Unlike a stationary lava field, a river is characterized by a defined flow velocity", "volcanic", True),
    (87, "rocky_landform-mining_cave", "#8a6a4a", "An artificial or natural cavity modified for mineral extraction. It is distinguished by fractured walls and supporting structures", "artificial", False),
    (88, "volcanic_geothermal-columnar_basalt_vertical", "#3d3d4a", "Composed of prisms of cooled lava and basaltic volcanic columns, these structures exhibit strict geometric regularity", "volcanic", False),
    (89, "aride_desert-anhydrite_desert", "#c8bfb0", "Composed of dehydrated calcium sulfate. These are white or greyish expanses, formed of hard mineral plates, often resulting from the evaporation of ancient marine basins", "terrestrial", False),
    (90, "aride_desert-valley_of_fire", "#b85a3a", "Ancient sand dune, composed of Aztec sandstone", "terrestrial", False),
    (91, "aride_desert-corundum_plateau", "#8a7080", "High plateaus of extremely hard rock. The walls are sharp and virtually unaffected by conventional erosion", "terrestrial", False),
    (92, "aride_desert-corundum_sand_desert", "#b07888", "Expanses where the ground is littered with fragments of raw sapphires or rubies, ranging from fine grains of sand to angular gravel, creating crystalline reflections under the starlight", "terrestrial", False),
    (93, "rocky_landform-arachnoide", "#6a5a50", "Radial fracture extending beyond the circular fracture", "terrestrial", False),
    (94, "volcanic_geothermal-lava_dome", "#8a3020", "A mass of lava whose high viscosity prevents it from flowing", "volcanic", True),
    (95, "rocky_landform-perforated_limestone", "#c8b898", "(beware of trypophobia) composed of perforated limestone", "terrestrial", False),
    (96, "volcanic_geothermal-pele_haire", "#8a6a20", "Capillary obsidian: wind-borne lava projection in the form of filaments", "volcanic", False),
    (97, "icy-frozen_methane", "#d0dae8", "Frozen methane takes the form of soap. This can produce masses of ice", "cryo", False),
]

# Build lookup helpers from the catalogue
BIOME_BY_NAME = {b[1]: b for b in BIOME_CATALOGUE}
BIOME_COLORS = {b[1]: b[2] for b in BIOME_CATALOGUE}
BIOME_IS_TERRAIN_MODIFIER = {b[1]: b[5] for b in BIOME_CATALOGUE}

# ============================================================
# BIOME → LAYER ASSIGNMENT
# ============================================================
# Each biome is assigned to exactly one layer group based on:
#   1. Natural geometry type (polygon / line / point)
#   2. What properties the artist needs to set per-feature
#
# "terrain"    → Polygon — base terrain, only needs elevation range
# "vegetation" → Polygon — forests etc., needs tree_type / density
# "liquid"     → Polygon — water / lava surfaces, needs depth / wave
# "linear"     → Line    — rivers / canyons, needs width / flow
# "point"      → Point   — geysers / vents, needs radius / intensity

BIOME_LAYER_GROUP = {
    # ── Liquid surfaces (Polygon) ─────────────────────────────
    # Drawn as polygon areas — these are bodies of liquid.
    "maritime_river-ocean": "individual",  # dedicated layer (1 layer = 1 biome)
    "maritime_river-lake": "individual",  # dedicated layer (1 layer = 1 biome)
    "maritime_river-delta": "individual",  # dedicated layer (1 layer = 1 biome)
    "maritime_river-beach": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-sandy_desert": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-rocky_desert": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-salt_desert": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-anhydrite_desert": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-valley_of_fire": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-corundum_plateau": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-corundum_sand_desert": "individual",  # dedicated layer (1 layer = 1 biome)
    "meadow_steppe-meadow": "individual",  # dedicated layer (1 layer = 1 biome)
    "meadow_steppe-savanna": "individual",  # dedicated layer (1 layer = 1 biome)
    "meadow_steppe-steppe": "individual",  # dedicated layer (1 layer = 1 biome)
    "forest-temperate_forest": "individual",  # dedicated layer (1 layer = 1 biome)
    "forest-boreal_forest": "individual",  # dedicated layer (1 layer = 1 biome)
    "forest-tropical_forest": "individual",  # dedicated layer (1 layer = 1 biome)
    "forest-dead_forest": "individual",  # dedicated layer (1 layer = 1 biome)
    "wetland-swamp": "individual",  # dedicated layer (1 layer = 1 biome)
    "wetland-mangrove": "individual",  # dedicated layer (1 layer = 1 biome)
    "wetland-bog": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-tundra": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-snow": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-glacier": "individual",  # dedicated layer (1 layer = 1 biome)
    "rocky_landform-raw_mountain": "individual",  # dedicated layer (1 layer = 1 biome)
    "rocky_landform-alpine_mountain": "individual",  # dedicated layer (1 layer = 1 biome)
    "rocky_landform-cliff": "individual",  # dedicated layer (1 layer = 1 biome)
    "rocky_landform-canyon": "individual",  # dedicated layer (1 layer = 1 biome)
    "rocky_landform-arachnoide": "individual",  # dedicated layer (1 layer = 1 biome)
    "rocky_landform-perforated_limestone": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-active_volcano": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-volcanic_basalt": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-lava_field": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-lava_lake": "individual",  # dedicated layer (1 layer = 1 biome)
    "methane_lake":       "liquid",   # legacy, now individual
    "icy-methane_lake":   "individual",  # dedicated layer (1 layer = 1 biome)
    "frozen_ocean":       "liquid",   # legacy, now individual
    "icy-frozen_ocean":   "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-sublimation_pit": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-permafrost":     "individual",  # dedicated layer (1 layer = 1 biome)
    "supercritical_fluid":"liquid",   # legacy, now individual
    "liquid_hydrocarbon_areas": "individual",  # dedicated layer (1 layer = 1 biome)
    "sulfur_plain":       "terrain",   # legacy, now individual
    "meadow_steppe-sulfur_plain": "individual",  # dedicated layer (1 layer = 1 biome)
    "sulfur_volcano":    "terrain",   # legacy, now individual
    "volcanic_geothermal-sulfur_volcano": "individual",  # dedicated layer (1 layer = 1 biome)
    "acid_lake":          "liquid",   # legacy, now individual
    "maritime_river-acid_lake": "individual",  # dedicated layer (1 layer = 1 biome)
    "ammonia_marsh":      "liquid",   # legacy, now individual
    "wetland-ammonia_swamp": "individual",  # dedicated layer (1 layer = 1 biome)
    "chlorine_flat":      "terrain",  # legacy, now individual
    "meadow_steppe-chlorinated_field": "individual",  # dedicated layer (1 layer = 1 biome)
    "radioactive_waste": "individual",  # dedicated layer (1 layer = 1 biome)
    "tar_pit":            "liquid",   # legacy, now individual
    "tar_basin":          "individual",  # dedicated layer (1 layer = 1 biome)
    "brine_pool":         "liquid",   # legacy, now individual
    "brine_basin":        "individual",  # dedicated layer (1 layer = 1 biome)
    "crystal_field":      "terrain",  # legacy, now individual
    "crystalline-crystalline_fields": "individual",  # dedicated layer (1 layer = 1 biome)
    "metal_plain":        "terrain",  # legacy, now individual
    "aride_desert-metal_plain": "individual",  # dedicated layer (1 layer = 1 biome)
    "rocky_landform-mining_cave": "individual",  # dedicated layer (1 layer = 1 biome)
    "nitrogen_ice":       "liquid",   # surface ice — legacy, now individual
    "icy-nitrogen_ice":   "individual",  # dedicated layer (1 layer = 1 biome)

    # ── Vegetation biomes (Polygon) ───────────────────────────
    # Drawn as polygon areas — artist needs tree_type, density, canopy.
    # "forest-temperate_forest" is now "individual" (see above)
    # "forest-boreal_forest" is now "individual" (see above)
    # "forest-tropical_forest" is now "individual" (see above)
    #"forest_tropical":    "vegetation",
    # "forest-dead_forest" is now "individual" (see above)
    #"forest_dead":        "vegetation",
    # "jungle" has been deleted
    # "wetland-swamp" is now "individual" (see above)
    #"swamp":              "vegetation",
    # "wetland-mangrove" is now "individual" (see above)
    #"mangrove":           "vegetation",
    # "wetland-bog" is now "individual" (see above)
    #"bog":                "vegetation",
    "terraformed_grass":  "vegetation",  # legacy, now individual
    "meadow_steppe-terraformed_grass": "individual",  # dedicated layer (1 layer = 1 biome)
    "terraformed_forest": "vegetation",  # legacy, now individual
    "forest-terraformed_forest": "individual",  # dedicated layer (1 layer = 1 biome)
    "mining_excavation":  "terrain",  # legacy, now individual
    "urban-mining_excavation": "individual",  # dedicated layer (1 layer = 1 biome)
    "ruins":              "terrain",  # legacy, now individual
    "urban-ruins":        "individual",  # dedicated layer (1 layer = 1 biome)
    "urban":              "terrain",  # legacy, now individual
    "urban-urban":        "individual",  # dedicated layer (1 layer = 1 biome)
    "agriculture":        "vegetation",  # legacy, now individual
    "meadow_steppe-agriculture_land": "individual",  # dedicated layer (1 layer = 1 biome)
    "landing_pad":        "terrain",  # legacy, now individual
    "urban-landing_pad":  "individual",  # dedicated layer (1 layer = 1 biome)
    "wasteland_irradiated": "terrain",  # legacy, now individual
    "meadow_steppe-wasteland_irradiated": "individual",  # dedicated layer (1 layer = 1 biome)

    # ── Linear features (LineString) ──────────────────────────
    # Drawn as lines with a width — naturally path-like features.
    "river":              "linear",    # legacy, now individual
    "maritime_river-river": "individual",  # dedicated layer (1 layer = 1 biome)
    "lava_river":         "linear",    # legacy, now individual
    "volcanic_geothermal-lava_river": "individual",  # dedicated layer (1 layer = 1 biome)
    # "rocky_landform-canyon" is now "individual" (see INDIVIDUAL_BIOME_LAYERS)
    #"canyon":             "linear",    # deep eroded gorge (follows a path)
    "ice_crevasse":       "linear",    # fracture lines in ice — legacy, now individual
    "icy-ice_crevasse":   "individual",  # dedicated layer (1 layer = 1 biome)
    "dry_riverbed":       "linear",    # legacy, now individual
    "aride_desert-dry_river_bed": "individual",  # dedicated layer (1 layer = 1 biome)
    "pressure_canyon":    "linear",    # legacy, now individual
    "rocky_landform-pressure_canyon": "individual",  # dedicated layer (1 layer = 1 biome)

    # ── Point features (Point) ────────────────────────────────
    # Placed as points with a radius — small localized features.
    "volcanic_geothermal-fumarole": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-geothermal": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-obsidian_field": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-ash_desert": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-magmatic_crust": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-columnar_basalt_vertical": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-lava_dome": "individual",  # dedicated layer (1 layer = 1 biome)
    "volcanic_geothermal-pele_haire": "individual",  # dedicated layer (1 layer = 1 biome)
    "ice_geyser":         "point",     # legacy, now individual
    "volcanic_geothermal-ice_geyser": "individual",  # dedicated layer (1 layer = 1 biome)
    "mineral_hot_spring": "point",     # legacy, now individual
    "volcanic_geothermal-mineral_thermal_source": "individual",  # dedicated layer (1 layer = 1 biome)
    "gemstone_cave":      "point",     # legacy, now individual
    "rocky_landform-cave": "individual",  # dedicated layer (1 layer = 1 biome)
    "quartz_desert":      "terrain",    # legacy, now individual
    "crystalline-quartz_desert": "individual",  # dedicated layer (1 layer = 1 biome)
    "salt_crystal_field": "terrain",  # legacy, now individual
    "crystalline-salt_crystal_field": "individual",  # dedicated layer (1 layer = 1 biome)
    "spatial-crater": "individual",  # dedicated layer (1 layer = 1 biome)
    "spatial-lunar_ground": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-dusty_plain": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-ice_plain": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-methane_lake": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-hydrocarbon_dune": "individual",  # dedicated layer (1 layer = 1 biome)
    "liquid_hydrocarbon_areas": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-cryovolcanic": "individual",  # dedicated layer (1 layer = 1 biome)
    "icy-frozen_methane": "individual",  # dedicated layer (1 layer = 1 biome)
    "aride_desert-iron_desert": "individual",  # dedicated layer (1 layer = 1 biome)

    # ── Everything else → Terrain (Polygon) ───────────────────
    # Default group — base terrain biomes that only need elevation.
}

# All biomes not explicitly assigned go to "terrain"
for _idx, _btype, _hex, _desc, _cat, _tmod in BIOME_CATALOGUE:
    if _btype not in BIOME_LAYER_GROUP:
        BIOME_LAYER_GROUP[_btype] = "terrain"

# Build reverse lookup: group → list of biome catalogue entries
# "individual" biomes get their own dedicated layer and are NOT in grouped layers.
BIOMES_BY_GROUP = {"terrain": [], "vegetation": [], "liquid": [], "linear": [], "point": [], "individual": []}
for _idx, _btype, _hex, _desc, _cat, _tmod in BIOME_CATALOGUE:
    group = BIOME_LAYER_GROUP[_btype]
    BIOMES_BY_GROUP[group].append((_idx, _btype, _hex, _desc, _cat, _tmod))

# ============================================================
# INDIVIDUAL BIOME LAYERS — New 1-layer-per-biome system
# ============================================================
# Biomes listed here get their own dedicated QGIS layer instead of
# being grouped into biomes_terrain/liquid/vegetation/etc.
#
# biome_type, biome_index, and color_hex are stored as QGIS layer
# custom properties (not per-feature fields).  The layer name is
# <planet>_<biome_type>.  Each entry defines the geometry type and
# the biome-specific fields the artist fills in.
#
# Biomes NOT listed here still use the legacy grouped layers.
#
# Key = biome_type (must match BIOME_CATALOGUE)
INDIVIDUAL_BIOME_LAYERS = {
    "maritime_river-ocean": {
        "group_name": "maritime river",
        "layer_name": "ocean",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Ocean name"),
            ("water_color", "string", "(Optional) Water color override"),
        ],
        "widgets": {
            "water_color": ("Color", {}),  # QGIS color picker widget
        },
    },
    "maritime_river-lake": {
        "group_name": "maritime river",
        "layer_name": "lake",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Lake name"),
            ("water_color", "string", "(Optional) Water color override"),
            ("salinity", "integer", "(Optional) Salinity percentage 0-100 (default 0)"),
        ],
        "widgets": {
            "water_color": ("Color", {}),  # QGIS color picker widget
            "salinity": ("Range", {"Min": 0, "Max": 100, "Step": 1}),
        },
    },
    "maritime_river-delta": {
        "group_name": "maritime river",
        "layer_name": "delta",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Delta name"),
        ],
        "widgets": {},
    },
    "maritime_river-beach": {
        "group_name": "maritime river",
        "layer_name": "beach",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Beach name"),
            ("beach_color", "string", "(Optional) Beach color override"),
        ],
        "widgets": {
            "beach_color": ("Color", {}),  # QGIS color picker widget
        },
    },
    "aride_desert-sandy_desert": {
        "group_name": "aride desert",
        "layer_name": "sandy desert",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Sandy desert name"),
        ],
        "widgets": {},
    },
    "aride_desert-rocky_desert": {
        "group_name": "aride desert",
        "layer_name": "rocky desert",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Rocky desert name"),
        ],
        "widgets": {},
    },
    "aride_desert-salt_desert": {
        "group_name": "aride desert",
        "layer_name": "salt desert",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Salt desert name"),
        ],
        "widgets": {},
    },
    "meadow_steppe-meadow": {
        "group_name": "meadow steppe",
        "layer_name": "meadow",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Meadow zone name"),
        ],
        "widgets": {},
    },
    "meadow_steppe-savanna": {
        "group_name": "meadow steppe",
        "layer_name": "savanna",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Savanna zone name"),
        ],
        "widgets": {},
    },
    "meadow_steppe-steppe": {
        "group_name": "meadow steppe",
        "layer_name": "steppe",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Steppe zone name"),
        ],
        "widgets": {},
    },
    "forest-temperate_forest": {
        "group_name": "forest",
        "layer_name": "temperate forest",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Forest zone name"),
            ("density", "double", "Vegetation density 0.0-1.0"),
            ("canopy_height", "integer", "Canopy height in metres"),
        ],
        "widgets": {
            "density": ("Range", {"Min": 0.0, "Max": 1.0, "Step": 0.01}),
            "canopy_height": ("Range", {"Min": 0, "Max": 200, "Step": 1}),
        },
    },
    "forest-boreal_forest": {
        "group_name": "forest",
        "layer_name": "boreal forest",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Forest zone name"),
            ("density", "double", "Vegetation density 0.0-1.0"),
            ("canopy_height", "integer", "Canopy height in metres"),
        ],
        "widgets": {
            "density": ("Range", {"Min": 0.0, "Max": 1.0, "Step": 0.01}),
            "canopy_height": ("Range", {"Min": 0, "Max": 200, "Step": 1}),
        },
    },
    "forest-tropical_forest": {
        "group_name": "forest",
        "layer_name": "tropical forest",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Forest zone name"),
            ("density", "double", "Vegetation density 0.0-1.0"),
            ("canopy_height", "integer", "Canopy height in metres"),
        ],
        "widgets": {
            "density": ("Range", {"Min": 0.0, "Max": 1.0, "Step": 0.01}),
            "canopy_height": ("Range", {"Min": 0, "Max": 200, "Step": 1}),
        },
    },
    "wetland-swamp": {
        "group_name": "wetland",
        "layer_name": "swamp",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "wetland-mangrove": {
        "group_name": "wetland",
        "layer_name": "mangrove",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "wetland-bog": {
        "group_name": "wetland",
        "layer_name": "bog",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-tundra": {
        "group_name": "icy",
        "layer_name": "tundra",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-snow": {
        "group_name": "icy",
        "layer_name": "snow",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-glacier": {
        "group_name": "icy",
        "layer_name": "glacier",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "rocky_landform-raw_mountain": {
        "group_name": "rocky landform",
        "layer_name": "raw mountain",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "rocky_landform-alpine_mountain": {
        "group_name": "rocky landform",
        "layer_name": "alpine mountain",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "rocky_landform-cliff": {
        "group_name": "rocky landform",
        "layer_name": "cliff",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "rocky_landform-canyon": {
        "group_name": "rocky landform",
        "layer_name": "canyon",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("elevation_bottom", "integer", "Elevation at the bottom (metres)"),
        ],
        "widgets": {
            "elevation_bottom": ("Range", {"Min": -5000, "Max": 10000, "Step": 1}),
        },
    },
    "volcanic_geothermal-active_volcano": {
        "group_name": "volcanic geothermal",
        "layer_name": "active volcano",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-volcanic_basalt": {
        "group_name": "volcanic geothermal",
        "layer_name": "volcanic basalt",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-lava_field": {
        "group_name": "volcanic geothermal",
        "layer_name": "lava field",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-lava_lake": {
        "group_name": "volcanic geothermal",
        "layer_name": "lava lake",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-fumarole": {
        "group_name": "volcanic geothermal",
        "layer_name": "fumarole",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-geothermal": {
        "group_name": "volcanic geothermal",
        "layer_name": "geothermal",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-obsidian_field": {
        "group_name": "volcanic geothermal",
        "layer_name": "obsidian field",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-ash_desert": {
        "group_name": "volcanic geothermal",
        "layer_name": "ash desert",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-magmatic_crust": {
        "group_name": "volcanic geothermal",
        "layer_name": "magmatic crust",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "spatial-crater": {
        "group_name": "spatial",
        "layer_name": "crater",
        "geom_type": "Point",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("radius", "double", "Crater radius in metres"),
        ],
        "widgets": {
            "radius": ("Range", {"Min": 10, "Max": 100000, "Step": 10}),
        },
    },
    "spatial-lunar_ground": {
        "group_name": "spatial",
        "layer_name": "lunar ground",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "spatial-lunar_pool": {
        "group_name": "spatial",
        "layer_name": "lunar pool",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "aride_desert-dusty_plain": {
        "group_name": "aride desert",
        "layer_name": "dusty plain",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-ice_plain": {
        "group_name": "icy",
        "layer_name": "ice plain",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-ice_crevasse": {
        "group_name": "icy",
        "layer_name": "ice crevasse",
        "geom_type": "LineString",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-ice_pick": {
        "group_name": "icy",
        "layer_name": "ice pick",
        "geom_type": "LineString",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("height", "double", "Formation height in metres"),
        ],
        "widgets": {
            "height": ("Range", {"Min": 0, "Max": 100, "Step": 0.5}),
        },
    },
    "icy-nitrogen_ice": {
        "group_name": "icy",
        "layer_name": "nitrogen ice",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-methane_lake": {
        "group_name": "icy",
        "layer_name": "methane lake",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-hydrocarbon_dune": {
        "group_name": "icy",
        "layer_name": "hydrocarbon dune",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "liquid_hydrocarbon_areas": {
        "group_name": "uncategorized",
        "layer_name": "liquid hydrocarbon areas",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-cryovolcanic": {
        "group_name": "icy",
        "layer_name": "cryovolcanic",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-frozen_ocean": {
        "group_name": "icy",
        "layer_name": "frozen ocean",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-sublimation_pit": {
        "group_name": "icy",
        "layer_name": "sublimation pit",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-permafrost": {
        "group_name": "icy",
        "layer_name": "permafrost",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-ice_geyser": {
        "group_name": "volcanic geothermal",
        "layer_name": "ice geyser",
        "geom_type": "Point",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("ice_height", "integer", "Ice plume height in metres"),
            ("radius", "integer", "Influence radius in metres"),
        ],
        "widgets": {
            "ice_height": ("Range", {"Min": 1, "Max": 500, "Step": 1}),
            "radius": ("Range", {"Min": 10, "Max": 100000, "Step": 10}),
        },
    },
    "aride_desert-iron_desert": {
        "group_name": "aride desert",
        "layer_name": "iron desert",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "aride_desert-dry_river_bed": {
        "group_name": "aride desert",
        "layer_name": "dry river bed",
        "geom_type": "LineString",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("width", "integer", "Channel width in metres"),
        ],
        "widgets": {
            "width": ("Range", {"Min": 1, "Max": 500, "Step": 1}),
        },
    },
    "rocky_landform-pressure_canyon": {
        "group_name": "rocky landform",
        "layer_name": "pressure canyon",
        "geom_type": "LineString",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("depth", "integer", "Canyon depth in metres"),
        ],
        "widgets": {
            "depth": ("Range", {"Min": 0, "Max": 5000, "Step": 1}),
        },
    },
    "meadow_steppe-sulfur_plain": {
        "group_name": "meadow steppe",
        "layer_name": "sulfur plain",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-sulfur_volcano": {
        "group_name": "volcanic geothermal",
        "layer_name": "sulfur volcano",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "maritime_river-acid_lake": {
        "group_name": "maritime river",
        "layer_name": "acid lake",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "wetland-ammonia_swamp": {
        "group_name": "wetland",
        "layer_name": "ammonia swamp",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "meadow_steppe-chlorinated_field": {
        "group_name": "meadow steppe",
        "layer_name": "chlorinated field",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "radioactive_waste": {
        "group_name": "uncategorized",
        "layer_name": "radioactive waste",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "tar_basin": {
        "group_name": "uncategorized",
        "layer_name": "tar basin",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("depth", "integer", "Liquid depth in metres"),
        ],
        "widgets": {},
    },
    "brine_basin": {
        "group_name": "uncategorized",
        "layer_name": "brine basin",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("surface_depth", "integer", "Surface depth in metres"),
            ("depth", "integer", "Liquid depth in metres"),
        ],
        "widgets": {},
    },
    "crystalline-crystalline_fields": {
        "group_name": "crystalline",
        "layer_name": "crystalline fields",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "aride_desert-metal_plain": {
        "group_name": "aride desert",
        "layer_name": "metal plain",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "rocky_landform-mining_cave": {
        "group_name": "rocky landform",
        "layer_name": "mining cave",
        "geom_type": "Point",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "rocky_landform-cave": {
        "group_name": "rocky landform",
        "layer_name": "cave",
        "geom_type": "Point",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "crystalline-quartz_desert": {
        "group_name": "crystalline",
        "layer_name": "quartz desert",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-mineral_thermal_source": {
        "group_name": "volcanic geothermal",
        "layer_name": "mineral thermal source",
        "geom_type": "Point",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "crystalline-salt_crystal_field": {
        "group_name": "crystalline",
        "layer_name": "salt crystal field",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "meadow_steppe-terraformed_grass": {
        "group_name": "meadow steppe",
        "layer_name": "terraformed grass",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "forest-terraformed_forest": {
        "group_name": "forest",
        "layer_name": "terraformed forest",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "urban-mining_excavation": {
        "group_name": "urban",
        "layer_name": "mining excavation",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "urban-ruins": {
        "group_name": "urban",
        "layer_name": "ruins",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "urban-urban": {
        "group_name": "urban",
        "layer_name": "urban",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "meadow_steppe-agriculture_land": {
        "group_name": "meadow steppe",
        "layer_name": "agriculture land",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "urban-landing_pad": {
        "group_name": "urban",
        "layer_name": "landing pad",
        "geom_type": "Point",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "meadow_steppe-wasteland_irradiated": {
        "group_name": "meadow steppe",
        "layer_name": "wasteland irradiated",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "maritime_river-river": {
        "group_name": "maritime river",
        "layer_name": "river",
        "geom_type": "LineString",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("width_start", "double", "Channel width at start (m)"),
            ("width_end", "double", "Channel width at end (m)"),
            ("flow_rate", "double", "(Optional) Water flow rate"),
        ],
        "widgets": {
            "width_start": ("Range", {"Min": 0.2, "Max": 2000, "Step": 0.2}),
            "width_end": ("Range", {"Min": 0.2, "Max": 2000, "Step": 0.2}),
        },
    },
    "volcanic_geothermal-lava_river": {
        "group_name": "volcanic geothermal",
        "layer_name": "lava river",
        "geom_type": "LineString",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("width_start", "double", "Channel width at start (m)"),
            ("width_end", "double", "Channel width at end (m)"),
            ("flow_rate", "double", "(Optional) Water flow rate"),
        ],
        "widgets": {
            "width_start": ("Range", {"Min": 0.2, "Max": 2000, "Step": 0.2}),
            "width_end": ("Range", {"Min": 0.2, "Max": 2000, "Step": 0.2}),
        },
    },
    "volcanic_geothermal-columnar_basalt_vertical": {
        "group_name": "volcanic geothermal",
        "layer_name": "columnar basalt (vertical)",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "aride_desert-anhydrite_desert": {
        "group_name": "aride desert",
        "layer_name": "anhydrite desert",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "aride_desert-valley_of_fire": {
        "group_name": "aride desert",
        "layer_name": "valley of fire",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "aride_desert-corundum_plateau": {
        "group_name": "aride desert",
        "layer_name": "corundum plateau",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "aride_desert-corundum_sand_desert": {
        "group_name": "aride desert",
        "layer_name": "corundum sand desert",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "rocky_landform-arachnoide": {
        "group_name": "rocky landform",
        "layer_name": "arachnoide",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "rocky_landform-perforated_limestone": {
        "group_name": "rocky landform",
        "layer_name": "perforated limestone",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "volcanic_geothermal-lava_dome": {
        "group_name": "volcanic geothermal",
        "layer_name": "lava dome",
        "geom_type": "Point",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
            ("radius", "integer", "Radius in metres"),
        ],
        "widgets": {
            "radius": ("Range", {"Min": 10, "Max": 10000, "Step": 10}),
        },
    },
    "volcanic_geothermal-pele_haire": {
        "group_name": "volcanic geothermal",
        "layer_name": "pele haire",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "icy-frozen_methane": {
        "group_name": "icy",
        "layer_name": "frozen methane",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "(Optional) Zone name"),
        ],
        "widgets": {},
    },
    "region": {
        "group_name": "uncategorized",
        "layer_name": "region",
        "geom_type": "Polygon",
        "fields": [
            ("name", "string", "the name of the region"),
        ],
        "widgets": {},
    },
}


def hex_to_rgb(hex_color):
    """Convert '#rrggbb' to (r, g, b) tuple."""
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# ============================================================
# POSTGRESQL FIELD / GEOMETRY TYPE MAPS
# ============================================================
_PG_FIELD_TYPE_MAP = {
    "string":   QVariant.String,
    "integer":  QVariant.Int,
    "double":   QVariant.Double,
    "datetime": QVariant.DateTime,
}

_PG_WKB_MAP = {
    "Point":      QgsWkbTypes.Point,
    "LineString":  QgsWkbTypes.LineString,
    "Polygon":    QgsWkbTypes.Polygon,
}

def pg_table_name(layer_name):
    """Convert a layer name to a PostgreSQL table name inside the planet schema.
    """

    name = layer_name.replace(" ", "_")  # Just in case, replace spaces with underscores
    return name.replace("-", "_")

def _get_pg_connection():
    """Return the 'DyingStar' PostgreSQL provider connection.

    Raises RuntimeError with a clear message if the connection is not found so
    the artist knows what to configure in QGIS before re-running the script.
    """
    md = QgsProviderRegistry.instance().providerMetadata("postgres")
    connections = md.connections()
    if "DyingStar" not in connections:
        available = ", ".join(connections.keys()) or "(none)"
        raise RuntimeError(
            "PostgreSQL connection 'DyingStar' not found in QGIS.\n"
            f"  Available connections: {available}\n"
            "  → Add it via: Layer menu → Data Source Manager → PostgreSQL → New"
        )
    return connections["DyingStar"]


def _build_layer_uri(table_name):
    """Build a QgsDataSourceUri pointing to *table_name* in the planet schema.

    Uses the 'DyingStar' connection as the base and overrides the schema,
    table, geometry column, and primary key.
    """
    conn = _get_pg_connection()
    uri = QgsDataSourceUri(conn.uri())
    uri.setDataSource(PLANET_NAME, table_name, "geom", "", "fid")
    return uri


def _ensure_last_updated_trigger(conn, table_name):
    """Create a PostgreSQL trigger that auto-sets last_updated on INSERT and UPDATE.

    Idempotent: the trigger function is created once per schema, and the trigger
    itself uses CREATE OR REPLACE (PG 14+) / IF NOT EXISTS.
    Also adds the last_updated column if the table was created before this feature.
    """
    schema = PLANET_NAME
    # 1. Ensure the column exists (for pre-existing tables)
    conn.executeSql(
        f'ALTER TABLE "{schema}"."{table_name}" '
        f'ADD COLUMN IF NOT EXISTS last_updated TIMESTAMP WITH TIME ZONE'
    )
    # 2. Create the shared trigger function (once per schema, idempotent)
    conn.executeSql(f"""
        CREATE OR REPLACE FUNCTION "{schema}".set_last_updated()
        RETURNS TRIGGER AS $$
        BEGIN
            NEW.last_updated := NOW();
            RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
    """)
    # 3. Drop + recreate the trigger (safe idempotent pattern for all PG versions)
    trigger_name = f"trg_last_updated_{table_name}"
    conn.executeSql(
        f'DROP TRIGGER IF EXISTS "{trigger_name}" ON "{schema}"."{table_name}"'
    )
    conn.executeSql(f"""
        CREATE TRIGGER "{trigger_name}"
        BEFORE INSERT OR UPDATE ON "{schema}"."{table_name}"
        FOR EACH ROW
        EXECUTE FUNCTION "{schema}".set_last_updated();
    """)
    print(f"  ✓ last_updated trigger on {schema}.{table_name}")


def _configure_last_updated_widget(layer):
    """Configure the last_updated field in QGIS: DateTime widget, auto-fill on insert/update."""
    fidx = layer.fields().indexOf("last_updated")
    if fidx < 0:
        return
    # DateTime widget showing date + time
    widget_config = {
        "display_format": "yyyy-MM-dd HH:mm:ss",
        "field_format": "yyyy-MM-dd HH:mm:ss",
        "calendar_popup": False,
    }
    layer.setEditorWidgetSetup(fidx, QgsEditorWidgetSetup("DateTime", widget_config))
    # QGIS-side default: now() on both insert and update (apply_on_update=True)
    layer.setDefaultValueDefinition(fidx, QgsDefaultValue("now()", True))
    # Make it read-only so artists don't accidentally edit it
    form_config = layer.editFormConfig()
    form_config.setReadOnly(fidx, True)
    layer.setEditFormConfig(form_config)


def create_vector_layer(name, geom_type, fields_def, style_config=None):
    """Create (or load) a PostGIS table in the planet schema of the 'DyingStar' connection.

    Schema  : PLANET_NAME  (created if absent)
    Table   : pg_table_name(name)  — biome type with hyphens → underscores, no planet prefix
    Provider: 'postgres'

    If the table already exists the function loads it without truncating so that
    existing artist work is preserved.

    The layer is registered with the project but NOT inserted into the layer
    tree — callers in setup_planet() place it into the correct group node.
    """


    table_name = pg_table_name(name)
    conn = _get_pg_connection()

    # Ensure schema exists
    conn.executeSql(f'CREATE SCHEMA IF NOT EXISTS "{PLANET_NAME}"')

    # Check whether the table already exists
    existing_tables = [t.tableName() for t in conn.tables(PLANET_NAME)]
    if table_name in existing_tables:
        uri = _build_layer_uri(table_name)
        layer = QgsVectorLayer(uri.uri(False), name, "postgres")
        if not layer.isValid():
            print(f"  ✗ Failed to load existing table: {PLANET_NAME}.{table_name}")
            return None
        # Ensure last_updated column + trigger exist (for tables created before this feature)
        _ensure_last_updated_trigger(conn, table_name)
        _configure_last_updated_widget(layer)
        QgsProject.instance().addMapLayer(layer, False)
        print(f"  ✓ Loaded existing table: {PLANET_NAME}.{table_name} → {name} "
              f"({layer.featureCount()} features)")
        return layer

    # Build QgsFields from the field definitions + inject last_updated
    all_fields_def = list(fields_def) + [("last_updated", "datetime", "Last updated timestamp")]
    fields = QgsFields()
    for fname, ftype, comment in all_fields_def:
        qt = _PG_FIELD_TYPE_MAP.get(ftype, QVariant.String)
        fields.append(QgsField(fname, qt, comment=comment))

    wkb_type = _PG_WKB_MAP.get(geom_type, QgsWkbTypes.Polygon)
    crs = QgsCoordinateReferenceSystem("EPSG:4326")

    # createVectorTable signature: (schema, name, fields, wkbType, crs, overwrite, options)
    conn.createVectorTable(PLANET_NAME, table_name, fields, wkb_type, crs, False, {})

    # Set up the PostgreSQL trigger for automatic timestamp updates
    _ensure_last_updated_trigger(conn, table_name)

    uri = _build_layer_uri(table_name)
    layer = QgsVectorLayer(uri.uri(False), name, "postgres")
    if not layer.isValid():
        print(f"  ✗ Failed to load created table: {PLANET_NAME}.{table_name}")
        return None

    _configure_last_updated_widget(layer)
    QgsProject.instance().addMapLayer(layer, False)
    print(f"  ✓ Created table: {PLANET_NAME}.{table_name} → {name} ({geom_type}, {len(fields_def)} fields)")
    return layer


def apply_categorized_style(layer, field, categories):
    """
    Apply categorized symbology.
    categories: dict of {value: (r, g, b, alpha)}
    """
    cats = []
    geom_type = int(layer.geometryType())  # cast to int for safe comparison

    for value, color in categories.items():
        r, g, b = color[:3]
        a = color[3] if len(color) > 3 else 180
        color_str = QColor(r, g, b, a).name()

        if geom_type == 0:  # Point
            sym = QgsMarkerSymbol.createSimple({
                "name": "circle", "size": "3",
                "color": color_str, "outline_color": "black",
            })
        elif geom_type == 1:  # Line
            sym = QgsLineSymbol.createSimple({
                "color": color_str, "width": "0.6",
            })
        else:  # Polygon
            sym = QgsFillSymbol.createSimple({
                "color": color_str,
                "outline_color": "#000000", "outline_width": "0.3",
            })

        sym.setColor(QColor(r, g, b, a))
        cat = QgsRendererCategory(value, sym, str(value))
        cats.append(cat)

    renderer = QgsCategorizedSymbolRenderer(field, cats)
    layer.setRenderer(renderer)
    layer.triggerRepaint()


def create_individual_biome_layer(biome_type):
    """
    Create a dedicated QGIS layer for a single biome type (new 1-layer-per-biome system).

    The layer is named <PLANET_NAME>_<biome_type> and stores:
      - biome_type, biome_index, color_hex as QGIS layer custom properties
      - only biome-specific fields as per-feature attributes

    A simple fill/line/marker style is applied using the biome's catalogue colour.
    """
    if biome_type not in INDIVIDUAL_BIOME_LAYERS:
        print(f"  ✗ {biome_type} not in INDIVIDUAL_BIOME_LAYERS")
        return None

    layer_def = INDIVIDUAL_BIOME_LAYERS[biome_type]
    biome_entry = BIOME_BY_NAME.get(biome_type)

    # Biome catalogue entries provide index, color, description, etc.
    # Some layers (e.g. "region", legacy-named biomes) are not in the
    # catalogue — they still get created but without biome metadata.
    if biome_entry:
        idx, btype, color_hex, desc, cat, _tmod = biome_entry
    else:
        idx = -1
        color_hex = "#888888"

    geom_type = layer_def["geom_type"]
    fields = layer_def["fields"]

    layer = create_vector_layer(
        INDIVIDUAL_BIOME_LAYERS[biome_type]["layer_name"],
        geom_type,
        fields,
    )
    if not layer:
        return None

    # Store biome metadata as layer custom properties (not per-feature fields).
    # The export pipeline reads these to inject biome_type/biome_index/color_hex
    # into the merged GeoJSON so Godot's BiomeQuery sees them.
    layer.setCustomProperty("biome_type", biome_type)
    layer.setCustomProperty("biome_index", idx)
    layer.setCustomProperty("color_hex", color_hex)

    # Apply simple fill style with the biome colour
    r, g, b = hex_to_rgb(color_hex)
    color = QColor(r, g, b, 180)
    geom_type_int = int(layer.geometryType())
    if geom_type_int == 0:  # Point
        sym = QgsMarkerSymbol.createSimple({
            "name": "circle", "size": "3",
            "color": color.name(), "outline_color": "black",
        })
    elif geom_type_int == 1:  # Line
        sym = QgsLineSymbol.createSimple({
            "color": color.name(), "width": "0.6",
        })
    else:  # Polygon
        sym = QgsFillSymbol.createSimple({
            "color": color.name(),
            "outline_color": "#000000", "outline_width": "0.3",
        })
    sym.setColor(color)
    layer.renderer().setSymbol(sym)
    layer.triggerRepaint()

    # Set up editor widgets (e.g. color picker for water_color)
    widgets = layer_def.get("widgets", {})
    for field_name, (widget_type, widget_config) in widgets.items():
        fidx = layer.fields().indexOf(field_name)
        if fidx >= 0:
            layer.setEditorWidgetSetup(fidx, QgsEditorWidgetSetup(widget_type, widget_config))
            print(f"  ✓ {field_name}: {widget_type} widget")

    print(f"  ✓ Individual biome layer: {biome_type} "
          f"(idx={idx}, color={color_hex}, {geom_type})")
    return layer


def setup_road_dropdowns(layer):
    """Set up ValueMap dropdown widgets for road_type and surface fields."""
    # road_type dropdown
    road_type_idx = layer.fields().indexOf("road_type")
    if road_type_idx >= 0:
        road_types = [
            {"Highway — Multi-lane, high-speed, asphalt": "highway"},
            {"Road — Standard two-lane, paved surface": "road"},
            {"Path — Narrow pedestrian/vehicle track": "path"},
            {"Trail — Unpaved footpath, follows terrain": "trail"},
        ]
        widget = QgsEditorWidgetSetup("ValueMap", {"map": road_types})
        layer.setEditorWidgetSetup(road_type_idx, widget)
        print(f"  ✓ Set road_type dropdown (4 values)")

    # surface dropdown
    surface_idx = layer.fields().indexOf("surface")
    if surface_idx >= 0:
        surfaces = [
            {"Asphalt — Paved, smooth": "asphalt"},
            {"Concrete — Paved, rigid": "concrete"},
            {"Gravel — Loose stones": "gravel"},
            {"Dirt — Packed earth": "dirt"},
            {"Grass — Grass/earth mix": "grass"},
            {"Sand — Sandy track": "sand"},
            {"Stone — Cobblestone or flagstone": "stone"},
        ]
        widget = QgsEditorWidgetSetup("ValueMap", {"map": surfaces})
        layer.setEditorWidgetSetup(surface_idx, widget)
        print(f"  ✓ Set surface dropdown (7 values)")


def setup_road_auto_fields(layer):
    """
    Auto-populate width, lanes, speed_limit, surface, has_sidewalk, has_lighting
    based on road_type selection.

    Defaults per road_type:
      highway → width=12, lanes=4, speed_limit=120, surface=asphalt, sidewalk=0, lighting=1
      road    → width=6,  lanes=2, speed_limit=60,  surface=asphalt, sidewalk=1, lighting=1
      path    → width=2,  lanes=0, speed_limit=20,  surface=gravel,  sidewalk=0, lighting=0
      trail   → width=1,  lanes=0, speed_limit=5,   surface=dirt,    sidewalk=0, lighting=0
    """
    fields = layer.fields()

    auto_rules = {
        "width": {
            "highway": "12.0", "road": "6.0", "path": "2.0", "trail": "1.0",
        },
        "lanes": {
            "highway": "4", "road": "2", "path": "0", "trail": "0",
        },
        "speed_limit": {
            "highway": "120", "road": "60", "path": "20", "trail": "5",
        },
        "surface": {
            "highway": "'asphalt'", "road": "'asphalt'", "path": "'gravel'", "trail": "'dirt'",
        },
        "has_sidewalk": {
            "highway": "0", "road": "1", "path": "0", "trail": "0",
        },
        "has_lighting": {
            "highway": "1", "road": "1", "path": "0", "trail": "0",
        },
    }

    for field_name, type_map in auto_rules.items():
        fidx = fields.indexOf(field_name)
        if fidx < 0:
            continue
        cases = "\n".join(
            f"    WHEN \"road_type\" = '{rtype}' THEN {val}"
            for rtype, val in type_map.items()
        )
        expr = f"CASE\n{cases}\n    ELSE NULL\nEND"
        layer.setDefaultValueDefinition(fidx, QgsDefaultValue(expr, True))
        print(f"  ✓ {field_name} auto-fill from road_type")


def setup_road_style(layer):
    """Apply categorized line styling to roads by road_type."""
    road_styles = {
        "highway": (80, 80, 80, 255),      # dark grey, thick
        "road":    (140, 130, 120, 255),    # warm grey
        "path":    (180, 160, 120, 255),    # sandy brown
        "trail":   (120, 100, 60, 200),     # earthy brown, slightly transparent
    }
    road_widths = {
        "highway": 3.0,
        "road":    2.0,
        "path":    1.2,
        "trail":   0.8,
    }
    try:
        categories = []
        for rtype, (r, g, b, a) in road_styles.items():
            symbol = QgsLineSymbol.createSimple({
                "color": f"{r},{g},{b},{a}",
                "width": str(road_widths.get(rtype, 1.0)),
                "capstyle": "round",
                "joinstyle": "round",
            })
            cat = QgsRendererCategory(rtype, symbol, rtype.capitalize())
            categories.append(cat)
        renderer = QgsCategorizedSymbolRenderer("road_type", categories)
        layer.setRenderer(renderer)
        print(f"  ✓ Applied road style ({len(categories)} road types)")
    except Exception as e:
        print(f"  ⚠ Could not apply road style: {e}")


def setup_map_decorations():
    """
    Enable a lat/lon coordinate grid and a scale bar on the map canvas.

    QGIS stores decoration settings in QSettings (per-user) and reads them
    when it renders the canvas.  We write the settings then ask each
    decoration object to re-read them.
    """
    from qgis.PyQt.QtCore import QSettings
    s = QSettings()

    # ── Coordinate Grid ──────────────────────────────────────
    # 10° interval gives 36 × 18 cells over the full equirectangular extent.
    s.setValue("/qgis/grid/annotationEnabled", True)
    s.setValue("/qgis/grid/annotationDirection", 0)   # horizontal
    s.setValue("/qgis/grid/annotationFont", QFont("Sans", 8).toString())
    s.setValue("/qgis/grid/annotationPrecision", 1)
    s.setValue("/qgis/grid/enabled", True)
    s.setValue("/qgis/grid/intervalX", 10.0)
    s.setValue("/qgis/grid/intervalY", 10.0)
    s.setValue("/qgis/grid/offsetX", 0.0)
    s.setValue("/qgis/grid/offsetY", 0.0)
    s.setValue("/qgis/grid/style", 1)  # 0=solid, 1=crosses, 2=markers

    # Try to activate the decoration object so it renders immediately
    try:
        for dec in iface.mainWindow().findChildren(type(None)):
            cls_name = type(dec).__name__
            if cls_name == "QgsDecorationGrid":
                dec.setEnabled(True)
                dec.update()
                break
    except Exception:
        pass
    print("  ✓ Grid decoration: 10° interval, cross style, annotations on")

    # ── Scale Bar ────────────────────────────────────────────
    s.setValue("/qgis/scalebar/enabled", True)
    s.setValue("/qgis/scalebar/placement", 0)       # 0=bottom-left
    s.setValue("/qgis/scalebar/preferredSize", 0)    # 0=auto
    s.setValue("/qgis/scalebar/snapping", True)
    s.setValue("/qgis/scalebar/style", 0)            # 0=tick down
    s.setValue("/qgis/scalebar/colorBar", QColor(0, 0, 0).name())
    s.setValue("/qgis/scalebar/numMapUnitsPerScaleBarUnit", 1.0)

    try:
        for dec in iface.mainWindow().findChildren(type(None)):
            cls_name = type(dec).__name__
            if cls_name == "QgsDecorationScaleBar":
                dec.setEnabled(True)
                dec.update()
                break
    except Exception:
        pass
    print("  ✓ Scale bar decoration: bottom-left, auto-size")
    print("    (if not visible: View → Decorations → Grid / Scale Bar)")

    iface.mapCanvas().refresh()


# ============================================================
# CREATE PLANET LAYERS
# ============================================================
def setup_planet():
    """Create all standard planet layers with biomes split by geometry and properties."""
    print("=" * 60)
    print(f"  Setting up planet: {PLANET_NAME}")
    print("=" * 60)
    print()
    print("  Biome layer split:")
    for group, entries in BIOMES_BY_GROUP.items():
        if group == "individual":
            print(f"    {'individual':12s} → {len(entries)} biome types (1 layer each)")
        else:
            print(f"    {group:12s} → {len(entries)} biome types")
    print()

    n_individual = len(INDIVIDUAL_BIOME_LAYERS)
    total_steps = 5 + n_individual  # world_border + contours + roads + poi + existing_features + N individual

    project = QgsProject.instance()

    # Store planet config as project variables so export_planet.py can read them
    QgsExpressionContextUtils.setProjectVariable(project, "planet_name", PLANET_NAME)
    QgsExpressionContextUtils.setProjectVariable(project, "planet_radius_m", str(PLANET_RADIUS_M))
    print(f"  ✓ Project variables set: planet_name={PLANET_NAME}, planet_radius_m={PLANET_RADIUS_M}")

    # Set project CRS
    project.setCrs(QgsCoordinateReferenceSystem("EPSG:4326"))

    # Set default extent to full planet
    canvas = iface.mapCanvas()
    canvas.setExtent(QgsRectangle(-180, -90, 180, 90))
    canvas.refresh()

    # --- Decoration: coordinate grid + scale bar ---
    setup_map_decorations()

    # ----------------------------------------------------------------
    # Layer-tree group registry — groups are created on first use.
    # Biome layers are placed in a group named after the prefix before
    # the '-' in the biome type (underscores → spaces).
    # Contours / roads / poi go to the root level (no group).
    # ----------------------------------------------------------------
    root = project.layerTreeRoot()
    _groups = {}  # group_name → QgsLayerTreeGroup

    def _get_or_create_group(group_name):
        if group_name not in _groups:
            _groups[group_name] = root.addGroup(group_name)
        return _groups[group_name]

    step = 0

    # --- 1. World Border (root level) ---
    step += 1
    print(f"\n[{step}/{total_steps}] Creating World Border layer...")
    world_border = create_vector_layer(
        "world border",
        "Polygon",
        [],
    )
    if world_border:
        # Insert the full-extent rectangle if the table is empty
        if world_border.featureCount() == 0:
            wb_feat = QgsFeature(world_border.fields())
            wb_feat.setGeometry(QgsGeometry.fromRect(QgsRectangle(-180, -90, 180, 90)))
            world_border.dataProvider().addFeature(wb_feat)
            world_border.updateExtents()
        # Transparent fill with a thin border so it doesn't obscure biome layers
        symbol = QgsFillSymbol.createSimple({
            "color": "0,0,0,0",
            "outline_color": "#888888",
            "outline_width": "0.3",
        })
        world_border.renderer().setSymbol(symbol)
        world_border.triggerRepaint()
        root.addLayer(world_border)

    # --- 2. Elevation Contours (root level) ---
    step += 1
    print(f"\n[{step}/{total_steps}] Creating Elevation Contours layer...")
    contours = create_vector_layer(
        "contours",
        "LineString",
        [
            ("elevation", "double", "Elevation in metres above sea level"),
            ("type", "string", "Contour type: contour, ridge, valley, cliff"),
            ("interval", "double", "Contour interval this line represents"),
        ],
    )
    if contours:
        root.addLayer(contours)

    # ================================================================
    # INDIVIDUAL BIOME LAYERS — 1 layer = 1 biome (new system)
    # ================================================================
    for biome_type in INDIVIDUAL_BIOME_LAYERS:
        step += 1
        biome_entry = BIOME_BY_NAME.get(biome_type)
        desc = biome_entry[3] if biome_entry else biome_type
        print(f"\n[{step}/{total_steps}] Creating individual biome layer: {biome_type}...")
        print(f"        {desc}")
        layer = create_individual_biome_layer(biome_type)
        if layer:
            group_name = INDIVIDUAL_BIOME_LAYERS.get(biome_type, {}).get("group_name", None) or "root"
            if group_name:
                _get_or_create_group(group_name).addLayer(layer)
            else:
                root.addLayer(layer)

    # ================================================================
    # NON-BIOME LAYERS (root level)
    # ================================================================

    # --- Roads ---
    step += 1
    print(f"\n[{step}/{total_steps}] Creating Roads layer...")
    roads = create_vector_layer(
        "roads",
        "LineString",
        [
            ("name", "string", "Road name"),
            ("road_type", "string", "Road type: highway, road, path, trail"),
            ("width", "double", "Total width in meters (auto-filled from road_type)"),
            ("lanes", "integer", "Number of lanes (auto-filled from road_type)"),
            ("surface", "string", "Surface type: asphalt, gravel, dirt, grass, sand, stone"),
            ("speed_limit", "integer", "Speed limit in km/h (auto-filled from road_type)"),
            ("has_sidewalk", "integer", "0 or 1 (auto-filled)"),
            ("has_lighting", "integer", "0 or 1 (auto-filled)"),
        ],
    )
    if roads:
        setup_road_dropdowns(roads)
        setup_road_auto_fields(roads)
        setup_road_style(roads)
        root.addLayer(roads)

    # --- Points of Interest ---
    step += 1
    print(f"\n[{step}/{total_steps}] Creating Points of Interest layer...")
    poi = create_vector_layer(
        "poi",
        "Point",
        [
            ("name", "string", "Point of Interest name"),
            ("poi_type", "string", "Type of Point of Interest: city, station, landmark, spawn_point"),
            ("population", "integer", "Population of the Point of Interest"),
            ("radius", "double", "Influence radius in meters"),
            ("elevation", "double", "Ground elevation override"),
            ("description", "string", "Description of the Point of Interest"),
        ],
    )
    if poi:
        root.addLayer(poi)

    # --- Load existing features (GeoJSON reference layer, stays at root) ---
    step += 1
    print(f"\n[{step}/{total_steps}] Loading existing planet features...")
    if os.path.exists(EXISTING_FEATURES):
        existing = QgsVectorLayer(EXISTING_FEATURES, f"{PLANET_NAME}_existing_features", "ogr")
        if existing.isValid():
            QgsProject.instance().addMapLayer(existing, False)
            root.addLayer(existing)
            print(f"  ✓ Loaded: {EXISTING_FEATURES}")
            print(f"    Features: {existing.featureCount()}")
        else:
            print(f"  ⚠ Could not load: {EXISTING_FEATURES}")
    else:
        print(f"  ⚠ File not found: {EXISTING_FEATURES}")

    # ----------------------------------------------------------------
    # Sort: groups alphabetically, layers within each group
    # alphabetically, root-level layers alphabetically.
    # ----------------------------------------------------------------

    # Sort layers inside each group
    for grp in _groups.values():
        children = grp.children()
        sorted_children = sorted(children, key=lambda n: n.name().lower())
        for node in sorted_children:
            cloned = node.clone()
            grp.insertChildNode(-1, cloned)
            grp.removeChildNode(node)

    # Sort all root children (groups + root-level layers) alphabetically
    root_children = root.children()
    sorted_root = sorted(root_children, key=lambda n: n.name().lower())
    for node in sorted_root:
        cloned = node.clone()
        root.insertChildNode(-1, cloned)
        root.removeChildNode(node)

    n_groups = len(_groups)
    n_root_layers = sum(1 for n in root.children() if not isinstance(n, QgsLayerTreeGroup))
    print(f"\n  ✓ Layer tree organised: {n_groups} groups, {n_root_layers} root-level layers")

    # --- Save project ---
    os.makedirs(os.path.join(WORK_DIR, PLANET_NAME), exist_ok=True)
    project_path = os.path.join(WORK_DIR, PLANET_NAME, f"{PLANET_NAME}.qgz")
    project.write(project_path)
    print(f"\n  ✓ Project saved: {project_path}")

    print("\n" + "=" * 60)
    print("  Setup complete! Layer overview:")
    print()
    individual_biomes = BIOMES_BY_GROUP.get("individual", [])
    if individual_biomes:
        print(f"  INDIVIDUAL BIOME LAYERS ({len(individual_biomes)} — 1 layer = 1 biome):")
        for _idx, _btype, _hex, _desc, _cat, _tmod in individual_biomes:
            geom = INDIVIDUAL_BIOME_LAYERS.get(_btype, {}).get("geom_type", "?")
            grp = INDIVIDUAL_BIOME_LAYERS.get(_btype, {}).get("group_name", None) or "root"
            print(f"    🔷 {_btype:40s} ({geom:10s}) [{grp}] — {_desc}")
        print()

    print("  OTHER LAYERS (root level):")
    print("    🌐 world_border (Polygon) — full-extent reference border")
    print("    📏 contours  (LineString) — elevation contour lines")
    print("    🛤️  roads     (LineString) — roads and paths")
    print("    📌 poi       (Point)      — cities, stations, spawn points")
    print()
    print(f"  PostgreSQL schema: {PLANET_NAME}")
    print("  TIP: Linear biomes (rivers) are drawn as lines — the export")
    print("  script will auto-buffer them by 'width' into polygons.")
    print("  Point biomes (geysers) are auto-buffered by 'radius'.")
    print()
    print("  Export with: export_planet.py")
    print("=" * 60)


# Run
setup_planet()
