#!/usr/bin/env python3
"""
Generate biome terrain module folders for ALL biomes in the QGIS catalogue.

Creates  scenes/planet/<biome_type>/<biome_type>_terrain.gd  for every biome
that doesn't already have a folder.  The content follows the exact same schema
as the existing hand-written modules (canyon_terrain.gd, fumarole_terrain.gd…).

Layer groups:
  terrain    → simple identification module (no terrain carving)
  vegetation → adds DEFAULT_VEGETATION_DENSITY + DEFAULT_TREE_TYPE
  liquid     → adds DEFAULT_DEPTH_M + IS_LIQUID flag
  linear     → already done (canyon, icy-ice_crevasse, aride_desert-dry_river_bed, rocky_landform-pressure_canyon, river)
  point      → already done (cave/rocky_landform-cave, fumarole, volcanic_geothermal-ice_geyser, volcanic_geothermal-mineral_thermal_source)
"""

import os
import textwrap

BASE = os.path.join(
    os.path.dirname(__file__), "..", "scenes", "planet"
)
BASE = os.path.normpath(BASE)

# ─── Complete catalogue (index, biome_type, color_hex, description, category) ─
BIOME_CATALOGUE = [
    (0,  "maritime_river-ocean", "#1a5276", "A vast expanse of liquid water subject to natural currents", "terrestrial"),
    (2,  "maritime_river-lake", "#3498db", "A freshwater or saltwater basin, isolated from ocean currents", "terrestrial"),
    (3,  "maritime_river-delta","#1a6e5c", "Alluvial wetland at the river mouth",  "terrestrial"),
    (4,  "maritime_river-beach","#f0d9a0", "Accumulation of loose sediments (sand, gravel, pebbles) along a coastline", "terrestrial"),
    (5,  "aride_desert-sandy_desert","#d4a437", "A hyperarid region dominated by the accumulation of quartz or silicate grains", "terrestrial"),
    (6,  "aride_desert-rocky_desert","#a0744f", "An arid expanse characterized by bare rock slabs and stone plateaus (mesas) sculpted by erosion", "terrestrial"),
    (7,  "aride_desert-salt_desert","#e8dcc8", "An endorheic depression where evaporation of runoff water leaves behind a crust of evaporites", "terrestrial"),
    (8,  "meadow_steppe-meadow","#7dae52", "A temperate biome dominated by a continuous herbaceous layer and soils rich in organic matter, favored by regular but insufficient rainfall for the development of a dense forest cover", "terrestrial"),
    (9,  "meadow_steppe-savanna","#b8a84a", "A tropical or subtropical ecosystem characterized by a dry grassy carpet dotted with isolated trees, governed by a marked water seasonality", "terrestrial"),
    (10, "meadow_steppe-steppe","#9ca056", "Semi-arid plain covered with short grasses and shrubby plants, forming a transition zone between meadow and desert", "terrestrial"),
    (11, "forest-temperate_forest","#2d5a1e", "Forest formation composed of deciduous trees or mixed stands, featuring a thick layer of decomposing litter", "terrestrial"),
    (12, "forest-boreal_forest","#1e4a2a", "A vast belt of conifers adapted to cold climates, with acidic soil and reduced species biodiversity", "terrestrial"),
    (13, "forest-tropical_forest","#1a5a10", "A high-density vegetation ecosystem characterized by a closed canopy and multiple vegetation layers. Humidity is saturated", "terrestrial"),
    (14, "forest-dead_forest", "#5c4a3a", "Tree stand that has lost its biological viability. The woody structures survive as charred or mineralized skeletons", "terrestrial"),
    # (15 removed — was jungle, deleted)
    (16, "wetland-swamp",     "#4a6741", "A wooded or grassy wetland where stagnant water permanently saturates the soil. Characterized by fine sedimentation and high bacterial activity", "terrestrial"),
    (17, "wetland-mangrove",  "#3a5a30", "An amphibious coastal forest located in tropical zones. The trees have roots adapted to high salinity and muddy soil", "terrestrial"),
    (18, "wetland-bog",       "#5a6a4a", "A wet, acidic ecosystem that accumulates undecomposed organic matter (peat). Growth is dominated by sphagnum mosses, creating a spongy soil capable of trapping significant amounts of carbon", "terrestrial"),
    (19, "icy-tundra",        "#8fa8b5", "Polar biome defined by the absence of trees and the presence of frozen ground. Vegetation is limited to mosses, lichens, and dwarf shrubs", "terrestrial"),
    (20, "icy-snow",           "#e8eaed", "Permanent blankets of snow ice that increase in density until they become firn ice", "terrestrial"),
    (21, "icy-glacier",        "#c8e0f0", "Continental ice mass resulting from the crystallization of snow. Under the effect of its own weight, the ice behaves like a viscous fluid, flowing and sculpting valleys", "terrestrial"),
    (22, "rocky_landform-raw_mountain", "#7a7a7a", "A high-altitude summit or slope located above the lichen growth limit. The landscape is dominated by exposed bedrock", "terrestrial"),
    (23, "rocky_landform-alpine_mountain", "#6a8a5a", "A mountain zone located between the tree line and the permanent snow line. Characterized by short grasslands (alpine meadows) and flora adapted to intense UV radiation and strong winds", "terrestrial"),
    (24, "rocky_landform-cliff", "#6e6e6e", "Rocky escarpment with a near-vertical slope resulting from tectonic processes or erosion", "terrestrial"),
    (25, "rocky_landform-canyon", "#8a5a3a", "Deep gorge with steep walls carved by linear erosion of a watercourse in horizontal sedimentary strata", "terrestrial"),
    (26, "volcanic_geothermal-active_volcano", "#4a2c2a", "A geological formation in the process of eruption or exhibiting significant internal magmatic activity. Characterized by emissions of tephra, gas and heat", "volcanic"),
    (27, "volcanic_geothermal-volcanic_basalt", "#2a2a2a", "A plain of dense, dark, extrusive igneous rock. Rapid surface cooling creates a fine-grained rock, often structured into vast plateaus", "volcanic"),
    (28, "volcanic_geothermal-lava_field", "#1a0a0a", "Extent of solidified lava exhibiting varied surface morphologies", "volcanic"),
    (29, "volcanic_geothermal-lava_lake", "#cc3300", "A depression filled with liquid magma, kept molten by thermal convection. A semi-solid crust can form on the surface, constantly fractured by magma currents", "volcanic"),
    (30, "volcanic_geothermal-fumarole", "#8a7a5a", "Volcanic gas emanation escaping from fissures. Composed mainly of water vapor, CO2 and sulfur compounds which often precipitate around the vent in the form of crystal", "volcanic"),
    (31, "volcanic_geothermal-geothermal", "#6a8a6a", "A surface hydrothermal system comprising hot springs and pools saturated with dissolved minerals. The interaction between water and heat creates deposits and geysers", "volcanic"),
    (32, "volcanic_geothermal-obsidian_field", "#0a0a1a", "A rapidly cooled lava flow that did not crystallize, forming a sharp, black volcanic glass", "volcanic"),
    (33, "volcanic_geothermal-ash_desert", "#4a4a4a", "A thick layer of ash deposited after an explosive eruption. The landscape is monochrome, arid, and the soil is very loose", "volcanic"),
    (34, "volcanic_geothermal-magmatic_crust", "#3a1a0a", "An unstable zone where a thin layer of solidified rock covers a shallow magma reservoir. It exhibits extremely high surface heat flow and risks of collapse", "volcanic"),
    # (35 removed — was regolith, merged into spatial-lunar_ground)
    (36, "spatial-crater",    "#808070", "Circular structure resulting from a meteorite impact. It consists of a central depression, a raised rim and a radial ejecta field", "barren"),
    # (37 removed — was crater_rim, now merged into spatial-crater)
    (38, "spatial-lunar_ground", "#aaaaaa", "Loose dusty surface with heavily cratered bright terrain, lunar regolith covering", "barren"),
    (39, "spatial-lunar_pool", "#4a4a5a", "Vast plains of dark basalt occupying giant impact basins. Unlike the highlands, the lunar seas are smoother and have few large craters", "barren"),
    # (40 removed — was ejecta_field, deleted)
    # (41 removed — was boulder_field, deleted)
    (42, "aride_desert-dusty_plain", "#b0a890", "Low-lying area covered with very fine particles (silt, clay). Susceptible to dust storms", "barren"),
    (43, "icy-ice_plain",      "#d0e8f0", "A flat expanse of massive ice. The albedo is very high, resulting in almost total reflection of stellar radiation", "cryo"),
    (44, "icy-ice_crevasse",   "#90b8d0", "A deep structural rupture within a glacial body or thick ice pack. The walls are vertical and reveal the stratification of the ice", "cryo"),
    (45, "icy-ice_pick",       "#c0d8e8", "The formation of ice and hardened snow blades or needles. These structures, which can reach several meters in height, result from a sublimation process of intense solar radiation in very dry and cold air. They create a sharp, mineral labyrinth", "cryo"),
    (46, "icy-nitrogen_ice",   "#e0e8f0", "A plain composed of solidified nitrogen, stable only at extremely low temperatures. Nitrogen ice behaves in a ductile manner, allowing internal convection currents and surface regeneration that erases impact craters", "cryo"),
    (47, "icy-methane_lake",  "#2a4a6a", "A liquid basin composed of a mixture of light hydrocarbons, primarily methane and ethane. Stable under cryogenic pressure and temperature conditions. The liquid has very low viscosity and surface tension, resulting in extremely slow and faint waves. Shorelines are sculpted by the erosion of hydrocarbons on a base of rock-hard water ice", "cryo"),
    (48, "icy-hydrocarbon_dune", "#5a4a3a", "Hydrocarbon sand dunes (Titan)", "cryo"),
    (49, "icy-cryovolcanic",  "#b0c8d8", "A geological formation found in cold worlds where magma is replaced by volatiles (water, ammonia, methane) in a liquid state. Eruptions occur when internal pressure forces these liquids through the icy crust, solidifying instantly upon contact with the atmosphere or a vacuum, creating domes of molten ice", "cryo"),
    (50, "icy-frozen_ocean",   "#8ab0c8", "A thick ice pack of water ice overlying a liquid ocean maintained by tidal heating or thermal insulation", "cryo"),
    (51, "icy-sublimation_pit", "#c8d8e0", "A rugged terrain formed by the direct transition of CO2 ice from a solid to a gaseous state under the effect of solar radiation, creating irregular depressions", "cryo"),
    (52, "icy-permafrost",     "#8a9a8a", "Soil whose temperature remains below 0 degrees C for years. Structured soils (frost polygons) are often found there, resulting from freeze-thaw cycles", "cryo"),
    (53, "volcanic_geothermal-ice_geyser", "#d8e8f8", "A cryovolcanic phenomenon where plumes of water vapor, nitrogen, or methane are expelled from the depths", "cryo"),
    (54, "aride_desert-iron_desert", "#c0603a", "A biome whose characteristic red color comes from the oxidation of iron dust. The atmosphere there is often thin and rich in dust", "martian"),
    # (55 removed — was dust_storm, deleted)
    (56, "aride_desert-dry_river_bed", "#8a7a5a", "A former dried-up channel. The soil is composed of rounded pebbles and stratified sediments", "martian"),
    # (57 removed — was polar_cap, deleted)
    # (58 removed — was ventifact, deleted)
    # (59 removed — was cloud_deck, deleted)
    # (60 removed — was acid_rain, deleted)
    (61, "rocky_landform-pressure_canyon", "#4a3a2a", "A deep rift where atmospheric pressure is higher than at the surface. Temperature increases with depth", "atmosphere"),
    (62, "liquid_hydrocarbon_areas", "#3a5a7a", "Surface liquid at extreme pressure/temperature", "atmosphere"),
    (63, "meadow_steppe-sulfur_plain", "#c8c030", "Yellowish expanses reminiscent of the moon Io. The ground is covered in elemental sulfur and solid sulfur dioxide", "toxic"),
    (64, "volcanic_geothermal-sulfur_volcano", "#b8a020", "Unlike terrestrial silicate volcanoes, these spew molten sulfur whose color changes according to the temperature (from yellow to black through blood red)", "toxic"),
    (65, "maritime_river-acid_lake", "#80a030", "Basins filled with a mixture of water and strong acids (sulfuric or hydrochloric), often located near volcanic areas", "toxic"),
    (66, "wetland-ammonia_swamp", "#6080a0", "Humid areas where the main solvent is not pure water but a water-ammonia mixture. The ammonia acts as an antifreeze, allowing the liquid to exist at temperatures well below 0\u00b0C", "toxic"),
    (67, "meadow_steppe-chlorinated_field", "#80c060", "Salt deserts composed of halides (such as sodium or potassium chloride). These plains are often the result of the complete evaporation of ancient salt seas", "toxic"),
    (68, "radioactive_waste",  "#50a050", "Irradiated contaminated zone",          "toxic"),
    (69, "tar_basin",           "#1a1a1a", "Depressions filled with heavy hydrocarbons (bitumen, asphalt). These basins are formidable natural traps", "toxic"),
    (70, "brine_basin",        "#4a7a7a", "Submarine or surface lakes with such high salinity that the liquid becomes much denser than the surrounding water. These areas are often devoid of oxygen", "toxic"),
    (71, "crystalline-crystalline_fields", "#a0c0e0", "Areas covered with macro-crystals (quartz, selenite or fluorite). These formations are generally created in giant hydrothermal cavities whose roof has been eroded, exposing perfect geometric structures", "mineral"),
    (72, "aride_desert-metal_plain", "#8a8a9a", "A biome whose surface is composed of native metals (iron, nickel or copper) or minerals with a metallic luster (pyrite, magnetite)", "mineral"),
    (73, "rocky_landform-cave", "#7050a0", "A natural underground network. Depending on the planet, it may be adorned with ice stalactites, limestone, or even exotic crystals", "mineral"),
    (74, "crystalline-quartz_desert", "#d0c8b8", "Arid expanse composed of pure silica grains. Unlike classic silica sand, the surface has a vitreous and semi-translucent appearance", "mineral"),
    (75, "volcanic_geothermal-mineral_thermal_source", "#50b0a0", "A hydrothermal water basin saturated with dissolved minerals. The cooling of the water at the surface leads to the formation of travertine terraces or siliceous frits. The basins are often vividly colored", "mineral"),
    (76, "crystalline-salt_crystal_field", "#e0d8c8", "Massive sedimentary deposit of halites. The biome is characterized by natural cubic formations and hopper-like structures rising from the ground", "mineral"),
    (77, "meadow_steppe-terraformed_grass", "#60c040", "Artificial grassland ecosystem whose parameters have been modified to match a specific biological standard", "artificial"),
    (78, "forest-terraformed_forest", "#208020", "Artificial planted forest cover on previously treated soil", "artificial"),
    (79, "urban-mining_excavation", "#5a4a3a", "Open-pit industrial excavation for mineral resource extraction. Features a stepped topography", "artificial"),
    (80, "urban-ruins",       "#6a6060", "Urban or industrial complex in a state of advanced structural degradation", "artificial"),
    (81, "urban-urban",        "#707070", "High-density surface of artificial structures and integrated infrastructure. The natural ground is completely sealed by synthetic or metallic coatings", "artificial"),
    (82, "meadow_steppe-agriculture_land", "#a0c040", "Industrial agricultural production zone. Characterized by a geometric sectorization of the land", "artificial"),
    (83, "urban-landing_pad",  "#505050", "Stabilized and reinforced platform designed to withstand the thermal and mechanical stresses of spacecraft propulsion systems", "artificial"),
    (84, "meadow_steppe-wasteland_irradiated","#4a5a3a","Environmental wasteland with high residual radiological contamination", "artificial"),
    (85, "maritime_river-river", "#2471a3", "A permanent watercourse flowing in a defined natural channel, fed by surface or underground sources, permanently carrying water over a significant distance", "terrestrial"),
    (86, "volcanic_geothermal-lava_river", "#cc5000", "An active flow channel transporting molten rock (extrusive magma). Unlike a stationary lava field, a river is characterized by a defined flow velocity", "volcanic"),
    (87, "rocky_landform-mining_cave", "#8a6a4a", "An artificial or natural cavity modified for mineral extraction. It is distinguished by fractured walls and supporting structures", "artificial"),
    (88, "volcanic_geothermal-columnar_basalt_vertical", "#3d3d4a", "Composed of prisms of cooled lava and basaltic volcanic columns, these structures exhibit strict geometric regularity", "volcanic"),
    (89, "aride_desert-anhydrite_desert", "#c8bfb0", "Composed of dehydrated calcium sulfate. These are white or greyish expanses, formed of hard mineral plates, often resulting from the evaporation of ancient marine basins", "terrestrial"),
    (90, "aride_desert-valley_of_fire", "#b85a3a", "Ancient sand dune, composed of Aztec sandstone", "terrestrial"),
    (91, "aride_desert-corundum_plateau", "#8a7080", "High plateaus of extremely hard rock. The walls are sharp and virtually unaffected by conventional erosion", "terrestrial"),
    (92, "aride_desert-corundum_sand_desert", "#b07888", "Expanses where the ground is littered with fragments of raw sapphires or rubies, ranging from fine grains of sand to angular gravel, creating crystalline reflections under the starlight", "terrestrial"),
    (93, "rocky_landform-arachnoide", "#6a5a50", "Radial fracture extending beyond the circular fracture", "terrestrial"),
    (94, "volcanic_geothermal-lava_dome", "#8a3020", "A mass of lava whose high viscosity prevents it from flowing", "volcanic"),
    (95, "rocky_landform-perforated_limestone", "#c8b898", "(beware of trypophobia) composed of perforated limestone", "terrestrial"),
    (96, "volcanic_geothermal-pele_haire", "#8a6a20", "Capillary obsidian: wind-borne lava projection in the form of filaments", "volcanic"),
    (97, "icy-frozen_methane", "#d0dae8", "Frozen methane takes the form of soap. This can produce masses of ice", "cryo"),
]

