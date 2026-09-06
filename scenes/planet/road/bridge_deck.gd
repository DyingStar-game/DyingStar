@tool
class_name BridgeDeck
## Builds the mesh and the collision of a bridge from a [BridgePlan], FOLLOWING
## THE ROAD CENTERLINE in plan and its two rims in profile.
##
## The previous implementation instanced a straight module and oriented it with
## a single Basis taken from the rim-to-rim chord, so a bridge over a curved
## road cut the corner and its ends drifted off the tarmac. Here the deck is
## extruded from the same polyline the ribbon is extruded from — every original
## centerline vertex is a station — so it cannot diverge from the road by more
## than the sagitta of one [member BridgeProfile.deck_segment_m] segment.
##
## ── Winding ────────────────────────────────────────────────────────────
## Triangles are emitted in Godot's CLOCKWISE-front convention BY CONSTRUCTION:
## the geometric normal (v1-v0)x(v2-v0) points INTO the solid. That is not a
## rendering detail — the NPC navmesh bake parses collision bodies through a
## pipeline that expects CW-front input and silently bakes ZERO polygons for
## outward-wound faces, which would seal NPCs off the deck while raycasts hit it
## fine (see PlanetTerrain._make_chunk_collision_body for the same problem on
## terrain chunks). Shading normals are supplied separately and point outward.
##
## ── Coordinates ────────────────────────────────────────────────────────
## Everything is emitted LOCAL to a single origin near the crossing, snapped to
## float32. Jolt's narrowphase runs in float32 relative to a body's origin even
## in a double build, so a shape whose vertices carry planet-scale coordinates
## has an ULP of about half a metre. The bridge body is placed at `origin` and
## its geometry never exceeds a few hundred metres from it.

## Two stations closer than this along the road are the same station.
const STATION_EPS_M := 0.01

## How far the underside of a ramp is pushed below the terrain, so the wedge
## merges into the ground instead of showing a gap under its lip.
const RAMP_UNDERSIDE_BURY_M := 0.30


## Build the geometry for [param plan].
##
## [param sampler] is the same terrain Callable BridgePlan was given — the ramp
## undersides have to follow the ground they are buried in.
##
## Returns { mesh: ArrayMesh, shape: ConcavePolygonShape3D, origin: Vector3,
## stations: PackedFloat64Array }, or an empty dictionary when the plan cannot
## be built. Surface 0 is the driving surface (asphalt), surface 1 the
## structure; the caller assigns the materials, which keeps this file free of
## resource loading and therefore unit-testable with no assets.
static func build(profile: BridgeProfile, plan: Dictionary, road: Dictionary,
		radius: float, sampler: Callable) -> Dictionary:
	if profile == null or plan.is_empty() or not bool(plan.get("ok", false)):
		return {}
	var cl: PackedVector2Array = road.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	if cl.size() < 2 or cum.size() != cl.size():
		return {}

	var stations := _stations(profile, plan, cum)
	if stations.size() < 2:
		return {}

	var road_w: float = float(plan.get("road_width_m", 0.0))
	if road_w <= 0.0:
		road_w = 2.0 * RoadTerrain.get_half_width_m(road)
	var tile_m: float = RoadTerrain.get_tile_size(RoadTerrain.get_road_type(road))

	var frames := _frames(cl, cum, stations)
	var origin := PlanetChunk.snap_to_f32(
			(plan["mid_dir"] as Vector3) * (radius + float(plan["rim_alt_m"])))

	# Deck: the slab the road runs on, half-width covering the road plus the two
	# parapets standing on it, flared where it dives into the ground.
	var deck_hw := PackedFloat64Array()
	var top_r := PackedFloat64Array()
	var bot_r := PackedFloat64Array()
	_profiles(profile, plan, radius, sampler, stations, frames,
			road_w, deck_hw, top_r, bot_r)

	var top := _acc()      # surface 0 — asphalt
	var struct := _acc()   # surface 1 — sides, underside, parapets
	var faces := PackedVector3Array()

	_prism(frames, origin, deck_hw, top_r, bot_r, stations, tile_m,
			top, struct, faces, true)

	# Parapets: outer face flush with the unflared deck edge, so they border the
	# road rather than eat into it. Their thickness is a PHYSICS budget — a
	# shape thinner than the distance a vehicle covers in one physics step can
	# be crossed outright, and this project has seen the server tick fall to
	# 10 Hz, where 45 km/h covers 1.25 m per step.
	var pw: float = profile.parapet_width_m
	var ph: float = profile.parapet_height_m
	if pw > 0.0 and ph > 0.0:
		var centre: float = 0.5 * road_w + 0.5 * pw
		for side in [1.0, -1.0]:
			var hw := PackedFloat64Array()
			var pt := PackedFloat64Array()
			var pb := PackedFloat64Array()
			for i in stations.size():
				hw.append(0.5 * pw)
				pt.append(top_r[i] + ph)
				pb.append(top_r[i])
			_prism(frames, origin, hw, pt, pb, stations, tile_m,
					struct, struct, faces, false, side * centre)

	# Stations are ABSOLUTE along-road distances, so U can reach ~16 000 tiles on
	# a hundred-kilometre road. That is past float32's useful precision for a
	# texture coordinate and the asphalt visibly swims; shift both surfaces back
	# to near zero, exactly as the ribbon does for the same reason.
	_recenter_uvs(top)
	_recenter_uvs(struct)
	var mesh := ArrayMesh.new()
	_commit(mesh, top)
	_commit(mesh, struct)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# Solid from both sides: a deck a body can reach from underneath (a crate
	# dropped in the gorge, a vehicle bouncing) must not be a one-way surface.
	shape.backface_collision = true
	return {"mesh": mesh, "shape": shape, "origin": origin,
			"stations": stations}


