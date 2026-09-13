@tool
class_name GradeRefine
## Local refinement of the terrain grid around a profiled line (railway or
## graded road): the cells a cutting
## or a tunnel mouth runs through are re-meshed k × k finer, so a 5 m trench
## and a 6 m bore exist in a grid whose vertices are 13 m apart.
##
## How it stays seamless:
##   · a refined cell's CORNERS are the coarse vertices themselves (already
##     carved by the coarse pass);
##   · a sub-vertex on an edge shared with an UNREFINED cell — or on the
##     chunk border, where the neighbour chunk knows nothing of this — is
##     interpolated along the coarse edge, so it lies exactly on the coarse
##     triangle's edge: no T-junction crack;
##   · a sub-vertex on an edge shared by two refined cells, and every interior
##     one, is re-sampled from the heightfield and carved by the railway rule.
##
## Sub-triangles crossing a tunnel's bore are dropped (a real triangle/box
## test, GradeTunnel.tri_hits_bore — not a vertex test, which let tall thin
## triangles of the steep face slice through the entrance): that is the hole
## in the mountain face the tube runs through, hidden by the headwall's collar.
##
## The same function builds the mesh and the collision patch from the same
## inputs (same grid, same sampler, same carve rule), so the two agree; the
## caller only turns the world positions into its own local frame. Only the
## railway rule is applied to the re-sampled sub-vertices, not the other
## terrain modifiers (rivers, craters, cracks): where one of those crosses a
## cutting the patch border may show a step.


