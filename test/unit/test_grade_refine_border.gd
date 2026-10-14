extends GutTest
## Two chunks sharing a border must agree on the sub-vertices of its edges:
## both re-sample them (the cells on both sides are refined) or both
## interpolate them. GradeRefine passed the neighbour cell's ROW (res) instead
## of its outer corners' row (res + 1) on a chunk's top edge, so the chunk
## below re-sampled while the chunk above interpolated — a 10 cm step, an open
## slit with skirts off (tarsis_3, village M0001, p214960190 / p214960188).
##
## Real HEALPix grids (the patch re-samples on the pixel's own face
## coordinates), a pad slid across each of the four borders of a pixel.

const NSIDE := 8192
const RES := 32
const RADIUS := 6356000.0
const CENTRE_LON := -39.5556
const CENTRE_LAT := 24.8560


func _sampler() -> Callable:
	# A relief with curvature: a re-sampled sub-vertex and one interpolated
	# along the coarse edge differ by centimetres, as on the real ground.
	return func(d: Vector3) -> float:
		var ll := HEALPix.vec2lonlat(d)
		return 5600.0 + 3.0 * sin(ll.x * 4000.0) + 2.0 * cos(ll.y * 3500.0)


func _patch(pd: PlanetData, ipix: int, ctx: Dictionary) -> Dictionary:
	var grid_dirs: Array = HEALPix.get_pixel_grid(NSIDE, ipix, RES)
	var grid_h := PackedFloat64Array()
	var band := PackedByteArray()
	grid_h.resize((RES + 1) * (RES + 1))
	band.resize((RES + 1) * (RES + 1))
	var f := _sampler()
	for yi in RES + 1:
		for xi in RES + 1:
			var dir: Vector3 = grid_dirs[yi][xi]
			var raw: float = f.call(dir)
			var h := GradeBed.apply(raw, HEALPix.vec2lonlat(dir), ctx)
			grid_h[yi * (RES + 1) + xi] = h
			if h != raw:
				band[yi * (RES + 1) + xi] = 1
	# The sampler is the RAW relief: the patch carves its re-sampled sub-vertices itself.
	return GradeRefine.build(pd, NSIDE, ipix, RES, grid_dirs, grid_h, band, ctx,
			PackedByteArray(), f, true)


func _key(p: Vector3) -> String:
	var ll := HEALPix.vec2lonlat(p.normalized())
	return "%.6f,%.6f" % [ll.x, ll.y]


func test_both_chunks_treat_a_shared_edge_alike() -> void:
	var pd := PlanetData.new()
	pd.radius = RADIUS
	var mpd := RADIUS * PI / 180.0
	var a := HEALPix.vec2pix_nest(NSIDE, HEALPix.lonlat2vec(CENTRE_LON, CENTRE_LAT))
	var ca := HEALPix.pix2vec_nest(NSIDE, a)
	var pitch := HEALPix.pixel_side_length(NSIDE, RADIUS) / float(RES)
	var compared := 0
	var worst := 0.0
	var worst_at := ""
	for side: String in ["N", "E", "S", "W"]:
		var b: int = int(HEALPix.get_neighbors_nest(NSIDE, a)[side])
		var cb := HEALPix.pix2vec_nest(NSIDE, b)
		var mid := (ca + cb).normalized()
		var across := (cb - ca).normalized()
		var along := across.cross(mid).normalized()
		# One small pad a cell inside EACH chunk: their inner corners hold a pad,
		# the border corners do not (reach 14.4 m, the border is ~23 m from both
		# pads) — the village's case, decided by the outer-corner test alone.
		for t: float in [0.9, 1.0, 1.1]:
			for u: float in [-0.5, 0.0, 0.5]:
				var off := along * (u * pitch / RADIUS)
				var pads: Array = []
				for sgn: float in [-1.0, 1.0]:
					var at := (mid + off + across * (sgn * t * pitch / RADIUS)).normalized()
					var ll := HEALPix.vec2lonlat(at)
					var rec := PadBed.record("t%d" % int(sgn), ll.x, ll.y, 0.3, 2.0, 2.0, 0.0, 0.0)
					rec["z"] = 5600.0
					rec["talus_m"] = 0.0
					pads.append(rec)
				var ctx := {"pieces": [], "profiles": {}, "pads": pads, "m_per_deg": mpd}
				var pa := _patch(pd, a, ctx)
				var pb := _patch(pd, b, ctx)
				if pa.is_empty() or pb.is_empty():
					continue
				var by := {}
				for p: Vector3 in pb["pos"]:
					by[_key(p)] = p
				for p: Vector3 in pa["pos"]:
					var k := _key(p)
					if not by.has(k):
						continue
					compared += 1
					var d: float = absf(p.length() - (by[k] as Vector3).length())
					if d > worst:
						worst = d
						worst_at = "%s t %.1f u %.1f at %s" % [side, t, u, k]
	assert_gt(compared, 0, "the two patches share border sub-vertices")
	assert_lt(worst, 0.001, "one height per shared sub-vertex (worst %.4f m, %s)" % [worst, worst_at])