## Along-road distances the deck is built at.
##
## Every original centerline vertex inside the structure is included, which is
## what guarantees the deck is the SAME polyline the ribbon extrudes and cannot
## cut a corner the road takes; deck_segment_m then only bounds the sagitta
## between them (4 m gives 4 cm on a 50 m-radius bend).
static func _stations(profile: BridgeProfile, plan: Dictionary,
		cum: PackedFloat64Array) -> PackedFloat64Array:
	var lo: float = float(plan["toe_lo_along"])
	var hi: float = float(plan["toe_hi_along"])
	if hi - lo < STATION_EPS_M:
		return PackedFloat64Array()
	var raw := PackedFloat64Array([lo, float(plan["deck_lo_along"]),
			float(plan["deck_hi_along"]), hi])
	var step: float = maxf(profile.deck_segment_m, 0.25)
	var d := lo + step
	while d < hi:
		raw.append(d)
		d += step
	for c in cum:
		if c > lo and c < hi:
			raw.append(c)
	var sorted := Array(raw)
	sorted.sort()
	var out := PackedFloat64Array()
	for v in sorted:
		if out.is_empty() or float(v) - out[out.size() - 1] > STATION_EPS_M:
			out.append(float(v))
	return out


## Per-station { up, tangent, normal } frame, built from the actual 3-D
## positions rather than from an east/north bearing.
##
## That frame is a trap worth naming: longitude is atan2(z, x), so eastward runs
## +X → +Z and the (east, north, up) triple is LEFT-handed in Godot's Y-up
## world. Building a deck on it mirrors a north-east road into a south-east one.
static func _frames(cl: PackedVector2Array, cum: PackedFloat64Array,
		stations: PackedFloat64Array) -> Array:
	var ups: Array[Vector3] = []
	for s in stations:
		var p := RoadBridge.lonlat_at(cl, cum, s)
		ups.append(RoadBridge.lonlat_to_dir(p.x, p.y))
	var out: Array = []
	var n := ups.size()
	for i in n:
		var u: Vector3 = ups[i]
		var a: Vector3 = ups[maxi(i - 1, 0)]
		var b: Vector3 = ups[mini(i + 1, n - 1)]
		var t: Vector3 = b - a
		t -= u * t.dot(u)
		if t.length_squared() < 1e-24:
			# Degenerate only if two stations collapsed; keep a usable frame
			# rather than emitting NaNs into a collision shape.
			t = u.cross(Vector3.UP)
			if t.length_squared() < 1e-24:
				t = u.cross(Vector3.RIGHT)
		t = t.normalized()
		out.append({"up": u, "t": t, "n": t.cross(u).normalized()})
	return out