## Build the patch for chunk (hp_nside, hp_ipix) at grid resolution [param res].
##
## [param grid_dirs] — the coarse grid directions; [param grid_h] — the
## coarse vertices' FINAL heights (after every modifier), (res+1)² entries.
## [param band] — 1 for every coarse vertex the railway rule moved.
## [param rw_ctx] — GradeBed.make_ctx() of this chunk (non-empty).
## [param skip_quads] — cells that must stay coarse (overlay-covered), may be
## empty. [param sampler] — `func(dir) -> raw height`. [param outward] — wind
## the sub-triangles with the geometric normal pointing out of the planet.
##
## Returns {} when nothing is refined, else
##   { quads: PackedByteArray (res*res, 1 = refined),
##     pos: Array[Vector3] (sub-vertex WORLD positions, double),
##     dirs: PackedVector3Array, normals: PackedVector3Array,
##     quad_of: PackedInt32Array (cell of each sub-vertex),
##     frac: PackedVector2Array (a/k, b/k of each sub-vertex in its cell),
##     tris: PackedInt32Array — indices < (res+1)² are coarse vertices,
##           (res+1)² + i is sub-vertex i }.
static func build(data: PlanetData, hp_nside: int, hp_ipix: int, res: int,
		grid_dirs: Array, grid_h: PackedFloat64Array, band: PackedByteArray,
		rw_ctx: Dictionary, skip_quads: PackedByteArray, sampler: Callable,
		outward: bool) -> Dictionary:
	if rw_ctx.is_empty() or res < 1 or band.size() != (res + 1) * (res + 1):
		return {}
	var n_coarse := (res + 1) * (res + 1)
	var k := GradeSettings.REFINE_K
	var radius: float = data.radius
	# One coarse pitch of lateral slack around a portal: a coarse vertex up
	# to a cell away from the collar still owns a quad the collar cuts.
	var pitch: float = HEALPix.pixel_side_length(hp_nside, radius) / float(res)
	var mpd: float = float(rw_ctx["m_per_deg"])
	var pieces: Array = rw_ctx["pieces"]
	var profiles: Dictionary = rw_ctx["profiles"]

	# Which coarse vertices stand near a tunnel mouth, and does any tunnel
	# reach this chunk at all (the bore test is only paid then).
	var near_portal := PackedByteArray()
	near_portal.resize(n_coarse)
	var has_portal := false
	var reach := GradeSettings.PORTAL_REFINE_M + GradeSettings.PORTAL_HOOD_M
	for yi in res + 1:
		for xi in res + 1:
			var idx := yi * (res + 1) + xi
			var q := GradeGeom.nearest_on_pieces(pieces, HEALPix.vec2lonlat(grid_dirs[yi][xi]), mpd)
			if not q["hit"]:
				continue
			var prof: Dictionary = profiles.get(int(q["fid"]), {})
			if prof.is_empty():
				continue
			var lat_reach: float = GradeTunnel.bore_half_width(float(prof["hw_m"])) \
					+ GradeSettings.TUNNEL_WALL_M + GradeSettings.PORTAL_COLLAR_M \
					+ pitch
			if absf(float(q["lat_m"])) > lat_reach:
				continue
			var along: float = float(q["along"])
			for seg in prof["segments"]:
				if int(seg["kind"]) != GradeSettings.Kind.TUNNEL:
					continue
				if absf(along - float(seg["lo"])) <= reach or absf(along - float(seg["hi"])) <= reach:
					near_portal[idx] = 1
					has_portal = true
					break

	# Cells to refine: a carved corner, or a corner near a mouth.
	var quads := PackedByteArray()
	quads.resize(res * res)
	var any := false
	for yi in res:
		for xi in res:
			var qi := yi * res + xi
			if not skip_quads.is_empty() and skip_quads[qi] == 1:
				continue
			var c00 := yi * (res + 1) + xi
			var c10 := c00 + 1
			var c01 := c00 + res + 1
			var c11 := c01 + 1
			if band[c00] == 1 or band[c10] == 1 or band[c01] == 1 or band[c11] == 1 \
					or near_portal[c00] == 1 or near_portal[c10] == 1 \
					or near_portal[c01] == 1 or near_portal[c11] == 1:
				quads[qi] = 1
				any = true
	if not any:
		return {}

	var fxy := HEALPix.pix2face_xy(hp_nside, hp_ipix)
	var face: int = fxy["face"]
	var base_ix: float = float(fxy["ix"])
	var base_iy: float = float(fxy["iy"])
	var inv_res := 1.0 / float(res)
	var inv_k := 1.0 / float(k)

	var pos: Array[Vector3] = []
	var dirs := PackedVector3Array()
	var normals := PackedVector3Array()
	var quad_of := PackedInt32Array()
	var frac := PackedVector2Array()
	var tris := PackedInt32Array()
	# Shared edge sub-vertices: key → global index.
	var edge_cache := {}
	# Track coordinates per vertex index, for the bore test (a vertex is
	# shared by up to six triangles).
	var local_cache := {}

	# Coarse world positions (double), for interpolation and normals.
	var coarse_pos: Array[Vector3] = []
	coarse_pos.resize(n_coarse)
	for yi in res + 1:
		for xi in res + 1:
			var idx := yi * (res + 1) + xi
			coarse_pos[idx] = (grid_dirs[yi][xi] as Vector3) * (radius + grid_h[idx])

	for yi in res:
		for xi in res:
			var qi := yi * res + xi
			if quads[qi] == 0:
				continue
			# Global index of every sub-grid node (a, b) of this cell.
			var node := PackedInt32Array()
			node.resize((k + 1) * (k + 1))
			var cell_pos: Array[Vector3] = []
			cell_pos.resize((k + 1) * (k + 1))
			for b in k + 1:
				for a in k + 1:
					var ni := b * (k + 1) + a
					var gidx := -1
					var p: Vector3
					var a_end := 1 if a == k else 0
					var b_end := 1 if b == k else 0
					if (a == 0 or a == k) and (b == 0 or b == k):
						# A coarse corner.
						gidx = (yi + b_end) * (res + 1) + (xi + a_end)
						p = coarse_pos[gidx]
					elif a == 0 or a == k or b == 0 or b == k:
						# On a cell edge: shared with the neighbouring cell.
						var c_from: int
						var c_to: int
						var j: int
						var other_refined: bool
						if b == 0 or b == k:
							c_from = (yi + b_end) * (res + 1) + xi
							c_to = c_from + 1
							j = a
							var oy := yi - 1 if b == 0 else yi + 1
							other_refined = oy >= 0 and oy < res and quads[oy * res + xi] == 1
						else:
							c_from = yi * (res + 1) + (xi + a_end)
							c_to = c_from + res + 1
							j = b
							var ox := xi - 1 if a == 0 else xi + 1
							other_refined = ox >= 0 and ox < res and quads[yi * res + ox] == 1
						var key := (c_from * n_coarse + c_to) * (k + 1) + j
						if edge_cache.has(key):
							gidx = int(edge_cache[key])
							p = pos[gidx - n_coarse]
						else:
							if other_refined:
								p = _resample(face, base_ix, base_iy, hp_nside, xi, yi, a, b,
										inv_res, inv_k, radius, sampler, rw_ctx)
							else:
								p = coarse_pos[c_from].lerp(coarse_pos[c_to], float(j) * inv_k)
							gidx = n_coarse + pos.size()
							pos.append(p)
							dirs.append(p.normalized())
							normals.append(Vector3.ZERO)
							quad_of.append(qi)
							frac.append(Vector2(float(a) * inv_k, float(b) * inv_k))
							edge_cache[key] = gidx
					else:
						p = _resample(face, base_ix, base_iy, hp_nside, xi, yi, a, b,
								inv_res, inv_k, radius, sampler, rw_ctx)
						gidx = n_coarse + pos.size()
						pos.append(p)
						dirs.append(p.normalized())
						normals.append(Vector3.ZERO)
						quad_of.append(qi)
						frac.append(Vector2(float(a) * inv_k, float(b) * inv_k))
					node[ni] = gidx
					cell_pos[ni] = p
			# Normals of this cell's sub-vertices from the sub-grid (first
			# writer wins on a shared edge).
			for b in k + 1:
				for a in k + 1:
					var gidx := node[b * (k + 1) + a]
					if gidx < n_coarse:
						continue
					var si := gidx - n_coarse
					if normals[si] != Vector3.ZERO:
						continue
					var pl: Vector3 = cell_pos[b * (k + 1) + maxi(a - 1, 0)]
					var pr: Vector3 = cell_pos[b * (k + 1) + mini(a + 1, k)]
					var pb: Vector3 = cell_pos[maxi(b - 1, 0) * (k + 1) + a]
					var pt: Vector3 = cell_pos[mini(b + 1, k) * (k + 1) + a]
					var nn := (pr - pl).cross(pt - pb)
					var d := dirs[si]
					if nn.dot(d) < 0.0:
						nn = -nn
					normals[si] = nn.normalized() if nn.length_squared() > 0.0 else d
			# Sub-triangles, the coarse pattern, wound as asked, dropped in a bore.
			for b in k:
				for a in k:
					var v00 := node[b * (k + 1) + a]
					var v10 := node[b * (k + 1) + a + 1]
					var v01 := node[(b + 1) * (k + 1) + a]
					var v11 := node[(b + 1) * (k + 1) + a + 1]
					var p00: Vector3 = cell_pos[b * (k + 1) + a]
					var p10: Vector3 = cell_pos[b * (k + 1) + a + 1]
					var p01: Vector3 = cell_pos[(b + 1) * (k + 1) + a]
					var p11: Vector3 = cell_pos[(b + 1) * (k + 1) + a + 1]
					_tri(tris, v00, v01, v10, p00, p01, p10, outward, has_portal,
							pieces, profiles, mpd, radius, local_cache)
					_tri(tris, v10, v01, v11, p10, p01, p11, outward, has_portal,
							pieces, profiles, mpd, radius, local_cache)
	return {"quads": quads, "pos": pos, "dirs": dirs, "normals": normals,
			"quad_of": quad_of, "frac": frac, "tris": tris}


