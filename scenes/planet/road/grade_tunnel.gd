@tool
class_name GradeTunnel
## The tube a profiled line (railway, graded road) runs through where the
## terrain stands too high to cut,
## and the headwalls at its two mouths.
##
## Built per chunk from the chunk's own piece of track, like the bed: the
## stations sit on an absolute 4 m grid so two chunks sharing a tunnel meet
## on the same ring. The section is the bore — the ballast bed plus the
## cutting's floor margin on each side, so the walls stand on the carved floor
## — under an arched ceiling, with TUNNEL_WALL_M of concrete around it. The
## tube reaches PORTAL_HOOD_M out of the mountain at each end (a gallery in
## front of the face); the headwall is a thick collar planted in the face,
## wide enough to hide the ragged hole the terrain patch leaves around the
## bore (see GradeRefine).
##
## Visual arrays and collision faces come out of the same builder, both local
## to the caller's origin, both wound with the chunk grid's sign (the caller
## says which).


## Stations along the tube, on an absolute grid.
const STATION_M := 4.0
## The arch starts this far below the crown.
const ARCH_RISE_M := 1.5
const ARCH_SEGMENTS := 6
## The headwall's centre plane, measured back from the tunnel's mouth (the
## terrain face rises at the mouth, over about one refined cell), and its
## thickness along the track — enough to be planted through that face.
const HEADWALL_OFFSET_M := 0.0
const HEADWALL_THICKNESS_M := 2.0
## Below the track level the walls reach into the bed.
const FOOT_M := 0.5


## Inner bore half-width for a bed of half-width [param hw_m].
static func bore_half_width(hw_m: float) -> float:
	return hw_m + GradeSettings.BORE_EXTRA_HW_M


## Is a point (track-relative [param along], [param lat_m], altitude [param z]
## above the radius) inside the bore of a tunnel of [param profile]? Used to
## drop the terrain triangles that would cross it. The floor itself is not
## "inside" (z must clear it by a little), so the carved floor around the
## tube stays.
static func inside_bore(profile: Dictionary, along: float, lat_m: float, z: float) -> bool:
	var bw := bore_half_width(float(profile["hw_m"]))
	if absf(lat_m) >= bw:
		return false
	var zt := GradeProfile.z_track_at(profile, along)
	if z < zt + 0.3 or z > zt + GradeSettings.BORE_H_M + GradeSettings.TUNNEL_WALL_M:
		return false
	var hood := GradeSettings.PORTAL_HOOD_M
	for seg in profile.get("segments", []):
		if int(seg["kind"]) != GradeSettings.Kind.TUNNEL:
			continue
		if along >= float(seg["lo"]) - hood and along <= float(seg["hi"]) + hood:
			return true
	return false


## Does the triangle [param p0]-[param p1]-[param p2] (WORLD positions)
## cross a tunnel's bore? A vertex test is not enough: at the mouth the
## terrain face is steep, and a sub-triangle with one vertex on the carved
## floor and the next one 10 m up the face has neither inside the bore yet
## slices straight through it — the "teeth" hanging in the entrance.
##
## The bore is a box in track coordinates (along, lat_m, height above the
## track); each vertex is taken to those coordinates against [param pieces]
## and the triangle tested against the box with the separating-axis theorem.
## The along-range is the tube's; the height range starts a little above the
## floor so the carved floor itself never counts.
static func tri_hits_bore(pieces: Array, profiles: Dictionary, mpd: float,
		radius: float, p0: Vector3, p1: Vector3, p2: Vector3) -> bool:
	var l0 := track_local(pieces, profiles, mpd, radius, p0)
	var l1 := track_local(pieces, profiles, mpd, radius, p1)
	var l2 := track_local(pieces, profiles, mpd, radius, p2)
	if l0.is_empty() or l1.is_empty() or l2.is_empty():
		return false
	return tri_hits_bore_local(l0["prof"], l0["v"], l1["v"], l2["v"])


