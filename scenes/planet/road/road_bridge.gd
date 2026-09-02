@tool
class_name RoadBridge
## Finds where a road spans a chasm, so a bridge can be placed there.
##
## On corundum planets the "canyons" are the procedural crack network: a
## Voronoi field of gorges (250 m wide, 180 m deep, every 4 km on tarsis_3)
## carved by ArideDesertCorundumPlateauTerrain.crack_offset(). There is no
## polyline to intersect — the cracks do not exist as data at QGIS export time,
## they are generated at runtime — so a crossing cannot be baked into the pack
## the way roads are.
##
## What makes this tractable is that crack_offset() is a PURE function of a
## direction plus the PlanetData parameters. So the crossings are found by
## walking the road and evaluating the field, and — the important part —
## the client and the server, walking the same road with the same parameters,
## find bit-identical spans without exchanging anything. That is the same
## property the crack carving itself already relies on.
##
## Why the road ribbon needs a bridge at all: it samples the RAW heightmap
## (PlanetChunk.generate_mesh does not apply the crack offset), so it already
## flies over every gorge at the rim altitude. The server collision, on the
## other hand, DOES carve them. Without a bridge you drive along a ribbon
## suspended over nothing and fall through it.
##
## Ownership: a span can be several hundred metres long and therefore straddle
## several chunks. Each span is assigned to the single chunk containing its
## MIDPOINT, which spawns the whole bridge — the same trick that keeps the road
## ribbon itself from being drawn twice. Detection is global (see
## PlanetData.get_bridge_spans()), never per chunk, so every chunk agrees on
## where a span begins and ends.

## Coarse walk step, as a fraction of the narrowest feature. A gorge is
## crack_width_m wide (250 m on tarsis_3), so stepping a quarter of that puts at
## least four samples inside every crack and cannot miss one.
##
## A fixed fine step is the obvious implementation and the wrong one: at 5 m,
## walking 109 km of road costs ~22 000 evaluations of the Voronoi field and
## froze the main thread for 1.8 s on the first chunk that needed a bridge.
const COARSE_STEP_FRACTION := 0.25

## Fallback coarse step when the crack width is unknown, in metres.
const COARSE_STEP_FALLBACK_M := 50.0

## Each rim found by the coarse walk is then bisected to this precision, so the
## deck ends up better placed than a fixed 5 m walk would have managed while
## costing an order of magnitude less.
const EDGE_PRECISION_M := 1.0

## Spans shorter than this are ignored: a road that only clips the very lip of
## a crack does not need a structure, and a 10 m bridge looks like a mistake.
const MIN_SPAN_M := 24.0

## Refuse to describe a span longer than this. Past it the crossing is so
## oblique that a bridge is the wrong answer and the road should be re-routed
## in QGIS (a 250 m gorge crossed at 10° needs 1.4 km of deck).
const MAX_SPAN_M := 900.0

## Extra deck length beyond the measured gap, split between both ends, so the
## abutments rest on solid ground rather than on the very edge of the crack.
const ABUTMENT_MARGIN_M := 12.0


## Unit direction for a lon/lat in degrees, in the engine's Y-up convention.
static func lonlat_to_dir(lon: float, lat: float) -> Vector3:
	var lo := deg_to_rad(lon)
	var la := deg_to_rad(lat)
	return Vector3(cos(la) * cos(lo), sin(la), cos(la) * sin(lo))


## Depth of the crack at a lon/lat, in metres (0 outside a crack).
##
## Passes vtx_spacing = 0 so the FULL-depth crack is measured, never the
## LOD-faded one — matching PlanetData.crack_aware_surface_dist(), which is the
## authoritative ground for the server's anti-tunnel clamp. A bridge must be
## placed on the physics reality, not on what a coarse mesh happens to draw.
static func chasm_depth_at(planet_data: PlanetData, lon: float, lat: float) -> float:
	if not planet_data.corundum_override_whole_planet:
		return 0.0
	var off := ArideDesertCorundumPlateauTerrain.crack_offset(
		lonlat_to_dir(lon, lat), planet_data.radius,
		planet_data.crack_spacing_m, planet_data.crack_width_m,
		planet_data.crack_depth_m, 0.0)
	return -off if off < 0.0 else 0.0