static func _resample(face: int, base_ix: float, base_iy: float, nside: int,
		xi: int, yi: int, a: int, b: int, inv_res: float, inv_k: float,
		radius: float, sampler: Callable, rw_ctx: Dictionary) -> Vector3:
	var fx := base_ix + (float(xi) + float(a) * inv_k) * inv_res
	var fy := base_iy + (float(yi) + float(b) * inv_k) * inv_res
	var dir := HEALPix._face_xy_to_vec(face, fx, fy, nside)
	var h: float = float(sampler.call(dir))
	h = GradeBed.apply(h, HEALPix.vec2lonlat(dir), rw_ctx)
	return dir * (radius + h)


## Append one sub-triangle unless it crosses a bore.
static func _tri(tris: PackedInt32Array, i0: int, i1: int, i2: int,
		p0: Vector3, p1: Vector3, p2: Vector3, outward: bool, has_portal: bool,
		pieces: Array, profiles: Dictionary, mpd: float, radius: float,
		local_cache: Dictionary) -> void:
	if has_portal:
		var l0 := _local(local_cache, i0, p0, pieces, profiles, mpd, radius)
		var l1 := _local(local_cache, i1, p1, pieces, profiles, mpd, radius)
		var l2 := _local(local_cache, i2, p2, pieces, profiles, mpd, radius)
		if not l0.is_empty() and not l1.is_empty() and not l2.is_empty() \
				and GradeTunnel.tri_hits_bore_local(l0["prof"], l0["v"], l1["v"], l2["v"]):
			return
	var n := (p1 - p0).cross(p2 - p0)
	var is_out := n.dot(p0) > 0.0
	tris.append(i0)
	if is_out == outward:
		tris.append(i1)
		tris.append(i2)
	else:
		tris.append(i2)
		tris.append(i1)


static func _local(cache: Dictionary, idx: int, p: Vector3, pieces: Array,
		profiles: Dictionary, mpd: float, radius: float) -> Dictionary:
	if cache.has(idx):
		return cache[idx]
	var l := GradeTunnel.track_local(pieces, profiles, mpd, radius, p)
	cache[idx] = l
	return l
