@tool
class_name BiomeDefinition
extends Resource
## Defines a single biome type with all its visual and gameplay properties.
##
## Each planet's [PlanetData] holds an array of BiomeDefinition resources.
## The terrain system uses [member biome_index] to match against biomemap
## pixels or GeoJSON polygon zones exported from QGIS, then applies the
## biome's material, colour, vegetation, and audio properties.

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
## Unique string identifier matching the QGIS biome_type field.
## e.g. "maritime_river-ocean", "aride_desert-sandy_desert", "forest-boreal_forest", "spatial-lunar_ground"
@export var biome_type: String = ""

## Numeric index matching the QGIS biome_index (0–84).
@export var biome_index: int = -1

## Human-readable display name (e.g. "Sandy Desert").
@export var display_name: String = ""

## Short description for UI tooltips / planet survey.
@export_multiline var description: String = ""

## Category tag for filtering. e.g. "terrestrial", "volcanic", "cryo"
@export_enum(
	"terrestrial", "volcanic", "barren", "cryo",
	"martian", "atmosphere", "toxic", "mineral", "artificial"
) var category: String = "terrestrial"

# ---------------------------------------------------------------------------
# Visual
# ---------------------------------------------------------------------------
## Dominant colour used for far-LOD rendering and minimap.
## Should match the color_hex from QGIS export.
@export var color: Color = Color.BLACK

## Optional override material for terrain chunks inside this biome.
## If null, the planet-wide [member PlanetData.terrain_material] is used.
@export var terrain_material_override: Material

## Optional detail texture tiled over the terrain in this biome
## (e.g. sand ripples, grass blades, rock cracks).
@export var detail_texture: Texture2D

## Detail texture tiling scale (higher = more repetitions per chunk).
@export var detail_texture_scale: float = 1.0

# ---------------------------------------------------------------------------
# Terrain properties
# ---------------------------------------------------------------------------
## If true, this biome is considered a liquid surface (ocean, lake, lava_lake…).
@export var is_liquid: bool = false

## If true, a thin translucent water sheet is placed over the terrain without
## depressing the ground.  Used for swamps, bogs, marshes — biomes that have
## shallow standing water but where the terrain is still visible underneath.
@export var has_shallow_water: bool = false

## Material for the shallow-water overlay (only used when has_shallow_water is true).
## Should be a semi-transparent ShaderMaterial (e.g. swamp_water.tres).
@export var shallow_water_material: Material

## Typical elevation range where this biome appears (meters above sea level).
## Used by procedural placement and validation — not a hard constraint.
@export var elevation_min: float = 0.0
@export var elevation_max: float = 10000.0

## Terrain roughness multiplier. 1.0 = use heightmap as-is.
## <1 smooths (ice, sand dunes), >1 exaggerates (mountains, cliffs).
@export_range(0.0, 3.0, 0.01) var terrain_roughness: float = 1.0

# ---------------------------------------------------------------------------
# Vegetation
# ---------------------------------------------------------------------------
## Whether this biome can have vegetation at all.
@export var supports_vegetation: bool = false

## Default vegetation density (0–1). Overridden by QGIS polygon density.
@export_range(0.0, 1.0, 0.01) var default_vegetation_density: float = 0.0

## Suggested tree type string for VegetationRule matching.
## e.g. "conifer", "deciduous", "palm", "cactus", "mushroom", "none"
@export var default_tree_type: String = "none"

# ---------------------------------------------------------------------------
# Audio / Ambience
# ---------------------------------------------------------------------------
## Ambient sound to play when the player is standing in this biome.
@export var ambient_sound: AudioStream

## Wind strength multiplier (affects particle effects, sound).
@export_range(0.0, 3.0, 0.01) var wind_strength: float = 1.0

# ---------------------------------------------------------------------------
# Gameplay
# ---------------------------------------------------------------------------
## Movement speed multiplier when walking on this biome (1.0 = normal).
@export_range(0.1, 2.0, 0.01) var movement_speed_factor: float = 1.0

## Damage per second to the player while on this biome (0 = safe).
@export var damage_per_second: float = 0.0

## Whether vehicles can traverse this biome.
@export var vehicle_traversable: bool = true


## Helper: create a Color from the hex string stored in QGIS exports.
static func color_from_hex(hex: String) -> Color:
	return Color(hex)
