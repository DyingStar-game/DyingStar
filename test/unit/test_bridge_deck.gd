extends GutTest
## Suite for [BridgeDeck] — the geometry a bridge is actually made of.
##
## The properties defended here are the four in-game complaints, turned into
## measurements:
##
##   · the deck FOLLOWS THE ROAD. The old deck was a straight module oriented by
##     the rim-to-rim chord, so over a curved road it cut the corner; the test
##     builds an arc and asserts the deck is an order of magnitude closer to the
##     centerline than that chord would have been.
##   · the deck REACHES BOTH RIMS, at the cutback beyond each, instead of
##     stopping short — which is what a single-altitude deck looked like once
##     its far end was buried in the high rim.
##   · the driving surface is LEVEL: every top vertex at one radius.
##   · the mesh is a CLOSED SOLID wound CW-front, because the NPC navmesh bake
##     silently produces zero polygons for outward-wound faces, and because a
##     deck a body can reach from underneath must not be a one-way surface.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_bridge_deck.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const GROUND_ALT := 100.0

var _profile: BridgeProfile


func before_each() -> void:
	_profile = BridgeProfile.new()


func _flat(_dir: Vector3) -> float:
	return GROUND_ALT


## Ground rising 2 % eastward, so the two rims of an east-west span differ and
## the deck has a gradient to follow.
func _east_slope(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	var mpd := RADIUS * PI / 180.0
	return GROUND_ALT + 0.02 * (lon - LON0) * mpd * cos(deg_to_rad(LAT))


## A straight east-west road.
func _straight_road(length_m: float) -> Dictionary:
	var mpd := RADIUS * PI / 180.0
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var step := 20.0
	for i in int(length_m / step) + 1:
		var d := float(i) * step
		cl.append(Vector2(LON0 + d / (mpd * clat), LAT))
		cum.append(d)
	return {"feature_id": 7, "centerline": cl, "_cum_lengths": cum,
			"road_type": "road", "half_width_m": 3.0}


## A road bending through a circular arc of [param bend_radius_m], so a straight
## chord across the gorge would visibly leave it.
func _curved_road(length_m: float, bend_radius_m: float) -> Dictionary:
	var mpd := RADIUS * PI / 180.0
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var step := 20.0
	for i in int(length_m / step) + 1:
		var d := float(i) * step
		var a := d / bend_radius_m
		var east := bend_radius_m * sin(a)
		var north := bend_radius_m * (1.0 - cos(a))
		cl.append(Vector2(LON0 + east / (mpd * clat), LAT + north / mpd))
		cum.append(d)
	return {"feature_id": 7, "centerline": cl, "_cum_lengths": cum,
			"road_type": "road", "half_width_m": 3.0}


func _span(road: Dictionary, a: float, b: float) -> Dictionary:
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var pa := RoadBridge.lonlat_at(cl, cum, a)
	var pb := RoadBridge.lonlat_at(cl, cum, b)
	var pm := RoadBridge.lonlat_at(cl, cum, 0.5 * (a + b))
	return {
		"feature_id": 7, "along_start": a, "along_end": b,
		"span_m": b - a, "road_width_m": 6.0,
		"start_dir": RoadBridge.lonlat_to_dir(pa.x, pa.y),
		"end_dir": RoadBridge.lonlat_to_dir(pb.x, pb.y),
		"mid_dir": RoadBridge.lonlat_to_dir(pm.x, pm.y),
		"truncated": false,
	}


func _build(road: Dictionary, a: float = 4000.0, b: float = 4250.0,
		sampler: Callable = Callable()) -> Dictionary:
	if not sampler.is_valid():
		sampler = _flat
	var plan := BridgePlan.compute(_profile, _span(road, a, b), road,
			RADIUS, sampler)
	var geo := BridgeDeck.build(_profile, plan, road, RADIUS, sampler)
	geo["plan"] = plan
	return geo


## World position of a station on the road centerline, at deck altitude.
func _centerline_at(road: Dictionary, along: float, r: float) -> Vector3:
	var p := RoadBridge.lonlat_at(road["centerline"], road["_cum_lengths"], along)
	return RoadBridge.lonlat_to_dir(p.x, p.y) * r


# ── Following the road ─────────────────────────────────────────────────

func test_deck_follows_a_curved_centerline() -> void:
	# A 250 m gorge crossed on a 400 m-radius bend. The two are measured against
	# each other: how far the OLD straight rim-to-rim chord strays from the
	# road, against how far the deck actually built does.
	var road := _curved_road(9000.0, 400.0)
	var geo := _build(road)
	assert_false(geo.is_empty(), "the deck must build")
	var plan: Dictionary = geo["plan"]
	var r: float = float(plan["deck_top_r"])
	var origin: Vector3 = geo["origin"]

	var chord_a := _centerline_at(road, float(plan["along_start"]), r)
	var chord_b := _centerline_at(road, float(plan["along_end"]), r)
	var worst_chord := 0.0
	var s: float = float(plan["along_start"])
	while s <= float(plan["along_end"]):
		worst_chord = maxf(worst_chord,
				_dist_to_segment(_centerline_at(road, s, r), chord_a, chord_b))
		s += 5.0

	var arrays: Array = (geo["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var worst_deck := 0.0
	for v in verts:
		worst_deck = maxf(worst_deck,
				_dist_to_polyline(origin + v, road, plan))

	# A deck reaches half its own width either side of the road, so that — and
	# not zero — is the yardstick both numbers are measured against.
	var half_deck: float = (0.5 * 6.0 + _profile.parapet_width_m
			+ _profile.ramp_flare_m)
	assert_gt(worst_chord, half_deck + 10.0,
			"the bend is sharp enough that a chord-built deck would have left "
			+ "the road entirely")
	assert_lt(worst_deck, half_deck + 0.05,
			"while this one never reaches past its own edge — the flared toe "
			+ "is the widest it ever gets")


func test_deck_vertices_stay_close_to_the_road() -> void:
	# The real regression: every deck vertex must be within half the deck width
	# (plus the flare) of the centerline. A chord-built deck fails this on a
	# bend by metres.
	var road := _curved_road(9000.0, 400.0)
	var geo := _build(road)
	var plan: Dictionary = geo["plan"]
	var origin: Vector3 = geo["origin"]
	var limit: float = (0.5 * 6.0 + _profile.parapet_width_m
			+ _profile.ramp_flare_m + 0.5)
	var mesh: ArrayMesh = geo["mesh"]
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_gt(verts.size(), 0, "the driving surface exists")
	var worst := 0.0
	for v in verts:
		var world: Vector3 = origin + v
		worst = maxf(worst, _dist_to_polyline(world, road, plan))
	assert_lt(worst, limit,
			"no part of the driving surface is further from the road than "
			+ "half a deck")


# ── Reaching the rims, and being level ─────────────────────────────────

func test_deck_reaches_a_cutback_past_each_rim() -> void:
	var geo := _build(_straight_road(9000.0))
	var stations: PackedFloat64Array = geo["stations"]
	var plan: Dictionary = geo["plan"]
	assert_lte(stations[0], float(plan["along_start"]) - _profile.road_cutback_m,
			"geometry starts at or beyond the west abutment")
	assert_gte(stations[stations.size() - 1],
			float(plan["along_end"]) + _profile.road_cutback_m,
			"and ends at or beyond the east one")


func test_the_flat_deck_is_level() -> void:
	var road := _straight_road(9000.0)
	var geo := _build(road)
	var plan: Dictionary = geo["plan"]
	var origin: Vector3 = geo["origin"]
	var want: float = float(plan["deck_top_r"])
	var arrays: Array = (geo["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var checked := 0
	for v in verts:
		var world: Vector3 = origin + v
		var along := _nearest_along(world, road, plan)
		if along < float(plan["deck_lo_along"]) + 1.0 \
				or along > float(plan["deck_hi_along"]) - 1.0:
			continue  # on a ramp, where the surface is meant to descend
		assert_almost_eq(world.length(), want, 0.05,
				"a flat-deck vertex sits at the deck radius")
		checked += 1
	assert_gt(checked, 10, "and there were flat-deck vertices to check")


func test_a_sloping_deck_is_a_straight_run_between_its_two_ends() -> void:
	# The deck follows its rims rather than being pinned to the higher one, so
	# neither end starts on a step. What must NOT happen is a kink in the
	# middle: every top vertex has to lie on the line between the two end radii.
	var road := _straight_road(9000.0)
	var geo := _build(road, 4000.0, 4250.0, _east_slope)
	var plan: Dictionary = geo["plan"]
	var origin: Vector3 = geo["origin"]
	var lo_r: float = float(plan["deck_lo_r"])
	var hi_r: float = float(plan["deck_hi_r"])
	assert_gt(absf(hi_r - lo_r), 4.0, "the two ends really do differ")
	var lo_s: float = float(plan["deck_lo_along"])
	var run: float = float(plan["deck_hi_along"]) - lo_s
	assert_lte(absf(hi_r - lo_r) / run, _profile.deck_tan() + 1e-9,
			"and the deck never exceeds its gradient cap")

	var arrays: Array = (geo["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var checked := 0
	for v in verts:
		var world: Vector3 = origin + v
		var along := _nearest_along(world, road, plan)
		if along < lo_s + 1.0 or along > float(plan["deck_hi_along"]) - 1.0:
			continue  # on a ramp, which has its own gradient
		var want: float = lo_r + (hi_r - lo_r) * ((along - lo_s) / run)
		assert_almost_eq(world.length(), want, 0.10,
				"deck vertex on the straight run between the two ends")
		checked += 1
	assert_gt(checked, 10, "and there were deck vertices to check")


# ── The solid ──────────────────────────────────────────────────────────

func test_collision_matches_the_visible_geometry() -> void:
	var geo := _build(_straight_road(9000.0))
	var shape: ConcavePolygonShape3D = geo["shape"]
	var faces: PackedVector3Array = shape.get_faces()
	assert_eq(faces.size() % 3, 0, "whole triangles")
	var mesh: ArrayMesh = geo["mesh"]
	var mesh_tris := 0
	for i in mesh.get_surface_count():
		mesh_tris += (mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
				as PackedVector3Array).size() / 3
	assert_eq(faces.size() / 3, mesh_tris,
			"every triangle you can see is a triangle you can hit")
	assert_true(shape.backface_collision,
			"solid from underneath too — a body in the gorge must not pass "
			+ "through the deck")


func test_the_driving_surface_is_wound_cw_front() -> void:
	# Godot's CW-front convention: the geometric normal points INTO the solid.
	# Outward-wound faces bake ZERO navmesh polygons, which would seal NPCs off
	# the deck while raycasts still hit it.
	var geo := _build(_straight_road(9000.0))
	var origin: Vector3 = geo["origin"]
	var arrays: Array = (geo["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var checked := 0
	for i in range(0, verts.size(), 3):
		var a: Vector3 = origin + verts[i]
		var b: Vector3 = origin + verts[i + 1]
		var c: Vector3 = origin + verts[i + 2]
		var gn := (b - a).cross(c - a)
		if gn.length_squared() < 1e-12:
			continue
		assert_lt(gn.normalized().dot(a.normalized()), 0.0,
				"the driving surface's geometric normal points down, into "
				+ "the slab")
		checked += 1
	assert_gt(checked, 10)


func test_the_prism_is_closed() -> void:
	# Every edge shared by exactly two triangles, in opposite directions: that
	# is what makes it a solid rather than a set of sheets, and it is why a
	# vehicle cannot find a seam to fall through.
	var geo := _build(_straight_road(9000.0))
	var faces: PackedVector3Array = (geo["shape"] as ConcavePolygonShape3D).get_faces()
	var edges: Dictionary = {}
	for i in range(0, faces.size(), 3):
		for e in 3:
			var p: Vector3 = faces[i + e]
			var q: Vector3 = faces[i + (e + 1) % 3]
			var key := "%s|%s" % [p, q]
			var rev := "%s|%s" % [q, p]
			if edges.has(rev):
				edges[rev] -= 1
				if edges[rev] == 0:
					edges.erase(rev)
			else:
				edges[key] = int(edges.get(key, 0)) + 1
	assert_eq(edges.size(), 0,
			"no edge is left unpaired — the geometry is a closed solid")


# ── Numerics ───────────────────────────────────────────────────────────

func test_local_coordinates_stay_inside_the_f32_budget() -> void:
	# Jolt's narrowphase is float32 relative to the body origin even in a double
	# build. Keeping local coordinates small is what keeps contact noise at
	# micrometres instead of at half a metre.
	var geo := _build(_straight_road(9000.0))
	var origin: Vector3 = geo["origin"]
	assert_gt(origin.length(), RADIUS - 1.0, "the body sits at the crossing")
	var faces: PackedVector3Array = (geo["shape"] as ConcavePolygonShape3D).get_faces()
	var worst := 0.0
	for v in faces:
		worst = maxf(worst, maxf(absf(v.x), maxf(absf(v.y), absf(v.z))))
	assert_lt(worst, 1500.0, "local extent stays within a f32 ULP of ~1e-4 m")


func test_a_refused_plan_builds_nothing() -> void:
	# "No deck" and "no ribbon cut" must be the same decision, or the road ends
	# up cut open over a gorge with nothing spanning it.
	assert_true(BridgeDeck.build(_profile, {"ok": false}, _straight_road(500.0),
			RADIUS, _flat).is_empty())


# ── Helpers ────────────────────────────────────────────────────────────

func _dist_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-12),
			0.0, 1.0)
	return p.distance_to(a + ab * t)


## Distance from [param p] to the road, measured on the deck's own sphere.
func _dist_to_polyline(p: Vector3, road: Dictionary, plan: Dictionary) -> float:
	var r: float = float(plan["deck_top_r"])
	# Quarter-metre stations: this measures a distance to a POLYLINE by sampling
	# it, so a coarse step over-reports by the sagitta of its own step and would
	# be mistaken for the deck straying.
	var best := INF
	var s: float = float(plan["toe_lo_along"])
	var hi: float = float(plan["toe_hi_along"])
	while s <= hi:
		best = minf(best, p.distance_to(_centerline_at(road, s, r)))
		s += 0.25
	# Compare on the horizontal only: ramps drop, and that is not a lateral
	# error.
	var vertical: float = absf(p.length() - r)
	return maxf(0.0, sqrt(maxf(best * best - vertical * vertical, 0.0)))


func _nearest_along(p: Vector3, road: Dictionary, plan: Dictionary) -> float:
	# Probe on the deck's mean radius: the search only needs to rank candidate
	# stations, and a sloping deck's ends differ by metres against stations
	# metres apart.
	var r: float = 0.5 * (float(plan["deck_lo_r"]) + float(plan["deck_hi_r"]))
	var best := INF
	var best_s: float = float(plan["toe_lo_along"])
	var s: float = best_s
	var hi: float = float(plan["toe_hi_along"])
	while s <= hi:
		var d := p.distance_to(_centerline_at(road, s, r))
		if d < best:
			best = d
			best_s = s
		s += 0.5
	return best_s
