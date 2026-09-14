extends GutTest
## LOD-seam stitch: a chunk whose edge faces a ONE-level-coarser neighbour is
## baked on that neighbour's grid (PlanetChunk.STITCH_*), so the two meshes
## share their border instead of leaving the skirt a gap to hide.
##
## What the stitch guarantees, and what this file checks:
##   1. the fine chunk's EVEN border vertices are the coarse chunk's own border
##      vertices — same direction, same pyramid level, same sampler call;
##   2. its ODD border vertices sit at the radius of the chord midpoint of
##      their two even neighbours, i.e. on the coarse chunk's straight edge;
##   3. behind the edge, when the parent reads a coarser pyramid tile than the
##      chunk, STITCH_BLEND_ROWS rows ramp from the parent's relief to the
##      chunk's own; nothing past the band moves;
##   4. PlanetTerrain's leaf pass splits a neighbour more than one level
##      coarser (2:1 balance) and sets the mask from the balanced set.
## Each geometric check has its control: the same seam UNSTITCHED is off by
## far more than the tolerance, so a stitch that did nothing would fail.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_chunk_lod_stitch.gd -gexit

const TILE_RES := 16
const EXPORT_NSIDE := 8
const RES := 8
const RADIUS := 6356000.0
const MAX_HEIGHT := 2000.0
const CLIFF_RADIUS := 20000.0
## Border vertices are float32 in the mesh, relative to each chunk's own
## centre: at these synthetic nsides a chunk spans hundreds of km and the
## two chunks' quantisation grids differ by a few cm. The controls miss by
## far more (CONTROL_MIN_M) — a stitch that did nothing would fail.
const TOL_M := 0.25
const CONTROL_MIN_M := 5.0

## Smooth relief, the SAME on every pyramid level (each texel samples one
## function of its direction): levels differ only by their sampling, as a
## real pyramid's do. The stitch engages here.
var _pd: PlanetData = null
## Every level carries its OWN relief, hundreds of metres apart: a cliff
## under every seam. The stitch must refuse those edges (STITCH_MAX_SLOPE).
var _pd_cliff: PlanetData = null


func before_all() -> void:
	_pd = _planet(false)
	_pd_cliff = _planet(true)
	# The first mesh build prints once (detail texture array), and every print
	# crosses the OpenTelemetry bridge, whose error GUT would count against the
	# test in progress. Outside a test nobody minds.
	_pd.get_detail_texture_array()
	_pd_cliff.get_detail_texture_array()


func _planet(per_level_relief: bool) -> PlanetData:
	var pd := PlanetData.new()
	pd.planet_name = "stitch_cliff" if per_level_relief else "stitch"
	# The cliff planet is small: STITCH_MAX_SLOPE is a slope over the
	# chunk's cells, so the levels' hundreds of metres of disagreement must
	# stand over cells of a few hundred metres, not of a hundred kilometres.
	pd.radius = CLIFF_RADIUS if per_level_relief else RADIUS
	pd.max_height = MAX_HEIGHT
	pd.height_offset = 0.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_heightmap_res = TILE_RES
	pd.export_nside = EXPORT_NSIDE
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	pd.chunk_heightmaps_dir = ""
	var ns := 1
	while ns <= EXPORT_NSIDE:
		for ipix in 12 * ns * ns:
			pd.store_chunk_image("hp_n%d_p%d" % [ns, ipix],
					_tile_image(ns, ipix, per_level_relief), [])
		ns *= 2
	return pd


func _tile_image(nside: int, ipix: int, per_level_relief: bool) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	@warning_ignore("integer_division")
	var face: int = ipix / (nside * nside)
	var xy := HEALPix.nest2xy(ipix % (nside * nside))
	for y in TILE_RES:
		for x in TILE_RES:
			var v: float
			if per_level_relief:
				# Level-dependent, never flat.
				v = 0.5 + 0.25 * sin(float(x) * 0.7 + float(ipix) * 0.3 + float(nside)) \
						* cos(float(y) * 0.5 + float(nside) * 1.3)
			else:
				# One smooth function of the texel's direction on the sphere.
				var d := HEALPix._face_xy_to_vec(face, float(xy.x) + (x + 0.5) / float(TILE_RES),
						float(xy.y) + (y + 0.5) / float(TILE_RES), nside)
				v = 0.5 + 0.05 * sin(d.x * 45.0) * cos(d.y * 35.0) + 0.05 * sin(d.z * 55.0)
			img.set_pixel(x, y, Color(v, 0.0, 0.0))
	return img


# ===================================================================
# Fixtures: a fine chunk and the coarser leaf across its WEST edge
# ===================================================================