# ─── Layer group assignment ───────────────────────────────────────
BIOME_LAYER_GROUP = {
    "maritime_river-ocean": "individual", "maritime_river-lake": "individual",
    "maritime_river-delta": "individual", "maritime_river-beach": "individual",
    "aride_desert-sandy_desert": "individual",
    "aride_desert-rocky_desert": "individual",
    "aride_desert-salt_desert": "individual",
    "meadow_steppe-meadow": "individual",
    "meadow_steppe-savanna": "individual",
    "meadow_steppe-steppe": "individual",
    "forest-temperate_forest": "individual",
    "forest-boreal_forest": "individual",
    "forest-tropical_forest": "individual",
    "forest-dead_forest": "individual",
    "wetland-swamp": "individual",
    "wetland-mangrove": "individual",
    "wetland-bog": "individual",
    "icy-tundra": "individual",
    "icy-snow": "individual",
    "icy-glacier": "individual",
    "rocky_landform-raw_mountain": "individual",
    "rocky_landform-alpine_mountain": "individual",
    "rocky_landform-cliff": "individual",
    "volcanic_geothermal-lava_lake": "individual", "methane_lake": "liquid",  # legacy, now individual
    "icy-methane_lake": "individual",
    "icy-hydrocarbon_dune": "individual",
    "icy-cryovolcanic": "individual",
    "frozen_ocean": "liquid", "supercritical_fluid": "liquid",  # legacy, now individual
    "icy-frozen_ocean": "individual",
    "icy-sublimation_pit": "individual",
    "icy-permafrost": "individual",
    "aride_desert-iron_desert": "individual",
    "aride_desert-anhydrite_desert": "individual",
    "aride_desert-valley_of_fire": "individual",
    "aride_desert-corundum_plateau": "individual",
    "aride_desert-corundum_sand_desert": "individual",
    "rocky_landform-arachnoide": "individual",
    "rocky_landform-perforated_limestone": "individual",
    "volcanic_geothermal-lava_dome": "individual",
    "volcanic_geothermal-pele_haire": "individual",
    "icy-frozen_methane": "individual",
    "liquid_hydrocarbon_areas": "individual",
    "acid_lake": "liquid",  # legacy, now individual
    "maritime_river-acid_lake": "individual",
    "ammonia_marsh": "liquid",  # legacy, now individual
    "wetland-ammonia_swamp": "individual",
    "chlorine_flat": "terrain",  # legacy, now individual
    "meadow_steppe-chlorinated_field": "individual",
    "radioactive_waste": "individual",
    "tar_pit": "liquid",  # legacy, now individual
    "tar_basin": "individual",
    "brine_pool": "liquid",  # legacy, now individual
    "brine_basin": "individual",
    "crystal_field": "terrain",  # legacy, now individual
    "crystalline-crystalline_fields": "individual",
    "metal_plain": "terrain",  # legacy, now individual
    "aride_desert-metal_plain": "individual",
    "rocky_landform-mining_cave": "individual",
    "icy-nitrogen_ice": "individual",
    # vegetation
    # "forest-temperate_forest" is now "individual" (see above)
    # "forest-boreal_forest" is now "individual" (see above)
    # "forest-tropical_forest" is now "individual" (see above)
    # "forest-dead_forest" is now "individual" (see above)
    # "jungle" has been deleted
    # "wetland-swamp" is now "individual" (see above)
    # "wetland-mangrove" is now "individual" (see above)
    #"mangrove": "vegetation",
    # "wetland-bog" is now "individual" (see above)
    #"bog": "vegetation",
    "terraformed_grass": "vegetation",  # legacy, now individual
    "meadow_steppe-terraformed_grass": "individual",
    "terraformed_forest": "vegetation",  # legacy, now individual
    "forest-terraformed_forest": "individual", "mining_excavation": "terrain",  # legacy, now individual
    "urban-mining_excavation": "individual", "ruins": "terrain",  # legacy, now individual
    "urban-ruins": "individual", "urban": "terrain",  # legacy, now individual
    "urban-urban": "individual", "agriculture": "vegetation",  # legacy, now individual
    "meadow_steppe-agriculture_land": "individual",
    "landing_pad": "terrain",  # legacy, now individual
    "urban-landing_pad": "individual",
    "wasteland_irradiated": "terrain",  # legacy, now individual
    "meadow_steppe-wasteland_irradiated": "individual",
    # linear
    # "rocky_landform-canyon" is now "individual" (migrated)
    "river": "linear",  # legacy, now individual
    "maritime_river-river": "individual",
    "icy-ice_crevasse": "individual",
    "dry_riverbed": "linear",  # legacy, now individual
    "aride_desert-dry_river_bed": "individual",
    "pressure_canyon": "linear",  # legacy, now individual
    "rocky_landform-pressure_canyon": "individual",
    "sulfur_plain": "terrain",  # legacy, now individual
    "meadow_steppe-sulfur_plain": "individual",
    "sulfur_volcano": "terrain",  # legacy, now individual
    "volcanic_geothermal-sulfur_volcano": "individual",
    "lava_river": "linear",  # legacy, now individual
    "volcanic_geothermal-lava_river": "individual",
    # point
    "volcanic_geothermal-fumarole": "individual",
    "volcanic_geothermal-geothermal": "individual",
    "volcanic_geothermal-obsidian_field": "individual",
    "volcanic_geothermal-ash_desert": "individual",
    "volcanic_geothermal-magmatic_crust": "individual",
    "volcanic_geothermal-columnar_basalt_vertical": "individual",
    "spatial-crater": "individual",
    "spatial-lunar_ground": "individual",
    "spatial-lunar_pool": "individual",
    "aride_desert-dusty_plain": "individual",
    "icy-ice_plain": "individual",
    "icy-ice_crevasse": "individual",
    "icy-ice_pick": "individual",
    "ice_geyser": "point",  # legacy, now individual
    "volcanic_geothermal-ice_geyser": "individual",
    "mineral_hot_spring": "point",  # legacy, now individual
    "volcanic_geothermal-mineral_thermal_source": "individual",
    "gemstone_cave": "point",  # legacy, now individual
    "rocky_landform-cave": "individual",
    "quartz_desert": "terrain",  # legacy, now individual
    "crystalline-quartz_desert": "individual",
    "salt_crystal_field": "terrain",  # legacy, now individual
    "crystalline-salt_crystal_field": "individual",
}
for _, bt, _, _, _ in BIOME_CATALOGUE:
    if bt not in BIOME_LAYER_GROUP:
        BIOME_LAYER_GROUP[bt] = "terrain"

