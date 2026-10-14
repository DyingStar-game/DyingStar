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
