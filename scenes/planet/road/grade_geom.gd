@tool
class_name GradeGeom
## Pure geometry for grade-limited lines (railways, graded roads): where a
## point is relative to the track — the line's own surface — and
## where the track is in space. Static, allocation-light, no PlanetData — the
## same functions run in the mesh workers, in the collision builder, on the
## server and in the unit tests.
##
## Conventions shared with the rest of the road code:
##   · along   — absolute metres from the road's true start (`_cum_lengths`),
##               so a value means the same thing whichever tile it came from;
##   · lat_m   — signed lateral offset in metres, POSITIVE to the LEFT of the
##               direction of travel, i.e. along `+RoadTerrain.perp_deg()` on the
##               map and along `frame.n` in 3-D (see [method frame_at]);
##   · lon/lat in degrees, directions in the engine's Y-up convention.


## Nearest point of any piece in [param pieces] to [param lonlat].
##
## [param pieces] are decoded road records (`centerline`, `_cum_lengths`,
## `feature_id`) — normally the railway pieces of a chunk plus its neighbours,
## which partition the same feature, so the minimum over them is the nearest
## point on the whole line and `along` is continuous across piece joints.
##
## Distances are measured in METRIC degrees (longitude scaled by cos(lat), the
## same scaling as [method RoadTerrain._dist_sq_to_segment]) so a 0.7 m rail
## offset is right at any latitude.
##
## Returns {hit: bool, along: float, lat_m: float, dist_m: float,
##          fid: int, piece: int} — `piece` is the index into [param pieces].
static func nearest_on_pieces(pieces: Array, lonlat: Vector2,
		m_per_deg: float) -> Dictionary:
	var best_sq := INF
	var best_along := 0.0
	var best_lat := 0.0
	var best_fid := -1
	var best_piece := -1
	var ls := maxf(cos(deg_to_rad(clampf(lonlat.y, -89.5, 89.5))), 1e-6)
	var px := lonlat.x * ls
	var py := lonlat.y
	for pi in pieces.size():
		var r: Dictionary = pieces[pi]
		var cl: PackedVector2Array = r.get("centerline", PackedVector2Array())
		var cum: PackedFloat64Array = r.get("_cum_lengths", PackedFloat64Array())
		var n := cl.size()
		if n < 2 or cum.size() != n:
			continue
		for i in n - 1:
			var a := cl[i]
			var b := cl[i + 1]
			var ax := a.x * ls
			var dx := b.x * ls - ax
			var dy := b.y - a.y
			var seg_sq := dx * dx + dy * dy
			var t := 0.0
			if seg_sq > 1e-24:
				t = clampf(((px - ax) * dx + (py - a.y) * dy) / seg_sq, 0.0, 1.0)
			var cx := px - (ax + t * dx)
			var cy := py - (a.y + t * dy)
			var d_sq := cx * cx + cy * cy
			if d_sq < best_sq:
				best_sq = d_sq
				best_along = cum[i] + t * (cum[i + 1] - cum[i])
				if seg_sq > 1e-24:
					best_lat = (dx * cy - dy * cx) / sqrt(seg_sq) * m_per_deg
				else:
					best_lat = sqrt(d_sq) * m_per_deg
				best_fid = int(r.get("feature_id", -1))
				best_piece = pi
	if best_piece < 0:
		return {"hit": false, "along": 0.0, "lat_m": 0.0, "dist_m": INF,
				"fid": -1, "piece": -1}
	return {"hit": true, "along": best_along, "lat_m": best_lat,
			"dist_m": sqrt(best_sq) * m_per_deg, "fid": best_fid,
			"piece": best_piece}


## lon/lat at an absolute along-distance on one piece (clamped to its ends).
static func lonlat_at(cl: PackedVector2Array, cum: PackedFloat64Array,
		along: float) -> Vector2:
	return RoadBridge.lonlat_at(cl, cum, along)


## Unit direction at an absolute along-distance on one piece.
static func dir_at(cl: PackedVector2Array, cum: PackedFloat64Array,
		along: float) -> Vector3:
	var p := RoadBridge.lonlat_at(cl, cum, along)
	return RoadBridge.lonlat_to_dir(p.x, p.y)


## Position of the track at [param along]: on the sphere of [param radius]
## plus the altitude [param z_at] returns for that along-distance.
static func pos_at(cl: PackedVector2Array, cum: PackedFloat64Array,
		along: float, z_at: Callable, radius: float) -> Vector3:
	return dir_at(cl, cum, along) * (radius + float(z_at.call(along)))


## Orthonormal frame of the track at [param along], following the GRADE of the
## profile and not just the map: {pos, up, t, n, k} with `t` the unit tangent
## in the direction of increasing along, `up` the outward radial made
## perpendicular to it, and `n = t × up` pointing to the LEFT of travel
## (positive lat_m). All three are right-handed as (n, up, -t) and (-n, up, t),
## which is what a mirrored rail module is placed with — never a negative
## scale.
##
## `k` is the TRUE metres per along-metre there (grade included): the along
## axis is the exporter's cumulative length, and anything laid by along
## count — rail modules, collision boxes — must be sized by k to meet in
## world space. On tarsis_3 the road part was exported with a planet radius
## 7.6 % smaller than the elevation's (plus a per-line cos(lat)), so 1.12 m
## modules stood 1.22 m apart: a 10 cm gap in every rail joint.
##
## Longitude is atan2(z, x), so the naive (east, north, up) triple is
## left-handed in Godot's Y-up world; building the frame from 3-D positions
## sidesteps that trap (see BridgeDeck._frames).
static func frame_at(cl: PackedVector2Array, cum: PackedFloat64Array,
		along: float, z_at: Callable, radius: float,
		half_step_m: float = 0.5) -> Dictionary:
	var n_pts := cl.size()
	var lo: float = cum[0] if n_pts > 0 else 0.0
	var hi: float = cum[n_pts - 1] if n_pts > 0 else 0.0
	var s0 := maxf(along - half_step_m, lo)
	var s1 := minf(along + half_step_m, hi)
	var pos := pos_at(cl, cum, along, z_at, radius)
	var up := pos.normalized()
	var t: Vector3
	var k := 1.0
	if s1 - s0 > 1e-6:
		t = pos_at(cl, cum, s1, z_at, radius) - pos_at(cl, cum, s0, z_at, radius)
		k = t.length() / (s1 - s0)
	else:
		t = Vector3.ZERO
	if t.length_squared() < 1e-24:
		t = up.cross(Vector3.UP)
		if t.length_squared() < 1e-24:
			t = up.cross(Vector3.RIGHT)
		k = 1.0
	t = t.normalized()
	up = (up - t * up.dot(t)).normalized()
	return {"pos": pos, "up": up, "t": t, "n": t.cross(up).normalized(), "k": k}


## Range of module indices whose CENTRE `(i + 0.5) * len_m` lies in
## [c0, c1): Vector2i(first, last_exclusive). Adjacent pieces that share a
## boundary therefore instance disjoint module sets, and the union covers the
## line — a module is never drawn twice nor skipped at a chunk border.
static func module_range(c0: float, c1: float, len_m: float) -> Vector2i:
	if len_m <= 0.0 or c1 <= c0:
		return Vector2i(0, 0)
	var first := int(ceil(c0 / len_m - 0.5))
	var last := int(ceil(c1 / len_m - 0.5))
	return Vector2i(first, maxi(last, first))