## Track coordinates of a WORLD position: {v: Vector3(along, lat_m, height
## above the track), prof} — {} when no railway is near. Cache it per vertex
## when testing many triangles ([method tri_hits_bore_local]).
static func track_local(pieces: Array, profiles: Dictionary, mpd: float,
		radius: float, p: Vector3) -> Dictionary:
	var q := GradeGeom.nearest_on_pieces(pieces, HEALPix.vec2lonlat(p), mpd)
	if not q["hit"]:
		return {}
	var prof: Dictionary = profiles.get(int(q["fid"]), {})
	if prof.is_empty():
		return {}
	var along: float = float(q["along"])
	return {"prof": prof, "v": Vector3(along, float(q["lat_m"]),
			p.length() - radius - GradeProfile.z_track_at(prof, along))}


## [method tri_hits_bore] on track coordinates already computed.
static func tri_hits_bore_local(prof: Dictionary, l0: Vector3, l1: Vector3, l2: Vector3) -> bool:
	var local: Array[Vector3] = [l0, l1, l2]
	var bw := bore_half_width(float(prof["hw_m"]))
	var hood := GradeSettings.PORTAL_HOOD_M
	var z_lo := 0.3
	var z_hi := GradeSettings.BORE_H_M + GradeSettings.TUNNEL_WALL_M
	for seg in profile_tunnels(prof):
		var a_lo: float = float(seg["lo"]) - hood
		var a_hi: float = float(seg["hi"]) + hood
		var centre := Vector3(0.5 * (a_lo + a_hi), 0.0, 0.5 * (z_lo + z_hi))
		var half := Vector3(0.5 * (a_hi - a_lo), bw, 0.5 * (z_hi - z_lo))
		if _tri_box(local[0] - centre, local[1] - centre, local[2] - centre, half):
			return true
	return false


## The TUNNEL segments of a profile.
static func profile_tunnels(profile: Dictionary) -> Array:
	var out: Array = []
	for seg in profile.get("segments", []):
		if int(seg["kind"]) == GradeSettings.Kind.TUNNEL:
			out.append(seg)
	return out


## Triangle / axis-aligned box overlap (Akenine-Möller), box centred at the
## origin with half-extents [param h].
static func _tri_box(v0: Vector3, v1: Vector3, v2: Vector3, h: Vector3) -> bool:
	var f0 := v1 - v0
	var f1 := v2 - v1
	var f2 := v0 - v2
	# The nine edge-cross axes.
	for f in [f0, f1, f2]:
		for axis in [Vector3(0.0, -f.z, f.y), Vector3(f.z, 0.0, -f.x), Vector3(-f.y, f.x, 0.0)]:
			var p0 := v0.dot(axis)
			var p1 := v1.dot(axis)
			var p2 := v2.dot(axis)
			var r := h.x * absf(axis.x) + h.y * absf(axis.y) + h.z * absf(axis.z)
			if maxf(-maxf(p0, maxf(p1, p2)), minf(p0, minf(p1, p2))) > r:
				return false
	# The box's own axes.
	if maxf(v0.x, maxf(v1.x, v2.x)) < -h.x or minf(v0.x, minf(v1.x, v2.x)) > h.x:
		return false
	if maxf(v0.y, maxf(v1.y, v2.y)) < -h.y or minf(v0.y, minf(v1.y, v2.y)) > h.y:
		return false
	if maxf(v0.z, maxf(v1.z, v2.z)) < -h.z or minf(v0.z, minf(v1.z, v2.z)) > h.z:
		return false
	# The triangle's plane.
	var n := f0.cross(f1)
	var r := h.x * absf(n.x) + h.y * absf(n.y) + h.z * absf(n.z)
	return absf(n.dot(v0)) <= r


## The bore's inner section as (lateral, height) points, left foot to right
## foot, positive lateral = left.
static func _inner_section(bw: float) -> PackedVector2Array:
	var h := GradeSettings.BORE_H_M
	var hw_wall := h - ARCH_RISE_M
	var pts := PackedVector2Array()
	pts.append(Vector2(bw, -FOOT_M))
	pts.append(Vector2(bw, hw_wall))
	for i in range(1, ARCH_SEGMENTS):
		var a := PI * float(i) / float(ARCH_SEGMENTS)
		pts.append(Vector2(bw * cos(a), hw_wall + ARCH_RISE_M * sin(a)))
	pts.append(Vector2(-bw, hw_wall))
	pts.append(Vector2(-bw, -FOOT_M))
	return pts