# ─── Folders that already exist (hand-written modules) ────────────
EXISTING_FOLDERS = {
    "rocky_landform_canyon", "volcanic_geothermal-active_volcano",
    "volcanic_geothermal_volcanic_basalt",
    "volcanic_geothermal_lava_field",
    "volcanic_geothermal_lava_lake",
    "volcanic_geothermal_fumarole",
    "volcanic_geothermal_geothermal",
    "volcanic_geothermal_obsidian_field",
    "volcanic_geothermal_ash_desert",
    "volcanic_geothermal_magmatic_crust",
    "spatial_crater",
    "spatial_lunar_ground",
    "spatial_lunar_pool",
    "aride_desert_dusty_plain",
    "icy_ice_plain",
    "icy_ice_crevasse",
    "icy_ice_pick",
    "icy_nitrogen_ice",
    "icy_methane_lake",
    "icy_hydrocarbon_dune",
    "liquid_hydrocarbon_areas",
    "icy_cryovolcanic",
    "icy_frozen_ocean",
    "icy_sublimation_pit",
    "icy_permafrost",
    "volcanic_geothermal_ice_geyser",
    "aride_desert_iron_desert",
    "river", "aride_desert_dry_river_bed", "rocky_landform_pressure_canyon",
    "meadow_steppe_sulfur_plain",
    "volcanic_geothermal_sulfur_volcano",
    "maritime_river_acid_lake",
    "wetland_ammonia_swamp",
    "meadow_steppe_chlorinated_field",
    "radioactive_waste",
    "tar_basin",
    "brine_basin",
    "crystalline_crystalline_fields",
    "aride_desert_metal_plain",
    "rocky_landform_mining_cave",
    "crystalline_quartz_desert",
    "volcanic_geothermal_mineral_thermal_source",
    "crystalline_salt_crystal_field",
    "meadow_steppe_terraformed_grass",
    "forest_terraformed_forest",
    "urban_mining_excavation",
    "urban_ruins",
    "urban_urban",
    "meadow_steppe_agriculture_land",
    "urban_landing_pad",
    "meadow_steppe_wasteland_irradiated",
    "maritime_river_river",
    "volcanic_geothermal_lava_river",
    "volcanic_geothermal_columnar_basalt_vertical",
    "aride_desert_anhydrite_desert",
    "aride_desert_valley_of_fire",
    "aride_desert_corundum_plateau",
    "aride_desert_corundum_sand_desert",
    "rocky_landform_arachnoide",
    "rocky_landform_perforated_limestone",
    "volcanic_geothermal_lava_dome",
    "volcanic_geothermal_pele_haire",
    "icy_frozen_methane",
    "gemstone_cave",  # legacy name, lives in cave/ folder
    "rocky_landform_cave",  # lives in cave/ folder
}
# gemstone_cave / rocky_landform_cave → cave/ (special mapping)
FOLDER_ALIAS = {"gemstone_cave": "cave", "rocky_landform_cave": "cave"}