## Walk one road and return the spans where it flies over a chasm.
##
## [param road] is a decoded pack record: `centerline` (PackedVector2Array of
## lon/lat) and `_cum_lengths` (distance from the road's true start, in metres).
## Because those distances are absolute, the spans returned here are stated in
## the road's own coordinate system and are identical whichever tile the record
## came from.
##
## Each span is
##     {feature_id, along_start, along_end, span_m, deck_span_m,
##      mid_lon, mid_lat, mid_dir, bearing, forward_dir, max_depth_m,
##      road_width_m, truncated}
## where `bearing` is the unit east/north direction of the crossing (longitude
## already scaled by cos(lat), so it is a real bearing and not a raw lon/lat
## delta) and `forward_dir` is that same direction as a world-space unit vector
## on the tangent plane — what the spawner actually orients the deck with.
static func find_spans_in_road(planet_data: PlanetData, road: Dictionary) -> Array:
	if not planet_data.corundum_override_whole_planet:
		return []
	var cl: PackedVector2Array = road.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	if cl.size() < 2 or cum.size() != cl.size():
		return []
	var fid: int = int(road.get("feature_id", -1))
	# Carried into every span so the deck can be built to the width of the road
	# it continues. Read the same way the ribbon reads it, so a bridge is never
	# wider or narrower than the tarmac running onto it.
	var hw: float = float(road.get("half_width_m", 0.0))
	if hw <= 0.0:
		hw = RoadTerrain.get_half_width_m(road)
	var road_w := 2.0 * hw

	var step := COARSE_STEP_FALLBACK_M
	if planet_data.crack_width_m > 0.0:
		step = planet_data.crack_width_m * COARSE_STEP_FRACTION
	step = maxf(step, 1.0)

	var first: float = cum[0]
	var last: float = cum[cum.size() - 1]
	if last - first < MIN_SPAN_M:
		return []

	var spans: Array = []
	var in_chasm := false
	var entry_along := 0.0
	var max_depth := 0.0
	var prev_along := first
	var prev_in := chasm_depth_at(planet_data, cl[0].x, cl[0].y) > 0.0
	if prev_in:
		in_chasm = true
		entry_along = first
	var along := first + step

	while along <= last:
		var p := lonlat_at(cl, cum, along)
		var d := chasm_depth_at(planet_data, p.x, p.y)
		var now_in := d > 0.0
		if now_in:
			max_depth = maxf(max_depth, d)
		if now_in != prev_in:
			# Bisect the rim between the last two coarse samples.
			var edge := _refine_edge(planet_data, cl, cum, prev_along, along, prev_in)
			if now_in:
				in_chasm = true
				entry_along = edge
				max_depth = maxf(d, 0.0)
			else:
				in_chasm = false
				var s := _make_span(fid, entry_along, edge,
						lonlat_at(cl, cum, entry_along), lonlat_at(cl, cum, edge),
						max_depth, road_w)
				if not s.is_empty():
					spans.append(s)
				max_depth = 0.0
		prev_in = now_in
		prev_along = along
		along += step

	if in_chasm:
		# The road ends inside a chasm — describe what we have rather than drop it.
		var s := _make_span(fid, entry_along, last,
				lonlat_at(cl, cum, entry_along), cl[cl.size() - 1], max_depth, road_w)
		if not s.is_empty():
			spans.append(s)
	return spans


## lon/lat at an absolute along-road distance, interpolated on the centerline.
static func lonlat_at(cl: PackedVector2Array, cum: PackedFloat64Array,
		along: float) -> Vector2:
	var n := cl.size()
	if n == 0:
		return Vector2.ZERO
	if along <= cum[0]:
		return cl[0]
	if along >= cum[n - 1]:
		return cl[n - 1]
	var lo := 0
	var hi := n - 1
	while lo + 1 < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if cum[mid] <= along:
			lo = mid
		else:
			hi = mid
	var seg: float = cum[hi] - cum[lo]
	if seg <= 1e-9:
		return cl[lo]
	return cl[lo].lerp(cl[hi], (along - cum[lo]) / seg)