## An interior pixel of face 4 (equatorial, no face crossing) at [param nside],
## chosen so its W neighbour lies on the same face and is not the sibling.
func _fine_ipix(nside: int) -> int:
	@warning_ignore("integer_division")
	var x := nside / 2
	@warning_ignore("integer_division")
	var y := nside / 2 + 1
	return 4 * nside * nside + HEALPix.xy2nest(x, y)


func _center(nside: int, ipix: int) -> Vector3:
	return PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, ipix) * RADIUS)


func _build(nside: int, ipix: int, stitch: int) -> PackedVector3Array:
	return _build_on(_pd, nside, ipix, stitch)


func _build_on(pd: PlanetData, nside: int, ipix: int, stitch: int) -> PackedVector3Array:
	var c := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, ipix) * pd.radius)
	var mesh := PlanetChunk.generate_mesh_healpix(pd, nside, ipix, RES, c, {}, stitch)
	assert_not_null(mesh)
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var out := PackedVector3Array()
	out.resize((RES + 1) * (RES + 1))
	for i in out.size():
		out[i] = Vector3(verts[i]) + c
	return out


## World positions of the fine chunk's west edge (xi == 0), yi = 0..RES.
func _west_edge(grid: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for yi in RES + 1:
		out.append(grid[yi * (RES + 1)])
	return out


## Distance from [param p] to the nearest vertex of [param verts].
func _nearest_m(p: Vector3, verts: PackedVector3Array) -> float:
	var best := INF
	for v in verts:
		best = minf(best, p.distance_to(v))
	return best


## The coarse leaf west of the fine chunk: its W neighbour's parent.
func _coarse_west(nside: int, ipix: int) -> int:
	var w: int = HEALPix.get_neighbors_nest(nside, ipix)["W"]
	assert_true(w >= 0)
	return HEALPix.parent_pixel(w)


func _check_seam(nside: int) -> void:
	var f_ipix := _fine_ipix(nside)
	var c_ipix := _coarse_west(nside, f_ipix)
	@warning_ignore("integer_division")
	var coarse := _build(nside / 2, c_ipix, 0)
	var stitched := _west_edge(_build(nside, f_ipix, PlanetChunk.STITCH_LEFT))
	var bare := _west_edge(_build(nside, f_ipix, 0))

	# 1. even vertices ARE coarse vertices
	for k in range(0, RES + 1, 2):
		assert_lt(_nearest_m(stitched[k], coarse), TOL_M,
				"n%d yi=%d : sommet pair du bord stitché ≠ sommet du voisin grossier" % [nside, k])
	# 2. odd vertices at the chord midpoint's radius
	var bare_odd_miss := 0.0
	for k in range(1, RES + 1, 2):
		var mid_r := ((stitched[k - 1] + stitched[k + 1]) * 0.5).length()
		assert_lt(absf(stitched[k].length() - mid_r), TOL_M,
				"n%d yi=%d : sommet impair hors de la corde du voisin" % [nside, k])
		var bare_mid_r := ((bare[k - 1] + bare[k + 1]) * 0.5).length()
		bare_odd_miss = maxf(bare_odd_miss, absf(bare[k].length() - bare_mid_r))
	# Controls: the unstitched seam is really open at this level.
	assert_gt(bare_odd_miss, CONTROL_MIN_M,
			"n%d : témoin — sans stitch les sommets impairs devraient quitter la corde" % nside)


# ===================================================================
# 1-2. Seam geometry
# ===================================================================

func test_seam_matches_when_parent_reads_the_same_tile() -> void:
	# nside 16 → parent 8 == export_nside: same tile, knots at the parent's
	# cell midpoints, so only the chord rule is at work.
	_check_seam(2 * EXPORT_NSIDE)


func test_seam_matches_when_parent_reads_a_coarser_tile() -> void:
	# nside 8 → parent 4: a different pyramid level altogether.
	_check_seam(EXPORT_NSIDE)
	# Control: unstitched, the fine even vertices read level 8 while the
	# coarse chunk reads level 4 — the seam is off by the level difference.
	var f_ipix := _fine_ipix(EXPORT_NSIDE)
	var c_ipix := _coarse_west(EXPORT_NSIDE, f_ipix)
	@warning_ignore("integer_division")
	var coarse := _build(EXPORT_NSIDE / 2, c_ipix, 0)
	var bare := _west_edge(_build(EXPORT_NSIDE, f_ipix, 0))
	var miss := 0.0
	for k in range(0, RES + 1, 2):
		miss = maxf(miss, _nearest_m(bare[k], coarse))
	assert_gt(miss, 1.0, "témoin — deux niveaux de pyramide devraient différer au bord")


func test_stitch_is_not_applied_above_twice_export_nside() -> void:
	assert_false(PlanetChunk.edge_stitch_applies(_pd, 4 * EXPORT_NSIDE))
	assert_true(PlanetChunk.edge_stitch_applies(_pd, 2 * EXPORT_NSIDE))
	assert_true(PlanetChunk.edge_stitch_applies(_pd, 2))
	assert_false(PlanetChunk.edge_stitch_applies(_pd, 1))
	# Same call, same mesh: the mask is ignored where it does not apply.
	var n := 4 * EXPORT_NSIDE
	var ip := _fine_ipix(n)
	var a := _build(n, ip, PlanetChunk.STITCH_LEFT)
	var b := _build(n, ip, 0)
	for i in a.size():
		assert_eq(a[i], b[i])


# ===================================================================
# 3. Blend band behind a stitched edge
# ===================================================================

func test_blend_rows_ramp_only_behind_the_stitched_edge() -> void:
	var n := EXPORT_NSIDE  # parent reads level 4: the ramp is on
	var ip := _fine_ipix(n)
	var st := _build(n, ip, PlanetChunk.STITCH_LEFT)
	var bare := _build(n, ip, 0)
	var stride := RES + 1
	var moved_rows := {}
	for yi in range(1, RES):
		for xi in range(1, RES):
			var d := st[yi * stride + xi].distance_to(bare[yi * stride + xi])
			if d > TOL_M:
				moved_rows[xi] = true
	for xi in range(1, PlanetChunk.STITCH_BLEND_ROWS):
		assert_true(moved_rows.has(xi), "la rangée %d derrière le bord doit être fondue" % xi)
	for xi in range(PlanetChunk.STITCH_BLEND_ROWS, RES):
		assert_false(moved_rows.has(xi), "la rangée %d ne doit pas bouger" % xi)
	# The other three edges are untouched (their neighbours are same-level).
	for yi in RES + 1:
		assert_eq(st[yi * stride + RES], bare[yi * stride + RES], "bord est intact")
	for xi in range(1, RES + 1):
		assert_eq(st[xi], bare[xi], "bord sud intact")
		assert_eq(st[RES * stride + xi], bare[RES * stride + xi], "bord nord intact")


func test_no_blend_when_parent_reads_the_same_tile() -> void:
	var n := 2 * EXPORT_NSIDE
	var ip := _fine_ipix(n)
	var st := _build(n, ip, PlanetChunk.STITCH_LEFT)
	var bare := _build(n, ip, 0)
	var stride := RES + 1
	for yi in RES + 1:
		for xi in range(1, RES + 1):
			assert_eq(st[yi * stride + xi], bare[yi * stride + xi],
					"même tuile : seul le bord bouge (xi=%d yi=%d)" % [xi, yi])


func test_an_edge_over_a_cliff_is_left_to_the_skirt() -> void:
	# The cliff planet: every level is another relief, so the parent's border
	# sits hundreds of metres from the chunk's own surface. Stitching there
	# would raise a sloped block along the seam; the edge keeps its heights.
	for n in [EXPORT_NSIDE, 2 * EXPORT_NSIDE]:
		var ip := _fine_ipix(n)
		var st := _build_on(_pd_cliff, n, ip, PlanetChunk.STITCH_LEFT)
		var bare := _build_on(_pd_cliff, n, ip, 0)
		for i in st.size():
			assert_eq(st[i], bare[i], "n%d : falaise sous la couture, le bord garde ses hauteurs" % n)


# ===================================================================
# 4. PlanetTerrain: 2:1 balance and mask
# ===================================================================

func _leaf(t: PlanetTerrain, nside: int, ipix: int, depth: int) -> Dictionary:
	return t._leaf_info(nside, ipix, depth, Vector3(0.0, 0.0, RADIUS + 100.0))


func test_balance_splits_a_two_level_coarser_neighbour_and_masks_the_edge() -> void:
	var t := PlanetTerrain.new()
	t.planet_data = _pd
	t.is_server = false
	# Every leaf at LOD 0: only nside differences drive the mask here.
	_pd.lod0_distance = 1.0e12
	var n := EXPORT_NSIDE
	var f := _fine_ipix(n)
	var w: int = HEALPix.get_neighbors_nest(n, f)["W"]
	var e: int = HEALPix.get_neighbors_nest(n, f)["E"]
	var desired := {}
	var lf := _leaf(t, n, f, 3)
	desired[lf.key] = lf
	# East: same level. West: the neighbour's GRANDPARENT is the leaf (2 levels).
	var le := _leaf(t, n, e, 3)
	desired[le.key] = le
	var lg := _leaf(t, n >> 2, w >> 4, 1)
	desired[lg.key] = lg

	t._balance_and_stitch(desired, Vector3(0.0, 0.0, RADIUS + 100.0))

	assert_false(desired.has(lg.key), "le grand-parent trop grossier doit être découpé")
	var parent_key: String = t._chunk_key_hp(n >> 1, w >> 2)
	assert_true(desired.has(parent_key), "…en ses quatre enfants, dont le parent du voisin ouest")
	assert_eq(int(desired[lf.key].get("stitch", 0)), PlanetChunk.STITCH_LEFT,
			"seule l'arête ouest fait face à un voisin un niveau plus grossier")
	assert_eq(int(desired[le.key].get("stitch", 0)), 0, "voisin de même niveau : pas de stitch")
	assert_eq(int(desired[parent_key].get("stitch", 0)), 0,
			"le côté grossier ne stitche jamais (sa bordure est la référence)")
	t.free()


func test_mask_ignores_a_neighbour_of_another_quality_lod() -> void:
	var t := PlanetTerrain.new()
	t.planet_data = _pd
	_pd.lod0_distance = 1.0e12
	var n := EXPORT_NSIDE
	var f := _fine_ipix(n)
	var w: int = HEALPix.get_neighbors_nest(n, f)["W"]
	var desired := {}
	var lf := _leaf(t, n, f, 3)
	desired[lf.key] = lf
	var lp := _leaf(t, n >> 1, w >> 2, 2)
	lp["lod"] = 2  # drawn at a coarser grid: the stitch could not meet it
	desired[lp.key] = lp
	t._balance_and_stitch(desired, Vector3(0.0, 0.0, RADIUS + 100.0))
	assert_eq(int(desired[lf.key].get("stitch", 0)), 0)
	t.free()


# ===================================================================
# 5. Tile mosaic: a point samples the same height from every tile around it
# ===================================================================

## The stitch (and every seam between chunks) rests on this: a direction
## resolves to the same height whichever tile the sampler starts from —
## along a shared edge AND at a shared corner, where the bilinear kernel
## reaches into the diagonal tile. The old 4-texel edge blend broke it at
## corners (two tiles faded towards different south neighbours: the 300 m
## "landslide" wall on tarsis_3's mesa edge), and its W/S half fetched the
## neighbour half a texel off.
func test_tile_mosaic_samples_identically_from_every_tile() -> void:
	var n := EXPORT_NSIDE
	var t := _fine_ipix(n)
	var nb := HEALPix.get_neighbors_nest(n, t)
	var g := HEALPix.get_pixel_grid(n, t, 4 * TILE_RES)  # 4 samples per texel
	var side := 4 * TILE_RES
	var worst_edge := 0.0
	for k in side + 1:
		# E edge, via T and via E
		var d: Vector3 = g[k][side]
		worst_edge = maxf(worst_edge, absf(_h(d, t) - _h(d, int(nb["E"]))))
		# N edge, via T and via N
		d = g[side][k]
		worst_edge = maxf(worst_edge, absf(_h(d, t) - _h(d, int(nb["N"]))))
		# W and S edges (the old half-texel bug lived on those sides)
		d = g[k][0]
		worst_edge = maxf(worst_edge, absf(_h(d, t) - _h(d, int(nb["W"]))))
		d = g[0][k]
		worst_edge = maxf(worst_edge, absf(_h(d, t) - _h(d, int(nb["S"]))))
	assert_lt(worst_edge, 1.0e-3, "une arête doit se lire pareil depuis ses deux tuiles")
	# Corners: via the four tiles that meet there. (Only a point ON a tile's
	# boundary may be sampled "via" that tile — _direction_to_pixel_uv clamps
	# the local UV — so the exact corner is the one point all four share.)
	var worst_corner := 0.0
	for corner in [[side, side, "E", "N", "NE"], [0, 0, "W", "S", "SW"],
			[side, 0, "E", "S", "SE"], [0, side, "W", "N", "NW"]]:
		var d: Vector3 = g[int(corner[1])][int(corner[0])]
		var ref := _h(d, t)
		for name in [corner[2], corner[3], corner[4]]:
			worst_corner = maxf(worst_corner, absf(ref - _h(d, int(nb[name]))))
	assert_lt(worst_corner, 1.0e-3, "un coin doit se lire pareil depuis ses quatre tuiles")


func _h(dir: Vector3, via_ipix: int) -> float:
	return _pd.sample_height_for_direction(dir, via_ipix, -1, Vector2i(-1, -1), null,
			EXPORT_NSIDE, null)