# ─── Vegetation defaults per biome ────────────────────────────────
VEG_DEFAULTS = {
    "forest-temperate_forest":  (0.8, "deciduous"),
    "forest-boreal_forest":    (0.7, "conifer"),
    "forest-tropical_forest":  (0.9, "tropical"),
    "forest-dead_forest":     (0.3, "dead"),
    # "jungle" has been deleted
    "wetland-swamp":     (0.4, "marsh"),
    "wetland-mangrove":  (0.6, "mangrove"),
    "wetland-bog":       (0.3, "moss"),
    "meadow_steppe-terraformed_grass": (0.5, "grass"),
    "forest-terraformed_forest":(0.7, "deciduous"),
    "meadow_steppe-agriculture_land": (0.8, "crop"),
}

# ─── Liquid defaults per biome (depth in metres) ─────────────────
LIQUID_DEFAULTS = {
    "maritime_river-ocean":  100.0,
    "maritime_river-lake":  30.0,
    "maritime_river-delta":  5.0,
    "volcanic_geothermal-lava_lake": 50.0,
    "icy-methane_lake":    40.0,
    "methane_lake":        40.0,   # legacy alias
    "icy-frozen_ocean":    80.0,
    "frozen_ocean":        80.0,   # legacy alias
    "liquid_hydrocarbon_areas": 60.0,
    "supercritical_fluid": 60.0,   # legacy alias
    "maritime_river-acid_lake": 25.0,
    "acid_lake":           25.0,   # legacy alias
    "wetland-ammonia_swamp":  8.0,
    "ammonia_marsh":        8.0,   # legacy alias
    "tar_basin":           15.0,
    "tar_pit":             15.0,   # legacy alias
    "brine_basin":         20.0,
    "brine_pool":          20.0,   # legacy alias
    "icy-nitrogen_ice":    10.0,
}