## The outer section: the inner one pushed out by the wall thickness.
static func _outer_section(bw: float) -> PackedVector2Array:
	var w := GradeSettings.TUNNEL_WALL_M
	var h := GradeSettings.BORE_H_M
	var hw_wall := h - ARCH_RISE_M
	var pts := PackedVector2Array()
	pts.append(Vector2(bw + w, -FOOT_M))
	pts.append(Vector2(bw + w, hw_wall))
	for i in range(1, ARCH_SEGMENTS):
		var a := PI * float(i) / float(ARCH_SEGMENTS)
		pts.append(Vector2((bw + w) * cos(a), hw_wall + (ARCH_RISE_M + w) * sin(a)))
	pts.append(Vector2(-bw - w, hw_wall))
	pts.append(Vector2(-bw - w, -FOOT_M))
	return pts


## The headwall's outer outline: the inner section projected from the bore's
## centre onto the collar rectangle, point for point, so the ring between the
## two is a fan of clean quads.
static func _collar_section(bw: float) -> PackedVector2Array:
	var w := GradeSettings.TUNNEL_WALL_M
	var c := GradeSettings.PORTAL_COLLAR_M
	var h := GradeSettings.BORE_H_M
	var half_w := bw + w + c
	var top := h + w + c
	var bottom := -FOOT_M - 1.0
	var centre := Vector2(0.0, 0.5 * (top + bottom))
	var pts := PackedVector2Array()
	for p in _inner_section(bw):
		var d := p - centre
		var scale := INF
		if absf(d.x) > 1e-6:
			scale = minf(scale, half_w / absf(d.x))
		if d.y > 1e-6:
			scale = minf(scale, (top - centre.y) / d.y)
		elif d.y < -1e-6:
			scale = minf(scale, (centre.y - bottom) / -d.y)
		pts.append(centre + d * scale)
	return pts


## Build the tube and headwalls for one chunk's piece of a profiled line.
## Returns {verts, norms, uvs, indices, faces} local to [param origin].
static func build_piece(cl: PackedVector2Array, cum: PackedFloat64Array,
		profile: Dictionary, radius: float, origin: Vector3,
		want_visual: bool, outward: bool) -> Dictionary:
	var acc := {"verts": PackedVector3Array(), "norms": PackedVector3Array(),
			"uvs": PackedVector2Array(), "indices": PackedInt32Array(),
			"faces": PackedVector3Array(), "want": want_visual, "outward": outward,
			"tile_m": RoadTerrain.get_tile_size(str(profile.get("road_type", "railway")))}
	if cl.size() < 2 or cum.size() != cl.size() or profile.is_empty():
		return acc
	var c0: float = cum[0]
	var c1: float = cum[cum.size() - 1]
	var last_piece: bool = c1 >= float(profile["along1"]) - 1e-6
	var z_at := func(along: float) -> float:
		return GradeProfile.z_track_at(profile, along)
	var bw := bore_half_width(float(profile["hw_m"]))
	var inner := _inner_section(bw)
	var outer := _outer_section(bw)
	var collar := _collar_section(bw)
	var hood := GradeSettings.PORTAL_HOOD_M
	for seg in profile["segments"]:
		if int(seg["kind"]) != GradeSettings.Kind.TUNNEL:
			continue
		var t_lo: float = float(seg["lo"]) - hood
		var t_hi: float = float(seg["hi"]) + hood
		var a := maxf(t_lo, c0)
		var b := minf(t_hi, c1)
		if b - a > 0.1:
			var stations := PackedFloat64Array([a])
			var s: float = (floor(a / STATION_M) + 1.0) * STATION_M
			while s < b - 0.05:
				stations.append(s)
				s += STATION_M
			stations.append(b)
			var frames: Array = []
			for st in stations:
				frames.append(GradeGeom.frame_at(cl, cum, st, z_at, radius))
			# Inner shell: normals toward the axis. Outer shell: away from it.
			_shell(acc, frames, stations, inner, origin, true)
			_shell(acc, frames, stations, outer, origin, false)
			# Feet: close the wall between the inner and outer bases.
			_feet(acc, frames, inner, outer, origin)
		# Headwalls, one per mouth, owned by the piece holding the mouth
		# (half-open on the far end so two pieces never both build one).
		for end in [[float(seg["lo"]), -1.0], [float(seg["hi"]), 1.0]]:
			var mouth: float = end[0]
			var sign: float = end[1]
			var centre_along: float = mouth - sign * HEADWALL_OFFSET_M
			var owned: bool = centre_along >= c0 and (centre_along < c1 or (last_piece and centre_along <= c1))
			if not owned:
				continue
			_headwall(acc, cl, cum, z_at, radius, centre_along, sign, inner, collar, origin)
	acc.erase("want")
	acc.erase("outward")
	return acc


