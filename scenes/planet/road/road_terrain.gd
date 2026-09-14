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
## slabs SURFACE_THICKNESS_M thick laid on the ground (top face, two flanks,
## and their own collision — see RoadRibbon), using flow-aligned UVs so the
## texture follows the road direction — UNLESS a highway / road carries a
## `max_slope_degrees`: such a graded road rides a grade-limited profile with
## cuttings, tunnels and viaducts, built by the same GradeBed / GradeTunnel as
## a railway (see GradeSettings).
##
## A highway is built as LANES: `lanes` × LANE_WIDTH_M plus a MEDIAN_GAP_M
## central gap where nothing is laid (the ground shows; a profiled bed or a
## deck fills it with the structure material). Its QGIS `width` is ignored.
##
## The material used depends on road_type × biome crossed:
##   • highway         → asphalt, or the melted-corundum engraved surface on
##                        the corundum plateau (CORUNDUM_HIGHWAY_MATERIAL_PATH)
##   • road            → always asphalt (fixed texture)
##   • path / trail    → biome-adaptive (path_grass in meadow_steppe-meadow,
##                        path_dirt on rock, etc.)

# ── Road type constants ──────────────────────────────────────────────

## Width of one driving lane, metres.
const LANE_WIDTH_M := 3.5
## Central gap between the two carriageways of a lane-built road, metres.
const MEDIAN_GAP_M := 0.5
## Road types built from their lane count (QGIS `width` is ignored for them).
const MEDIAN_TYPES: PackedStringArray = ["highway"]
## Lane count when the feature carries none.
const DEFAULT_LANES := {"highway": 4}

## Half-widths per road_type in metres.
## These match the QGIS auto-fill defaults in setup_planet_project.py. The
## highway entry is only the [method get_half_width] fallback: a highway zone
## is sized from its lanes (see [method lane_half_width_m]).
const HALF_WIDTH_M := {
	"highway": 7.25,  # 4 lanes × 3.5 m + 0.5 m median = 14.5 m total
	"road":    3.0,   # 6 m total
	"path":    1.0,   # 2 m total
	"trail":   0.5,   # 1 m total
	"railway": 2.5,   # ballast bed when `tracks` is unset — see RailwaySettings
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
	"railway": 4.0,
}

## Thickness of the surfacing, metres: the top of every road — ribbon,
## profiled bed, deck — sits this far above the ground / the profile.
const SURFACE_THICKNESS_M := 0.08

## How far below the ground the ribbon's flanks reach, metres. The terrain
## collision interpolates between its vertices while the ribbon samples the
## true height, so a slab that stopped at the ground would show daylight
## underneath on rough terrain.
const RIBBON_BURY_M := 0.10

## Road types whose QGIS `max_slope_degrees` is honoured (the exporter writes
## the flag only for these; ModifierPack drops it on any other type).
const GRADED_TYPES: PackedStringArray = ["highway", "road"]

## Road types that always use asphalt regardless of biome. A railway is fixed
## too, on its own ballast material (see [method get_material_path]).
const FIXED_MATERIAL_TYPES: PackedStringArray = ["highway", "road", "railway"]

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

## The corundum plateau's highway: melted corundum, vertex-tinted like the
## ground, engraved with the gaufrage (normal map + parallax height map).
const CORUNDUM_HIGHWAY_MATERIAL_PATH := MATERIAL_DIR + "road_corundum_melted.tres"
## The biome whose highways get that surface. Kept as a string rather than
## ArideDesertCorundumPlateauTerrain.BIOME_TYPE so this module does not pull a
## biome module in at load (see the note in RailwaySettings).
const CORUNDUM_BIOME_TYPE := "aride_desert-corundum_plateau"
## Every corundum biome (plateau, sand desert, …) shares this prefix.
const CORUNDUM_BIOME_PREFIX := "aride_desert-corundum"
## The same melted corundum without the engraving, for the slab's flanks and
## a bed's skirts — the gaufrage is a road marking, it belongs on the top only.
const CORUNDUM_HIGHWAY_SIDE_MATERIAL_PATH := MATERIAL_DIR + "road_corundum_melted_side.tres"
## Road materials whose parallax the chunk emitter must keep — it strips
## heightmap_enabled from every other road material (flat overlay, no gain).
const PARALLAX_MATERIAL_PATHS: PackedStringArray = [CORUNDUM_HIGHWAY_MATERIAL_PATH]
## Vehicles keep to the RIGHT of their direction of travel. Mind the planet's
## chirality: with dir = (cos lat·cos lon, sin lat, cos lat·sin lon) the frame
## (east, north, up) is LEFT-handed — facing +along, the +perp side (positive
## lateral offsets, see [method lane_layout] and [method perp_deg]) is on the
## driver's RIGHT. So the +perp carriageway travels +along and the -perp one
## -along. Decides which way each carriageway's road markings face.
const RIGHT_HAND_TRAFFIC := true
## The engraved tile: one lane across, GAUFRAGE_ALONG_M along the road.
const GAUFRAGE_ACROSS_M := LANE_WIDTH_M
const GAUFRAGE_ALONG_M := 3.0

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


## A highway / road with a grade limit set — it is built on a profile.
static func is_graded_road(zone: Dictionary) -> bool:
	return get_road_type(zone) in GRADED_TYPES and zone.has("max_slope_degrees")


## Steepest grade (rise / run) of a graded road, from its degrees.
static func max_grade(zone: Dictionary) -> float:
	return tan(deg_to_rad(clampf(float(zone.get("max_slope_degrees", 0)), 0.0, 89.0)))


## Returns [code]true[/code] if this zone describes a valid road
## (has a centerline with ≥ 2 points).
static func is_road_zone(zone: Dictionary) -> bool:
	var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
	return cl.size() >= 2


