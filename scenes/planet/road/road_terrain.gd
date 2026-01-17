@tool
class_name RoadTerrain
## Terrain module for the **road** overlay system.
##
## Roads are exported from QGIS as LineStrings buffered into polygons
## (with the original centerline preserved in properties).  They are
## stored in a separate GeoJSON file (roads_geojson on PlanetData) and
## loaded by a dedicated BiomeQuery instance.
##
## Unlike biome overlays, roads do NOT depress the terrain.  They are
## flat texture overlays sitting slightly above the ground to avoid
## z-fighting, using flow-aligned UVs so the texture follows the road
## direction.
##
## The material used depends on road_type × biome crossed:
##   • highway / road  → always asphalt (fixed texture)
##   • path / trail    → biome-adaptive (path_grass in meadow_steppe-meadow,
##                        path_dirt on rock, etc.)

# ── Road type constants ──────────────────────────────────────────────

## Half-widths per road_type in metres.
## These match the QGIS auto-fill defaults in setup_planet_project.py.
const HALF_WIDTH_M := {
	"highway": 6.0,   # 12 m total
	"road":    3.0,   # 6 m total
	"path":    1.0,   # 2 m total
	"trail":   0.5,   # 1 m total
}

## Detection polygon is wider than the visual road so chunk-level sampling
## reliably catches narrow roads.  This multiplier is applied to the
## half-width when building the detection polygon in the export script.
const DETECTION_MULTIPLIER := 3.0

## Texture tile size in metres per road type.
## Roads tile more tightly than natural features.
const TILE_M := {
	"highway": 8.0,
	"road":    6.0,
	"path":    3.0,
	"trail":   2.0,
}

## Small offset above terrain (metres) to prevent z-fighting.
const SURFACE_OFFSET := 0.05

## Road types that always use asphalt regardless of biome.
const FIXED_MATERIAL_TYPES: PackedStringArray = ["highway", "road"]

## Road types that adapt their material to the underlying biome.
const ADAPTIVE_MATERIAL_TYPES: PackedStringArray = ["path", "trail"]


# ── Material paths ───────────────────────────────────────────────────

## Fixed materials for highway/road.
const ASPHALT_MATERIAL_PATH := "res://assets/materials/planet/path_asphalt.tres"

## Biome-adaptive material mapping:  biome_type → .tres path.
## For path/trail road types, the material is selected based on the
## biome the road segment crosses.
const ADAPTIVE_MATERIAL_MAP := {
	"meadow_steppe-meadow": "res://assets/materials/planet/path_grass.tres",
	"meadow_steppe-savanna": "res://assets/materials/planet/path_grass.tres",
	"meadow_steppe-steppe": "res://assets/materials/planet/path_grass.tres",
	"meadow_steppe-terraformed_grass": "res://assets/materials/planet/path_grass.tres",
	"forest-temperate_forest": "res://assets/materials/planet/path_dirt.tres",
	"forest-boreal_forest": "res://assets/materials/planet/path_dirt.tres",
	"forest-tropical_forest": "res://assets/materials/planet/path_dirt.tres",
	"forest-dead_forest": "res://assets/materials/planet/path_dirt.tres",
	"aride_desert-sandy_desert": "res://assets/materials/planet/path_sand.tres",
	"aride_desert-rocky_desert": "res://assets/materials/planet/path_dirt.tres",
	"icy-snow":          "res://assets/materials/planet/path_snow.tres",
	"icy-tundra":        "res://assets/materials/planet/path_dirt.tres",
}

## Fallback material when no biome match is found for adaptive types.
const FALLBACK_MATERIAL_PATH := "res://assets/materials/planet/path_dirt.tres"


# ── Detection helpers ──────────────────────────────────────────────

## Returns the road_type property from a road zone dictionary,
## defaulting to "trail" if not set.
static func get_road_type(zone: Dictionary) -> String:
	var rt: String = zone.get("road_type", "trail")
	if rt.is_empty():
		rt = "trail"
	return rt


## Returns [code]true[/code] if this zone describes a valid road
## (has a centerline with ≥ 2 points).
static func is_road_zone(zone: Dictionary) -> bool:
	var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
	return cl.size() >= 2


## Convert the road half-width from metres to degrees and cache it
## in the zone dictionary so BiomeQuery.get_cross_section_t() can use it.
static func prepare_zone(zone: Dictionary, planet_radius: float) -> void:
	if not zone.get("_road_hw_converted", false):
		var m_per_deg := planet_radius * PI / 180.0
		var rt := get_road_type(zone)
		var hw_m: float = HALF_WIDTH_M.get(rt, 0.5)
		zone["half_width_deg"] = hw_m / m_per_deg
		zone["_road_hw_converted"] = true


## Get the half-width in metres for a road type.
static func get_half_width(road_type: String) -> float:
	return HALF_WIDTH_M.get(road_type, 0.5)


## Get the tile size in metres for a road type.
static func get_tile_size(road_type: String) -> float:
	return TILE_M.get(road_type, 2.0)


## Returns [code]true[/code] if this road type uses a fixed material
## (asphalt) regardless of biome.
static func is_fixed_material(road_type: String) -> bool:
	return road_type in FIXED_MATERIAL_TYPES


## Get the material path for a road segment.
## [param road_type] — "highway", "road", "path", or "trail"
## [param biome_type] — the biome_type of the terrain under this segment
##                       (only used for adaptive road types)
static func get_material_path(road_type: String, biome_type: String = "") -> String:
	if is_fixed_material(road_type):
		return ASPHALT_MATERIAL_PATH
	# Adaptive: look up biome → path material.
	if ADAPTIVE_MATERIAL_MAP.has(biome_type):
		return ADAPTIVE_MATERIAL_MAP[biome_type]
	return FALLBACK_MATERIAL_PATH