## Position of a section point in a frame, local to origin.
static func _at(f: Dictionary, p: Vector2, origin: Vector3) -> Vector3:
	return PlanetChunk.snap_to_f32((f["pos"] as Vector3) + (f["n"] as Vector3) * p.x
			+ (f["up"] as Vector3) * p.y - origin)


## Quads between consecutive stations for each section edge.
static func _shell(acc: Dictionary, frames: Array, stations: PackedFloat64Array,
		section: PackedVector2Array, origin: Vector3, inward: bool) -> void:
	var tile: float = acc["tile_m"]
	for e in section.size() - 1:
		var p0 := section[e]
		var p1 := section[e + 1]
		# Section-edge normal in (lateral, height): perpendicular to the edge,
		# pointing away from the bore centre (or toward it when inward).
		var edge := p1 - p0
		var n2 := Vector2(edge.y, -edge.x).normalized()
		var mid := 0.5 * (p0 + p1)
		if n2.dot(mid - Vector2(0.0, 0.5 * GradeSettings.BORE_H_M)) < 0.0:
			n2 = -n2
		if inward:
			n2 = -n2
		for k in frames.size() - 1:
			var fa: Dictionary = frames[k]
			var fb: Dictionary = frames[k + 1]
			var a0 := _at(fa, p0, origin)
			var a1 := _at(fb, p0, origin)
			var b0 := _at(fa, p1, origin)
			var b1 := _at(fb, p1, origin)
			var na: Vector3 = ((fa["n"] as Vector3) * n2.x + (fa["up"] as Vector3) * n2.y).normalized()
			var nb: Vector3 = ((fb["n"] as Vector3) * n2.x + (fb["up"] as Vector3) * n2.y).normalized()
			var u0: float = stations[k] / tile
			var u1: float = stations[k + 1] / tile
			var v0 := 0.0
			var v1 := edge.length() / tile
			_emit_quad(acc, a0, a1, b0, b1, na, nb, Vector2(u0, v0), Vector2(u1, v0),
					Vector2(u0, v1), Vector2(u1, v1))


## Close the wall base between the inner and outer feet, both sides.
static func _feet(acc: Dictionary, frames: Array, inner: PackedVector2Array,
		outer: PackedVector2Array, origin: Vector3) -> void:
	for side in [[0, 0], [inner.size() - 1, outer.size() - 1]]:
		var p_in: Vector2 = inner[side[0]]
		var po: Vector2 = outer[side[1]]
		for k in frames.size() - 1:
			var fa: Dictionary = frames[k]
			var fb: Dictionary = frames[k + 1]
			var down_a: Vector3 = -(fa["up"] as Vector3)
			var down_b: Vector3 = -(fb["up"] as Vector3)
			_emit_quad(acc, _at(fa, p_in, origin), _at(fb, p_in, origin),
					_at(fa, po, origin), _at(fb, po, origin), down_a, down_b,
					Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)