## Half-width, top radius and bottom radius at each station.
static func _profiles(profile: BridgeProfile, plan: Dictionary, radius: float,
		sampler: Callable, stations: PackedFloat64Array, frames: Array,
		road_w: float, hw_out: PackedFloat64Array,
		top_out: PackedFloat64Array, bot_out: PackedFloat64Array) -> void:
	var deck_lo: float = float(plan["deck_lo_along"])
	var deck_hi: float = float(plan["deck_hi_along"])
	# One radius per END: the deck follows its two rims rather than being pinned
	# to the higher one, so neither end starts on a step.
	var r_lo: float = float(plan.get("deck_lo_r", plan["deck_top_r"]))
	var r_hi: float = float(plan.get("deck_hi_r", plan["deck_top_r"]))
	var deck_len: float = maxf(deck_hi - deck_lo, 1e-6)
	var tan_lo: float = float(plan.get("ramp_lo_tan", profile.ramp_tan()))
	var tan_hi: float = float(plan.get("ramp_hi_tan", profile.ramp_tan()))
	var ramp_lo: float = maxf(float(plan.get("ramp_lo_m", 0.0)), 1e-6)
	var ramp_hi: float = maxf(float(plan.get("ramp_hi_m", 0.0)), 1e-6)
	var base_hw: float = 0.5 * road_w + profile.parapet_width_m
	for i in stations.size():
		var s: float = stations[i]
		var d := 0.0
		var t_side := 0.0
		var ramp_len := 1.0
		# The deck is the straight run between its two end radii; a ramp leaves
		# the end it belongs to and keeps descending from there, so the join is
		# a change of gradient and never a step.
		var top: float = r_lo + (r_hi - r_lo) * ((s - deck_lo) / deck_len)
		if s < deck_lo:
			d = deck_lo - s
			t_side = tan_lo
			ramp_len = ramp_lo
			top = r_lo - d * t_side
		elif s > deck_hi:
			d = s - deck_hi
			t_side = tan_hi
			ramp_len = ramp_hi
			top = r_hi - d * t_side
		# The flare absorbs the lateral disagreement between this deck, built
		# from the WHOLE-road record (decimated at the pack's coarsest level),
		# and the ribbon, built from the chunk's fine tile: the two polylines
		# can differ by up to the decimation tolerance, ~1.5 m for a 6 m road.
		# Widening only the buried end hides that without widening the bridge.
		hw_out.append(base_hw + profile.ramp_flare_m * clampf(d / ramp_len, 0.0, 1.0))
		top_out.append(top)
		var bottom: float = top - profile.deck_thickness_m
		if d > 0.0:
			# On a ramp the underside must be UNDER the terrain, or the wedge
			# stands on a visible lip. Over the gorge it must not be, or the
			# slab would be as deep as the gorge.
			var ground: float = (radius
					+ float(sampler.call((frames[i] as Dictionary)["up"]))
					+ RoadTerrain.SURFACE_OFFSET)
			bottom = minf(bottom, ground - RAMP_UNDERSIDE_BURY_M)
		bot_out.append(bottom)


## Emit one closed prism: top, underside, two flanks and two end caps.
##
## [param lateral] shifts the whole prism sideways along the frame normal, which
## is how the two parapets are placed without a second code path.
## [param top_is_road] routes the top strip to the asphalt accumulator and gives
## it the ribbon's own flow-aligned UVs.
static func _prism(frames: Array, origin: Vector3, hw: PackedFloat64Array,
		top_r: PackedFloat64Array, bot_r: PackedFloat64Array,
		stations: PackedFloat64Array, tile_m: float, top_acc: Dictionary,
		side_acc: Dictionary, faces: PackedVector3Array, top_is_road: bool,
		lateral: float = 0.0) -> void:
	var n := stations.size()
	var tl := PackedVector3Array()
	var tr := PackedVector3Array()
	var bl := PackedVector3Array()
	var br := PackedVector3Array()
	for i in n:
		var f: Dictionary = frames[i]
		var u: Vector3 = f["up"]
		var nn: Vector3 = f["n"]
		var c: Vector3 = nn * lateral
		tl.append(_local(u * top_r[i] + c + nn * hw[i], origin))
		tr.append(_local(u * top_r[i] + c - nn * hw[i], origin))
		bl.append(_local(u * bot_r[i] + c + nn * hw[i], origin))
		br.append(_local(u * bot_r[i] + c - nn * hw[i], origin))

	for i in n - 1:
		var f0: Dictionary = frames[i]
		var f1: Dictionary = frames[i + 1]
		var u0: Vector3 = f0["up"]
		var u1: Vector3 = f1["up"]
		var n0: Vector3 = f0["n"]
		var n1: Vector3 = f1["n"]
		# Top — outward is +up, so the geometric normal comes out -up: CW-front.
		if top_is_road:
			var v0: float = hw[i] / tile_m
			var v1: float = hw[i + 1] / tile_m
			_strip(top_acc, faces, tl[i], tr[i], tl[i + 1], tr[i + 1], u0, u1,
					Vector2(stations[i] / tile_m, v0),
					Vector2(stations[i] / tile_m, -v0),
					Vector2(stations[i + 1] / tile_m, v1),
					Vector2(stations[i + 1] / tile_m, -v1))
		else:
			_strip_plain(top_acc, faces, tl[i], tr[i], tl[i + 1], tr[i + 1],
					u0, u1, stations, i, tile_m)
		# Underside.
		_strip_plain(side_acc, faces, br[i], bl[i], br[i + 1], bl[i + 1],
				-u0, -u1, stations, i, tile_m)
		# Flanks.
		_strip_plain(side_acc, faces, bl[i], tl[i], bl[i + 1], tl[i + 1],
				n0, n1, stations, i, tile_m)
		_strip_plain(side_acc, faces, tr[i], br[i], tr[i + 1], br[i + 1],
				-n0, -n1, stations, i, tile_m)

	var last := n - 1
	var ft: Dictionary = frames[0]
	var lt: Dictionary = frames[last]
	# Caps, wound so the geometric normal points into the prism at both ends.
	_tri(side_acc, faces, tl[0], bl[0], br[0], -(ft["t"] as Vector3))
	_tri(side_acc, faces, tl[0], br[0], tr[0], -(ft["t"] as Vector3))
	_tri(side_acc, faces, tl[last], tr[last], br[last], lt["t"] as Vector3)
	_tri(side_acc, faces, tl[last], br[last], bl[last], lt["t"] as Vector3)