## Half-width in metres for [param zone]: the per-feature `width` exported from
## QGIS when the designer filled it in, otherwise the [constant HALF_WIDTH_M]
## default for the road type. A railway follows its `tracks` and a highway its
## `lanes` ([method lane_half_width_m]) — their `width` is ignored.
##
## `width` is the TOTAL width in metres, as written by
## tools/planettech/qgis/export_roads.py — hence the halving. Note that BiomeQuery stores a
## `half_width_deg` of its own (width / 2, mislabelled: that value is in metres),
## which [method prepare_zone] overwrites with the correct degree value.
static func get_half_width_m(zone: Dictionary) -> float:
	# A railway has no `width`: its bed is a function of `tracks` (same rule
	# in the exporter).
	if RailwaySettings.is_railway(zone):
		return RailwaySettings.railway_half_width_m(int(zone.get("tracks", 0)))
	# A highway is a function of its lanes — `width` is deliberately ignored.
	var rt := get_road_type(zone)
	if has_median(rt):
		return lane_half_width_m(lanes_of(zone))
	var width_m: float = float(zone.get("width", 0.0))
	if width_m > 0.0:
		return width_m * 0.5
	return HALF_WIDTH_M.get(rt, 0.5)


## Lane count of [param zone]: its `lanes` when set (> 0), else the type's
## default. A legacy GeoJSON zone stores 0 for "unset".
static func lanes_of(zone: Dictionary) -> int:
	var n := int(zone.get("lanes", 0))
	if n <= 0:
		n = int(DEFAULT_LANES.get(get_road_type(zone), 0))
	return n


## Is [param road_type] built as lanes around a central median?
static func has_median(road_type: String) -> bool:
	return road_type in MEDIAN_TYPES


## Half-width of a lane-built road: [param lanes] × LANE_WIDTH_M + the median.
static func lane_half_width_m(lanes: int) -> float:
	return (float(maxi(lanes, 1)) * LANE_WIDTH_M + MEDIAN_GAP_M) * 0.5


## Cross-section of a road as lateral intervals in metres from the centerline.
## POSITIVE offsets are on the `+perp` side (the ribbon's `pt_l`, see
## [method perp_deg]) — the one convention every builder shares.
##
## Returns {"strips": Array of Vector2(lo, hi) — the driving surfaces, in
## ascending offset; "median": Vector2(lo, hi), or Vector2.ZERO when the road
## has none}. The median comes after floor(lanes / 2) lanes counted from the
## -hw edge; a road without a median (or fewer than 2 lanes) is one strip.
static func lane_layout(road_type: String, lanes: int, hw_m: float) -> Dictionary:
	if not has_median(road_type) or lanes < 2:
		return {"strips": [Vector2(-hw_m, hw_m)], "median": Vector2.ZERO}
	@warning_ignore("integer_division")
	var m_lo := -hw_m + float(lanes / 2) * LANE_WIDTH_M
	var m_hi := m_lo + MEDIAN_GAP_M
	return {
		"strips": [Vector2(-hw_m, m_lo), Vector2(m_hi, hw_m)],
		"median": Vector2(m_lo, m_hi),
	}


## [method lane_layout] of a zone dictionary.
static func lane_layout_of(zone: Dictionary) -> Dictionary:
	return lane_layout(get_road_type(zone), lanes_of(zone), get_half_width_m(zone))


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
		var hw_m: float = get_half_width_m(r) + extra_margin_m
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


## Does the chunk emitter keep this material's parallax? (It strips it from
## every other road material.)
static func keeps_parallax(mat_path: String) -> bool:
	return mat_path in PARALLAX_MATERIAL_PATHS


## Is this the engraved corundum surface (lane UVs, vertex tint)?
static func is_corundum_surface(mat_path: String) -> bool:
	return mat_path == CORUNDUM_HIGHWAY_MATERIAL_PATH


## The material of a road's SIDES (flanks, skirts) given its top's: the
## engraved corundum gets the plain one, every other material is its own.
static func side_material_path(mat_path: String) -> String:
	if is_corundum_surface(mat_path):
		return CORUNDUM_HIGHWAY_SIDE_MATERIAL_PATH
	return mat_path


## Is the ground corundum — the corundum DEFAULT biome ([param on_default],
## see PlanetData.corundum_applies_to_zone), a corundum biome, or a zone whose
## rock is a corundum variety (corundum_white, corundum_blue, … and emery, the
## impure corundum)? A highway on such ground is melted corundum.
static func is_corundum_ground(biome_type: String, rock_type: String = "",
		on_default: bool = false) -> bool:
	if on_default or biome_type.begins_with(CORUNDUM_BIOME_PREFIX):
		return true
	return rock_type.begins_with("corundum") or rock_type == "emery"


## Get the material path for a road segment.
## [param road_type] — "highway", "road", "path", "trail" or "railway"
## [param biome_type] — the biome_type of the terrain under this segment
##                       (adaptive road types, and the corundum highway)
## [param on_corundum] — the ground here is corundum ([method is_corundum_ground])
static func get_material_path(road_type: String, biome_type: String = "",
		on_corundum: bool = false) -> String:
	if road_type == "railway":
		return RailwaySettings.BALLAST_MATERIAL_PATH
	if road_type == "highway" and is_corundum_ground(biome_type, "", on_corundum):
		return CORUNDUM_HIGHWAY_MATERIAL_PATH
	if is_fixed_material(road_type):
		return ASPHALT_MATERIAL_PATH
	# Adaptive: look up biome → path material.
	if ADAPTIVE_MATERIAL_MAP.has(biome_type):
		return ADAPTIVE_MATERIAL_MAP[biome_type]
	return FALLBACK_MATERIAL_PATH