## A thick ring in the plane of the track at [param centre_along]: front
## and back faces between the bore and the collar outline, plus the rim.
static func _headwall(acc: Dictionary, cl: PackedVector2Array, cum: PackedFloat64Array,
		z_at: Callable, radius: float, centre_along: float, sign: float,
		inner: PackedVector2Array, collar: PackedVector2Array, origin: Vector3) -> void:
	var half_t := 0.5 * HEADWALL_THICKNESS_M
	var f := GradeGeom.frame_at(cl, cum, centre_along, z_at, radius)
	var t: Vector3 = f["t"]
	# Two planes, front (toward the open air, i.e. -sign·t… the mouth at
	# `lo` faces backwards along the track) and back (into the mountain).
	# `sign` is -1 at the `lo` mouth, whose open air lies at smaller along:
	# the front plane and its normal go that way.
	var f_front := f.duplicate()
	f_front["pos"] = (f["pos"] as Vector3) + t * (sign * half_t)
	var f_back := f.duplicate()
	f_back["pos"] = (f["pos"] as Vector3) - t * (sign * half_t)
	var n_front: Vector3 = t * sign
	var n_back: Vector3 = -t * sign
	var tile: float = acc["tile_m"]
	var m := inner.size()
	for e in m - 1:
		var i0 := inner[e]
		var i1 := inner[e + 1]
		var o0 := collar[e]
		var o1 := collar[e + 1]
		# Front ring quad (inner edge → collar edge).
		_emit_quad(acc, _at(f_front, i0, origin), _at(f_front, i1, origin),
				_at(f_front, o0, origin), _at(f_front, o1, origin), n_front, n_front,
				i0 / tile, i1 / tile, o0 / tile, o1 / tile)
		# Back ring quad.
		_emit_quad(acc, _at(f_back, i1, origin), _at(f_back, i0, origin),
				_at(f_back, o1, origin), _at(f_back, o0, origin), n_back, n_back,
				i1 / tile, i0 / tile, o1 / tile, o0 / tile)
		# Rim between the two planes along the collar edge.
		var rim_edge := o1 - o0
		var rn2 := Vector2(rim_edge.y, -rim_edge.x).normalized()
		if rn2.dot(0.5 * (o0 + o1) - Vector2(0.0, 0.5 * GradeSettings.BORE_H_M)) < 0.0:
			rn2 = -rn2
		var rn: Vector3 = ((f["n"] as Vector3) * rn2.x + (f["up"] as Vector3) * rn2.y).normalized()
		_emit_quad(acc, _at(f_front, o0, origin), _at(f_back, o0, origin),
				_at(f_front, o1, origin), _at(f_back, o1, origin), rn, rn,
				Vector2.ZERO, Vector2(HEADWALL_THICKNESS_M / tile, 0.0),
				Vector2(0.0, rim_edge.length() / tile),
				Vector2(HEADWALL_THICKNESS_M / tile, rim_edge.length() / tile))
	# Close the ring's bottom rim (between the two feet) so the block is solid.
	var o_first := collar[0]
	var o_last := collar[m - 1]
	var i_first := inner[0]
	var i_last := inner[m - 1]
	var down: Vector3 = -(f["up"] as Vector3)
	_emit_quad(acc, _at(f_front, o_first, origin), _at(f_back, o_first, origin),
			_at(f_front, i_first, origin), _at(f_back, i_first, origin), down, down,
			Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
	_emit_quad(acc, _at(f_front, i_last, origin), _at(f_back, i_last, origin),
			_at(f_front, o_last, origin), _at(f_back, o_last, origin), down, down,
			Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)


## One quad a0→a1 (along) × b0→b1: visual (with normals/uvs) and collision.
## [param na] is the surface normal at a0/b0, pointing OUT of the solid; the
## collision winding is chosen so the geometric normal agrees with it when the
## caller asked for `outward`, and is reversed otherwise.
static func _emit_quad(acc: Dictionary, a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3,
		na: Vector3, nb: Vector3, uva0: Vector2, uva1: Vector2, uvb0: Vector2, uvb1: Vector2) -> void:
	var faces: PackedVector3Array = acc["faces"]
	var geo_out: bool = (a1 - a0).cross(b0 - a0).dot(na) >= 0.0
	var want_out: bool = bool(acc["outward"]) == geo_out
	if want_out:
		faces.append(a0); faces.append(a1); faces.append(b0)
		faces.append(b0); faces.append(a1); faces.append(b1)
	else:
		faces.append(a0); faces.append(b0); faces.append(a1)
		faces.append(b0); faces.append(b1); faces.append(a1)
	if not bool(acc["want"]):
		return
	var verts: PackedVector3Array = acc["verts"]
	var norms: PackedVector3Array = acc["norms"]
	var uvs: PackedVector2Array = acc["uvs"]
	var indices: PackedInt32Array = acc["indices"]
	var base := verts.size()
	verts.append(a0); norms.append(na); uvs.append(uva0)
	verts.append(a1); norms.append(nb); uvs.append(uva1)
	verts.append(b0); norms.append(na); uvs.append(uvb0)
	verts.append(b1); norms.append(nb); uvs.append(uvb1)
	indices.append(base); indices.append(base + 1); indices.append(base + 2)
	indices.append(base + 2); indices.append(base + 1); indices.append(base + 3)