## A corner the crack rim snap slid off the grid drags its cells' sub-vertices
## along: the patch of each refined cell covers that cell as it really stands,
## once. On the grid, the sub-triangles fanned from a corner slid 35 m onto the
## rim spread over the next cells — two floors a few cm apart flickering in turn
## (tarsis_3, 39.521 W 24.747 N). Measured as plan areas: the sub-triangles of a
## cell add up to its real quad, no more (an overlap counts twice).
func test_a_slid_corner_takes_its_cells_along() -> void:
	var pd := PlanetData.new()
	pd.radius = RADIUS
	var mpd := RADIUS * PI / 180.0
	var ipix := HEALPix.vec2pix_nest(NSIDE, HEALPix.lonlat2vec(CENTRE_LON, CENTRE_LAT))
	var grid_dirs: Array = HEALPix.get_pixel_grid(NSIDE, ipix, RES)
	var pitch := HEALPix.pixel_side_length(NSIDE, RADIUS) / float(RES)
	# A pad on corner (16, 16): the four cells around it are refined.
	var cx := 16
	var cy := 16
	var ll := HEALPix.vec2lonlat(grid_dirs[cy][cx])
	var rec := PadBed.record("slide", ll.x, ll.y, 0.0, 2.0, 2.0, 0.0, 0.0)
	rec["z"] = 5600.0
	rec["talus_m"] = 0.0
	var ctx := {"pieces": [], "profiles": {}, "pads": [rec], "m_per_deg": mpd}
	var n := (RES + 1) * (RES + 1)
	var grid_h := PackedFloat64Array()
	var band := PackedByteArray()
	grid_h.resize(n)
	band.resize(n)
	var f := _sampler()
	var world: Array[Vector3] = []
	world.resize(n)
	for yi in RES + 1:
		for xi in RES + 1:
			var dir: Vector3 = grid_dirs[yi][xi]
			var raw: float = f.call(dir)
			var h := GradeBed.apply(raw, HEALPix.vec2lonlat(dir), ctx)
			grid_h[yi * (RES + 1) + xi] = h
			band[yi * (RES + 1) + xi] = 1 if h != raw else 0
			world[yi * (RES + 1) + xi] = dir * (RADIUS + h)
	# Slide the corner 0.4 pitch towards its (+1, +1) neighbour, as the rim snap does.
	var c := cy * (RES + 1) + cx
	var toward: Vector3 = (grid_dirs[cy + 1][cx + 1] as Vector3) - (grid_dirs[cy][cx] as Vector3)
	var slid_dir: Vector3 = ((grid_dirs[cy][cx] as Vector3)
			+ toward.normalized() * (0.4 * pitch / RADIUS)).normalized()
	world[c] = slid_dir * (RADIUS + grid_h[c])
	var ref := GradeRefine.build(pd, NSIDE, ipix, RES, grid_dirs, grid_h, band, ctx,
			PackedByteArray(), f, true, world)
	assert_false(ref.is_empty(), "the pad refines its cells")
	if ref.is_empty():
		return
	var quads: PackedByteArray = ref["quads"]
	var pos: Array = ref["pos"]
	var quad_of: PackedInt32Array = ref["quad_of"]
	var tris: PackedInt32Array = ref["tris"]
	var up: Vector3 = grid_dirs[cy][cx]
	# Summed over every refined cell: a sub-vertex on an edge two refined cells
	# share belongs to the first that made it, so a triangle cannot be told its
	# cell from its vertices — but an overlap anywhere shows in the total.
	var covered := 0.0
	for t in range(0, tris.size(), 3):
		var p: Array[Vector3] = []
		for j in 3:
			var ti := tris[t + j]
			p.append(world[ti] if ti < n else pos[ti - n])
		covered += absf((p[1] - p[0]).cross(p[2] - p[0]).dot(up)) * 0.5
	var real := 0.0
	var cells := 0
	for qi in RES * RES:
		if quads[qi] == 0:
			continue
		@warning_ignore("integer_division")
		var yi: int = qi / RES
		var xi: int = qi % RES
		var c00: Vector3 = world[yi * (RES + 1) + xi]
		var c10: Vector3 = world[yi * (RES + 1) + xi + 1]
		var c01: Vector3 = world[(yi + 1) * (RES + 1) + xi]
		var c11: Vector3 = world[(yi + 1) * (RES + 1) + xi + 1]
		real += (absf((c10 - c00).cross(c01 - c00).dot(up))
				+ absf((c10 - c11).cross(c01 - c11).dot(up))) * 0.5
		cells += 1
	for yi in [cy - 1, cy]:
		for xi in [cx - 1, cx]:
			assert_eq(quads[yi * RES + xi], 1, "cell (%d, %d) is refined" % [xi, yi])
	assert_almost_eq(covered, real, real * 0.001,
			"the sub-triangles of the %d refined cells cover them once" % cells)
