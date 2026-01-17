@tool
class_name SpatialCraterTerrain
## Terrain module for the **spatial-crater** biome.
##
## Circular structure resulting from a meteorite impact.
## Category: barren.  Layer group: individual (polygon).
##
## **Depression profile** (radial distance d from centroid, radius R):
##
##   • d > R × 1.15  — untouched terrain
##   • R ≤ d ≤ R × 1.15 — rim uplift band (raised lip)
##   • 0 ≤ d < R — parabolic bowl floor
##
## Multiple craters in the same area are applied biggest-first so that
## smaller craters can be nested inside larger ones.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "spatial-crater"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 36
## Category tag for grouping.
const CATEGORY := "barren"

# ── Depth / Rim profile constants ─────────────────────────────────

## Real lunar depth-to-DIAMETER ratios (from observational data).
## These are multiplied by diameter (= 2 × radius) to get depth.
##   diameter > 400 m  → 0.20
##   200–400 m         → 0.17
##   100–200 m         → 0.15
##    30–100 m         → 0.12
##     < 30 m          → 0.10 (extrapolated)
const _RATIO_LARGE   := 0.20  # diameter > 400 m
const _RATIO_MEDIUM  := 0.17  # diameter 200–400 m
const _RATIO_SMALL   := 0.15  # diameter 100–200 m
const _RATIO_TINY    := 0.12  # diameter 30–100 m
const _RATIO_MICRO   := 0.10  # diameter < 30 m (extrapolated)

## Maximum depth clamp (metres) — prevents absurdly deep craters.
const MAX_DEPTH_M := 500.0

## Minimum radius in metres below which the crater is too small to depress.
const MIN_RADIUS_M := 20.0

## Rim uplift as a fraction of depth — lip height above surrounding terrain.
const RIM_UPLIFT_RATIO := 0.04

## Outer edge of the rim band, as a multiplier of the crater radius.
## Between radius and radius × RIM_OUTER_MULT the terrain ramps up.
const RIM_OUTER_MULT := 1.15

# ── Visual identity ───────────────────────────────────────────────

