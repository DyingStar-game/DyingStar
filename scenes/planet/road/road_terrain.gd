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

## Materials live under assets/_universe/environment/terrain/ — they were moved
## there by the "new tree architecture" commit, and the old
## res://assets/materials/planet/ paths silently dropped every road surface
## (planet_chunk.gd skips a road group whose material fails to load).
const MATERIAL_DIR := "res://assets/_universe/environment/terrain/"

## Fixed materials for highway/road.
const ASPHALT_MATERIAL_PATH := MATERIAL_DIR + "path_asphalt.tres"

## Biome-adaptive material mapping:  biome_type → .tres path.
## For path/trail road types, the material is selected based on the
## biome the road segment crosses.
const ADAPTIVE_MATERIAL_MAP := {
	"meadow_steppe-meadow": MATERIAL_DIR + "path_grass.tres",
	"meadow_steppe-savanna": MATERIAL_DIR + "path_grass.tres",
	"meadow_steppe-steppe": MATERIAL_DIR + "path_grass.tres",
	"meadow_steppe-terraformed_grass": MATERIAL_DIR + "path_grass.tres",
	"forest-temperate_forest": MATERIAL_DIR + "path_dirt.tres",
	"forest-boreal_forest": MATERIAL_DIR + "path_dirt.tres",
	"forest-tropical_forest": MATERIAL_DIR + "path_dirt.tres",
	"forest-dead_forest": MATERIAL_DIR + "path_dirt.tres",
	"aride_desert-sandy_desert": MATERIAL_DIR + "path_sand.tres",
	"aride_desert-rocky_desert": MATERIAL_DIR + "path_dirt.tres",
	"icy-snow":          MATERIAL_DIR + "path_snow.tres",
	"icy-tundra":        MATERIAL_DIR + "path_dirt.tres",
}

## Fallback material when no biome match is found for adaptive types.
const FALLBACK_MATERIAL_PATH := MATERIAL_DIR + "path_dirt.tres"


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


## Half-width in metres for [param zone]: the per-feature `width` exported from
## QGIS when the designer filled it in, otherwise the [constant HALF_WIDTH_M]
## default for the road type.
##
## `width` is the TOTAL width in metres, as written by
## tools/qgis/export_roads.py — hence the halving. Note that BiomeQuery stores a
## `half_width_deg` of its own (width / 2, mislabelled: that value is in metres),
## which [method prepare_zone] overwrites with the correct degree value.
static func get_half_width_m(zone: Dictionary) -> float:
	var width_m: float = float(zone.get("width", 0.0))
	if width_m > 0.0:
		return width_m * 0.5
	return HALF_WIDTH_M.get(get_road_type(zone), 0.5)


## Convert the road half-width from metres to degrees and cache it
## in the zone dictionary so BiomeQuery.get_cross_section_t() can use it.
static func prepare_zone(zone: Dictionary, planet_radius: float) -> void:
	if not zone.get("_road_hw_converted", false):
		var m_per_deg := planet_radius * PI / 180.0
		zone["half_width_deg"] = get_half_width_m(zone) / m_per_deg
		zone["_road_hw_converted"] = true


## Get the half-width in metres for a road type.
static func get_half_width(road_type: String) -> float:
	return HALF_WIDTH_M.get(road_type, 0.5)


## Get the tile size in metres for a road type.
static func get_tile_size(road_type: String) -> float:
	return TILE_M.get(road_type, 2.0)


## Unit perpendicular to the segment [param p0]-[param p1], in DEGREES, such
## that offsetting a point by `perp * (half_width_m / metres_per_degree)` moves
## it exactly half_width_m metres sideways at any latitude.
##
## The obvious version — rotating the raw lon/lat delta by 90° — is wrong, and
## was wrong in the road ribbon for a long time: a degree of longitude is only
## cos(lat) as long as a degree of latitude, so rotating in degree space is not
## a rotation. It extruded a north-south road cos(lat) too narrow (-9 % at 25°,
## -50 % at 60°) and left a diagonal road's edges non-perpendicular to it — a
## sheared ribbon. Rotate in METRIC space and convert back.
##
## Returns Vector2.ZERO for a degenerate segment, which the caller must skip.
static func perp_deg(p0: Vector2, p1: Vector2) -> Vector2:
	var d := p1 - p0
	if d.length_squared() < 1e-24:
		return Vector2.ZERO
	var ls := maxf(cos(deg_to_rad(clampf(0.5 * (p0.y + p1.y), -89.5, 89.5))), 1e-6)
	var metric := Vector2(d.x * ls, d.y).normalized()
	return Vector2(-metric.y / ls, metric.x)


## Squared distance in degrees from [param p] to segment [param a]-[param b],
## with longitude scaled by cos(lat) so the comparison is metric-ish.
static func _dist_sq_to_segment(p: Vector2, a: Vector2, b: Vector2,
		lat_scale: float) -> float:
	var ax := a.x * lat_scale
	var bx := b.x * lat_scale
	var px := p.x * lat_scale
	var dx := bx - ax
	var dy := b.y - a.y
	var seg_sq := dx * dx + dy * dy
	var t := 0.0
	if seg_sq > 1e-24:
		t = clampf(((px - ax) * dx + (p.y - a.y) * dy) / seg_sq, 0.0, 1.0)
	var cx := px - (ax + t * dx)
	var cy := p.y - (a.y + t * dy)
	return cx * cx + cy * cy


## Is (lon, lat) on the surface of any road in [param roads]?
##
## [param roads] are the records of THIS chunk's modifier tile, so the test is a
## point-to-polyline distance over a handful of local points. The three prop
## spawners used to each run their own copy of a BiomeQuery lookup plus
## get_cross_section_t() over every road on the planet, per candidate instance.
##
## [param m_per_deg] = planet_radius * PI / 180.
##
## [param extra_margin_m] widens every road by that many metres for the test only. A caller placing
## something with a FOOTPRINT (a mining zone, a building) must pass its own half-extent here:
## without it the test only rejects a candidate whose exact centre lands on the tarmac, and a 500 m
## field centred just off the verge still swallows the road whole.
static func point_on_any_road(lon: float, lat: float, roads: Array,
		m_per_deg: float, extra_margin_m: float = 0.0) -> bool:
	if roads.is_empty():
		return false
	var p := Vector2(lon, lat)
	var lat_scale := cos(deg_to_rad(clampf(lat, -89.5, 89.5)))
	if lat_scale < 1e-6:
		lat_scale = 1e-6
	for r in roads:
		var cl: PackedVector2Array = r.get("centerline", PackedVector2Array())
		if cl.size() < 2:
			continue
		var hw_m: float = float(r.get("half_width_m", get_half_width_m(r))) + extra_margin_m
		var hw_deg := hw_m / m_per_deg
		var hw_sq := hw_deg * hw_deg
		for i in cl.size() - 1:
			if _dist_sq_to_segment(p, cl[i], cl[i + 1], lat_scale) <= hw_sq:
				return true
	return false


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