def to_class_name(biome_type: str) -> str:
    """Convert 'aride_desert-sandy_desert' → 'ArideDesertSandyDesertTerrain'."""
    return "".join(w.capitalize() for w in biome_type.split("_")) + "Terrain"


def generate_terrain_module(idx, biome_type, color_hex, desc, category) -> str:
    """Return the full GDScript content for one *_terrain.gd."""
    group = BIOME_LAYER_GROUP[biome_type]
    cls = to_class_name(biome_type)

    lines = []
    lines.append("@tool")
    lines.append(f"class_name {cls}")

    # Doc comment
    if group == "terrain":
        lines.append(f"## Terrain module for the **{biome_type}** biome.")
        lines.append(f"##")
        lines.append(f"## {desc}.")
        lines.append(f"## Category: {category}.  Layer group: terrain (polygon).")
        lines.append(f"## This module provides identification constants so that game systems")
        lines.append(f"## can recognise the biome without hard-coding strings everywhere.")
    elif group == "vegetation":
        lines.append(f"## Terrain module for the **{biome_type}** vegetation biome.")
        lines.append(f"##")
        lines.append(f"## {desc}.")
        lines.append(f"## Category: {category}.  Layer group: vegetation (polygon).")
        lines.append(f"## Includes default vegetation density and tree-type constants")
        lines.append(f"## used by PlanetVegetation when no per-feature override exists.")
    elif group == "liquid":
        lines.append(f"## Terrain module for the **{biome_type}** liquid biome.")
        lines.append(f"##")
        lines.append(f"## {desc}.")
        lines.append(f"## Category: {category}.  Layer group: liquid (polygon).")
        lines.append(f"## Includes a default depth constant used by PlanetChunk when the")
        lines.append(f"## QGIS feature has no explicit depth value.")

    lines.append("")
    lines.append("# ── Constants ──────────────────────────────────────────────────────")
    lines.append("")
    lines.append(f'## Biome type string as defined in the QGIS catalogue.')
    lines.append(f'const BIOME_TYPE := "{biome_type}"')
    lines.append(f'## Biome index in the catalogue (0-based).')
    lines.append(f'const BIOME_INDEX := {idx}')
    lines.append(f'## Category tag for grouping.')
    lines.append(f'const CATEGORY := "{category}"')

    # Group-specific constants
    if group == "vegetation":
        density, tree = VEG_DEFAULTS.get(biome_type, (0.5, "none"))
        lines.append(f"## Default vegetation density when the QGIS feature has no override.")
        lines.append(f"const DEFAULT_VEGETATION_DENSITY := {density}")
        lines.append(f'## Default tree type for VegetationRule matching.')
        lines.append(f'const DEFAULT_TREE_TYPE := "{tree}"')

    elif group == "liquid":
        depth = LIQUID_DEFAULTS.get(biome_type, 30.0)
        lines.append(f"## Default liquid depth when the QGIS feature has no depth value (metres).")
        lines.append(f"const DEFAULT_DEPTH_M := {depth}")

    lines.append("")
    lines.append("")
    lines.append("# ── Detection helpers ──────────────────────────────────────────────")
    lines.append("")

    # matches_zone
    lines.append(f"## Returns [code]true[/code] if the biome definition is a {biome_type}.")
    lines.append(f"static func matches_zone(bd: BiomeDefinition) -> bool:")
    lines.append(f'\treturn bd != null and bd.biome_type == BIOME_TYPE')

    return "\n".join(lines) + "\n"


# ─── Main ─────────────────────────────────────────────────────────
created = 0
skipped = 0

for idx, biome_type, color_hex, desc, category in BIOME_CATALOGUE:
    if biome_type in EXISTING_FOLDERS:
        skipped += 1
        continue

    folder_name = FOLDER_ALIAS.get(biome_type, biome_type)
    folder_path = os.path.join(BASE, folder_name)
    file_name = f"{folder_name}_terrain.gd"
    file_path = os.path.join(folder_path, file_name)

    if os.path.exists(file_path):
        skipped += 1
        continue

    os.makedirs(folder_path, exist_ok=True)
    content = generate_terrain_module(idx, biome_type, color_hex, desc, category)
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(content)
    created += 1
    print(f"  ✓ {folder_name}/{file_name}")

print(f"\nDone: {created} created, {skipped} skipped (already exist)")