## Floor grey — flat compacted regolith.
const COL_FLOOR := Color(0.48, 0.48, 0.42)
## Rim grey — brighter exposed rock edge.
const COL_RIM := Color(0.54, 0.54, 0.48)


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the biome definition is a crater.
static func is_crater_biome(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE


## Alias kept for consistency with all other biome terrain modules.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return is_crater_biome(bd)


# ── Depth helpers ──────────────────────────────────────────────────

## Compute crater depth from radius (metres) using graduated
## depth-to-diameter ratios from real lunar crater observations.
static func depth_for_radius(radius_m: float) -> float:
	var diameter := radius_m * 2.0
	var ratio: float
	if diameter > 400.0:
		ratio = _RATIO_LARGE
	elif diameter > 200.0:
		# Lerp between 0.17 (at 200 m) and 0.20 (at 400 m).
		var t := (diameter - 200.0) / 200.0
		ratio = lerpf(_RATIO_MEDIUM, _RATIO_LARGE, t)
	elif diameter > 100.0:
		var t := (diameter - 100.0) / 100.0
		ratio = lerpf(_RATIO_SMALL, _RATIO_MEDIUM, t)
	elif diameter > 30.0:
		var t := (diameter - 30.0) / 70.0
		ratio = lerpf(_RATIO_TINY, _RATIO_SMALL, t)
	else:
		# Below 30 m diameter — extrapolated.
		ratio = _RATIO_MICRO
	return minf(diameter * ratio, MAX_DEPTH_M)


## Compute rim uplift height from depth.
static func rim_height_for_depth(depth_m: float) -> float:
	return depth_m * RIM_UPLIFT_RATIO


## Apply the crater depression profile to a single vertex.
## [param dist_m]  — distance from the vertex to the crater centroid (metres)
## [param radius_m] — crater radius (metres)
## [param depth_m] — crater depth (metres)
## Returns the height adjustment (negative = dig, positive = rim uplift).
static func height_offset(dist_m: float, radius_m: float, depth_m: float) -> float:
	var rim_outer := radius_m * RIM_OUTER_MULT
	var rim_h := rim_height_for_depth(depth_m)

	if dist_m >= rim_outer:
		# Outside the crater entirely.
		return 0.0
	if dist_m >= radius_m:
		# Rim band: smooth raised lip that tapers off outward.
		# rim_t goes from 0 (at rim_outer) to 1 (at radius).
		var rim_t := 1.0 - (dist_m - radius_m) / (rim_outer - radius_m)
		# Smooth bell-curve-like shape for the rim cross-section.
		return rim_h * rim_t * rim_t * (3.0 - 2.0 * rim_t)  # smoothstep
	# Inside the crater bowl — parabolic profile.
	# t = 0 at centre (deepest), t = 1 at rim (ground level).
	var t := dist_m / radius_m
	# Parabolic: depth at center, zero at rim, slight rim uplift on top.
	return -depth_m * (1.0 - t * t) + rim_h * t * t * (3.0 - 2.0 * t)


# ── Direction helpers ─────────────────────────────────────────────

## Convert longitude/latitude (degrees) to a unit direction vector
## in Godot's Y-up coordinate system.
static func lonlat_to_dir(lon_deg: float, lat_deg: float) -> Vector3:
	var lon := deg_to_rad(lon_deg)
	var lat := deg_to_rad(lat_deg)
	var cl := cos(lat)
	return Vector3(cl * cos(lon), sin(lat), cl * sin(lon))


# ── Baked crater pipeline (heightmap generation) ──────────────────

## Pre-compute packed arrays for fast per-pixel crater evaluation.
## Call once before the pixel loop, pass the result to [method apply_baked_craters].
## Returns a Dictionary with:
##   "dirs"       — PackedVector3Array of crater centre unit directions
##   "radii"      — PackedFloat64Array of crater radii (metres)
##   "depths"     — PackedFloat64Array of crater depths (metres)
##   "cos_thresh" — PackedFloat64Array of cos(outer_angle) for spatial rejection
##   "count"      — int
static func prepare_baked_craters(
		baked_craters: Array, planet_radius: float) -> Dictionary:
	var n := baked_craters.size()
	var dirs := PackedVector3Array()
	var radii := PackedFloat64Array()
	var depths := PackedFloat64Array()
	var cos_thresh := PackedFloat64Array()
	dirs.resize(n)
	radii.resize(n)
	depths.resize(n)
	cos_thresh.resize(n)
	for i in n:
		var cr: Dictionary = baked_craters[i]
		var cr_r: float = cr["radius_m"]
		var cr_d: float = cr["depth_m"]
		dirs[i] = lonlat_to_dir(cr["lon"], cr["lat"])
		radii[i] = cr_r
		depths[i] = cr_d
		# Outer rim in metres → angular threshold on the unit sphere.
		var outer_m := cr_r * RIM_OUTER_MULT
		var outer_angle := outer_m / planet_radius  # radians (small-angle)
		cos_thresh[i] = cos(outer_angle)
	return {
		"dirs": dirs,
		"radii": radii,
		"depths": depths,
		"cos_thresh": cos_thresh,
		"count": n,
	}


## Compute the additive crater height offset for a single pixel/vertex
## direction, using pre-computed baked data from [method prepare_baked_craters].
## Uses 3D angular distance (acos of dot product) for perfect circles.
static func apply_baked_craters(
		pixel_dir: Vector3, baked_data: Dictionary,
		planet_radius: float) -> float:
	var dirs: PackedVector3Array = baked_data["dirs"]
	var radii: PackedFloat64Array = baked_data["radii"]
	var depths: PackedFloat64Array = baked_data["depths"]
	var cos_th: PackedFloat64Array = baked_data["cos_thresh"]
	var n: int = baked_data["count"]
	var total := 0.0
	for i in n:
		var d := pixel_dir.dot(dirs[i])
		if d < cos_th[i]:
			continue
		var dist_m := acos(clampf(d, -1.0, 1.0)) * planet_radius
		total += height_offset(dist_m, radii[i], depths[i])
	return total


# ── Per-vertex crater pipeline (sub-pixel craters) ───────────────

## Compute the additive crater height offset for a single vertex
## direction, from an Array of crater dictionaries (lon, lat, radius_m,
## depth_m).  Uses 3D angular distance for perfect circular borders.
static func apply_craters(
		vertex_dir: Vector3, craters: Array,
		planet_radius: float) -> float:
	var total := 0.0
	for cr in craters:
		var cr_dir := lonlat_to_dir(float(cr["lon"]), float(cr["lat"]))
		var cr_r: float = float(cr["radius_m"])
		var outer_m := cr_r * RIM_OUTER_MULT
		var d := vertex_dir.dot(cr_dir)
		if d < cos(outer_m / planet_radius):
			continue
		var dist_m := acos(clampf(d, -1.0, 1.0)) * planet_radius
		total += height_offset(dist_m, cr_r, float(cr["depth_m"]))
	return total