## One quad of a strip, as two CW-front triangles. [param a]/[param b] are the
## near pair and [param c]/[param d] the far one; the outward normal is the
## cross product implied by that order (see the class header).
static func _strip(acc: Dictionary, faces: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		na: Vector3, nc: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
	_push(acc, faces, a, b, c, na, na, nc, ua, ub, uc)
	_push(acc, faces, b, d, c, na, nc, nc, ub, ud, uc)


## Same, with structural UVs: along the road over the tile size, across the
## section by index. The structure is never read as a texture flow, so this only
## has to be stable and non-degenerate.
static func _strip_plain(acc: Dictionary, faces: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		na: Vector3, nc: Vector3, stations: PackedFloat64Array, i: int,
		tile_m: float) -> void:
	var u0: float = stations[i] / tile_m
	var u1: float = stations[i + 1] / tile_m
	_strip(acc, faces, a, b, c, d, na, nc,
			Vector2(u0, 0.0), Vector2(u0, 1.0), Vector2(u1, 0.0), Vector2(u1, 1.0))


static func _tri(acc: Dictionary, faces: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
	_push(acc, faces, a, b, c, outward, outward, outward,
			Vector2.ZERO, Vector2(1.0, 0.0), Vector2(1.0, 1.0))


static func _push(acc: Dictionary, faces: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3,
		nc: Vector3, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	var v: PackedVector3Array = acc["v"]
	var nrm: PackedVector3Array = acc["n"]
	var uv: PackedVector2Array = acc["uv"]
	v.append(a); v.append(b); v.append(c)
	nrm.append(na); nrm.append(nb); nrm.append(nc)
	uv.append(ua); uv.append(ub); uv.append(uc)
	acc["v"] = v
	acc["n"] = nrm
	acc["uv"] = uv
	faces.append(a); faces.append(b); faces.append(c)


## Shift an accumulator's UVs by whole tiles so they sit near the origin. Whole
## tiles only, so a tiling texture is unchanged.
static func _recenter_uvs(acc: Dictionary) -> void:
	var uv: PackedVector2Array = acc["uv"]
	if uv.is_empty():
		return
	var min_u := uv[0].x
	var min_v := uv[0].y
	for i in range(1, uv.size()):
		min_u = minf(min_u, uv[i].x)
		min_v = minf(min_v, uv[i].y)
	var off := Vector2(floorf(min_u), floorf(min_v))
	if off.is_zero_approx():
		return
	for i in uv.size():
		uv[i] -= off
	acc["uv"] = uv


static func _acc() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(),
			"uv": PackedVector2Array()}


## Add one accumulator to [param mesh] as a surface, with tangents — the road
## materials are normal-mapped and SurfaceTool is what generates them.
static func _commit(mesh: ArrayMesh, acc: Dictionary) -> void:
	var v: PackedVector3Array = acc["v"]
	if v.is_empty():
		return
	var nrm: PackedVector3Array = acc["n"]
	var uv: PackedVector2Array = acc["uv"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in v.size():
		st.set_normal(nrm[i])
		st.set_uv(uv[i])
		st.add_vertex(v[i])
	st.generate_tangents()
	st.commit(mesh)


static func _local(world: Vector3, origin: Vector3) -> Vector3:
	return PlanetChunk.snap_to_f32(world - origin)