## Bisect [a, b] for the along-distance where the chasm state flips.
## [param a_in] is the state at [param a]; the state at [param b] is its
## opposite. Both sides of a rim converge on the same value, so two adjacent
## spans never disagree about where the ground ends.
static func _refine_edge(planet_data: PlanetData, cl: PackedVector2Array,
		cum: PackedFloat64Array, a: float, b: float, a_in: bool) -> float:
	var lo := a
	var hi := b
	while hi - lo > EDGE_PRECISION_M:
		var mid := 0.5 * (lo + hi)
		var p := lonlat_at(cl, cum, mid)
		var mid_in := chasm_depth_at(planet_data, p.x, p.y) > 0.0
		if mid_in == a_in:
			lo = mid
		else:
			hi = mid
	# Return the SOLID side so a deck always lands on ground, never in the void.
	return lo if a_in == false else hi


static func _make_span(fid: int, a_along: float, b_along: float,
		a_lonlat: Vector2, b_lonlat: Vector2, max_depth: float,
		road_width_m: float) -> Dictionary:
	var gap := b_along - a_along
	if gap < MIN_SPAN_M:
		return {}
	# Interpolate on the SHORT way round, so a span straddling the ±180° seam
	# does not put its midpoint on the far side of the planet.
	var dlon := wrapf(b_lonlat.x - a_lonlat.x, -180.0, 180.0)
	var mid := Vector2(a_lonlat.x + 0.5 * dlon, 0.5 * (a_lonlat.y + b_lonlat.y))
	var mid_dir := lonlat_to_dir(mid.x, mid.y)
	# A degree of longitude is only cos(lat) as long as a degree of latitude, so
	# the raw lon/lat delta is NOT a direction. Taking it for one skews the deck
	# by ~10° against a road running NE at 45° of latitude, and worse further
	# from the equator — scale it before normalising. RoadTerrain does the same
	# thing for its own distance tests.
	var lat_scale := cos(deg_to_rad(clampf(mid.y, -89.5, 89.5)))
	var dir_ll := Vector2(dlon * lat_scale, b_lonlat.y - a_lonlat.y)
	var bearing := dir_ll.normalized() if dir_ll.length_squared() > 1e-20 else Vector2.RIGHT
	# The deck is straight and must land on both rims, so its direction is the
	# rim-to-rim chord, flattened onto the tangent plane at the midpoint. Giving
	# the spawner a ready-made world vector spares it rebuilding an east/north
	# frame from angles, which is where the orientation used to go wrong.
	var chord := lonlat_to_dir(b_lonlat.x, b_lonlat.y) - lonlat_to_dir(a_lonlat.x, a_lonlat.y)
	var forward := chord - mid_dir * chord.dot(mid_dir)
	forward = forward.normalized() if forward.length_squared() > 1e-20 else Vector3.ZERO
	var truncated := gap > MAX_SPAN_M
	return {
		"feature_id": fid,
		"along_start": a_along,
		"along_end": b_along,
		"span_m": gap,
		"deck_span_m": gap + ABUTMENT_MARGIN_M,
		"mid_lon": mid.x,
		"mid_lat": mid.y,
		"mid_dir": mid_dir,
		"bearing": bearing,
		"forward_dir": forward,
		"max_depth_m": max_depth,
		"road_width_m": road_width_m,
		"truncated": truncated,
	}


## Every span on the planet, found by walking each road once.
##
## [param roads] must hold WHOLE roads, not per-chunk pieces: a span can be
## longer than a fine tile, so a clipped record would report a truncated gap
## and two neighbouring chunks would disagree about where the bridge starts.
## PlanetData.get_bridge_spans() feeds this from the pack's coarsest level,
## where a record covers the entire road.
static func find_all_spans(planet_data: PlanetData, roads: Array) -> Array:
	var out: Array = []
	for r in roads:
		out.append_array(find_spans_in_road(planet_data, r))
	return out


## The spans this chunk is responsible for: those whose MIDPOINT lies in its
## HEALPix pixel. Quadtree leaves are disjoint and cover the sphere, so every
## span has exactly one owner and no bridge is ever built twice.
static func spans_owned_by(spans: Array, hp_nside: int, hp_ipix: int) -> Array:
	if hp_nside <= 0:
		return []
	var out: Array = []
	for s in spans:
		if HEALPix.vec2pix_nest(hp_nside, s["mid_dir"]) == hp_ipix:
			out.append(s)
	return out
