extends GutTest
## MountainRelief: the procedural mountains, from the pure envelope / ridge
## maths up to the sampler contract — the mesh, the collision, a gameplay
## query without a frame and the coarse chunks all stand on ONE relief.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_mountain_relief.gd

const TILE_RES := 16
const EXPORT_NSIDE := 8
## Finest chunk: nside 64 (max_quadtree_depth 6), 8 quads a side.
const DEPTH := 6
const CHUNK_NSIDE := 64
const RES := 8
const RADIUS := 1000000.0
const MAX_HEIGHT := 500.0

var _pd: PlanetData = null
var _mpd: float = RADIUS * PI / 180.0
## A chunk of face 4 and the lon/lat of its centre — the fixtures put the
## polygon edge and the ridge through it.
var _hp_ipix: int = -1
var _export_ipix: int = -1
var _center_ll := Vector2.ZERO


func before_all() -> void:
	_pd = _planet()
	_pd.get_detail_texture_array()
	@warning_ignore("integer_division")
	var x := EXPORT_NSIDE / 2
	@warning_ignore("integer_division")
	var y := EXPORT_NSIDE / 2 + 1
	_export_ipix = 4 * EXPORT_NSIDE * EXPORT_NSIDE + HEALPix.xy2nest(x, y)
	_hp_ipix = _export_ipix
	var ns := EXPORT_NSIDE
	while ns < CHUNK_NSIDE:
		_hp_ipix = (_hp_ipix << 2) | 3
		ns *= 2
	_center_ll = HEALPix.vec2lonlat(HEALPix.pix2vec_nest(CHUNK_NSIDE, _hp_ipix))


func before_each() -> void:
	_pd.set_mountain_overrides([], [])


func _planet() -> PlanetData:
	var pd := PlanetData.new()
	pd.planet_name = "mountains"
	pd.radius = RADIUS
	pd.max_height = MAX_HEIGHT
	pd.height_offset = 0.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_heightmap_res = TILE_RES
	pd.chunk_resolution = RES
	pd.max_quadtree_depth = DEPTH
	pd.export_nside = EXPORT_NSIDE
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	pd.chunk_heightmaps_dir = ""
	var ns := 1
	while ns <= EXPORT_NSIDE:
		for ipix in 12 * ns * ns:
			pd.store_chunk_image("hp_n%d_p%d" % [ns, ipix], _tile_image(ns, ipix), [])
		ns *= 2
	return pd


func _tile_image(nside: int, ipix: int) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	@warning_ignore("integer_division")
	var face: int = ipix / (nside * nside)
	var xy := HEALPix.nest2xy(ipix % (nside * nside))
	for y in TILE_RES:
		for x in TILE_RES:
			var d := HEALPix._face_xy_to_vec(face, float(xy.x) + (x + 0.5) / float(TILE_RES),
					float(xy.y) + (y + 0.5) / float(TILE_RES), nside)
			img.set_pixel(x, y, Color(0.5 + 0.05 * sin(d.x * 45.0) * cos(d.y * 35.0), 0.0, 0.0))
	return img


# ===================================================================
# Feature fixtures (pack-decoded shape)
# ===================================================================

## A square massif of half-side [param half_km] centred on [param c].
func _zone(c: Vector2, half_km: float, over: Dictionary = {}) -> Dictionary:
	var dl := half_km * 1000.0 / _mpd
	var dlon := dl / cos(deg_to_rad(c.y))
	var poly := PackedVector2Array([
		c + Vector2(-dlon, -dl), c + Vector2(dlon, -dl), c + Vector2(dlon, dl), c + Vector2(-dlon, dl)])
	var z := {"coverage": "partial", "polygon": poly, "amplitude_m": 400.0,
			"wavelength_m": 8000.0, "octaves": 5, "feather_m": 2000.0, "seed": 11}
	z.merge(over, true)
	return z


func _ridge(c: Vector2, len_km: float, over: Dictionary = {}) -> Dictionary:
	var dlon := len_km * 500.0 / _mpd / cos(deg_to_rad(c.y))
	var r := {"coverage": "partial",
			"polygon": PackedVector2Array([c + Vector2(-dlon, 0.0), c + Vector2(dlon, 0.0)]),
			"height_m": 300.0, "width_m": 2000.0, "sharpness": 0.5, "roughness": 0.0,
			"asymmetry": 0.0, "seed": 5}
	r.merge(over, true)
	return r


func _ll_offset(c: Vector2, east_m: float, north_m: float) -> Vector2:
	return c + Vector2(east_m / _mpd / cos(deg_to_rad(c.y)), north_m / _mpd)


# ===================================================================
# Envelope
# ===================================================================

func test_envelope_is_zero_outside_one_deep_inside_and_smooth_between() -> void:
	var c := Vector2(12.0, 20.0)
	var z := MountainRelief.prepare_zone(_zone(c, 20.0))
	assert_false(z.full)
	assert_eq(MountainRelief.envelope(_ll_offset(c, 25000.0, 0.0), z, _mpd), 0.0, "outside")
	assert_eq(MountainRelief.envelope(_ll_offset(c, 20500.0, 0.0), z, _mpd), 0.0, "just outside")
	assert_eq(MountainRelief.envelope(c, z, _mpd), 1.0, "centre")
	assert_eq(MountainRelief.envelope(_ll_offset(c, 17500.0, 0.0), z, _mpd), 1.0, "2.5 km in: past the feather")
	var mid := MountainRelief.envelope(_ll_offset(c, 19000.0, 0.0), z, _mpd)
	assert_between(mid, 0.05, 0.95)
	# Transect across the east edge: never a jump larger than the ramp allows.
	var prev := 0.0
	var step := 25.0
	var x := 21000.0
	while x > 15000.0:
		var e := MountainRelief.envelope(_ll_offset(c, x, 3000.0), z, _mpd)
		assert_true(e >= prev - 1e-9, "monotone inwards at %.0f m" % x)
		assert_lt(e - prev, 1.6 * step / 2000.0 + 1e-6, "smooth at %.0f m" % x)
		prev = e
		x -= step
	assert_eq(prev, 1.0)


func test_full_record_equals_partial_record_deep_inside() -> void:
	var c := Vector2(12.0, 20.0)
	var partial := MountainRelief.prepare_zone(_zone(c, 20.0))
	var zf := _zone(c, 20.0)
	zf["coverage"] = "full"
	zf.erase("polygon")
	var full := MountainRelief.prepare_zone(zf)
	assert_true(full.full)
	var d := HEALPix.lonlat2vec(c.x + 0.01, c.y - 0.02)
	var a := MountainRelief.offset(d, RADIUS, [partial], [], 30.0)
	var b := MountainRelief.offset(d, RADIUS, [full], [], 30.0)
	assert_ne(a, 0.0)
	assert_eq(a, b)


func test_zones_add_and_lift_survives_a_coarse_grid() -> void:
	var c := Vector2(12.0, 20.0)
	var z1 := MountainRelief.prepare_zone(_zone(c, 20.0))
	var z2 := MountainRelief.prepare_zone(_zone(c, 10.0, {"seed": 99, "lift_m": 150.0}))
	var d := HEALPix.lonlat2vec(c.x, c.y)
	var a := MountainRelief.offset(d, RADIUS, [z1], [], 30.0)
	var b := MountainRelief.offset(d, RADIUS, [z2], [], 30.0)
	assert_eq(MountainRelief.offset(d, RADIUS, [z1, z2], [], 30.0), a + b)
	# 8 km wavelength: at a 5 km pitch nothing of the noise fits, the lift stays.
	assert_eq(MountainRelief.offset(d, RADIUS, [z2], [], 5000.0), 150.0)
	assert_eq(MountainRelief.offset(d, RADIUS, [z1], [], 5000.0), 0.0)


# ===================================================================
# Ridges
# ===================================================================

func test_ridge_profile_is_symmetric_bounded_and_tapers_at_the_ends() -> void:
	var c := Vector2(12.0, 20.0)
	var r := MountainRelief.prepare_ridge(_ridge(c, 20.0), _mpd)
	assert_almost_eq(r.length_m, 20000.0, 20.0)
	var crest := MountainRelief.ridge_height(c, HEALPix.lonlat2vec(c.x, c.y), RADIUS, r)
	assert_almost_eq(crest, 300.0, 1e-6, "full height on the crest, mid-line")
	for off in [300.0, 900.0, 1500.0]:
		var n := MountainRelief.ridge_height(_ll_offset(c, 0.0, off),
				HEALPix.lonlat2vec(c.x, c.y), RADIUS, r)
		var s := MountainRelief.ridge_height(_ll_offset(c, 0.0, -off),
				HEALPix.lonlat2vec(c.x, c.y), RADIUS, r)
		assert_almost_eq(n, s, 1e-6, "symmetric at %.0f m" % off)
		assert_between(n, 0.0, 300.0)
	assert_eq(MountainRelief.ridge_height(_ll_offset(c, 0.0, 2100.0),
			HEALPix.lonlat2vec(c.x, c.y), RADIUS, r), 0.0, "past the foot")
	var end := MountainRelief.ridge_height(_ll_offset(c, 9990.0, 0.0),
			HEALPix.lonlat2vec(c.x, c.y), RADIUS, r)
	assert_lt(end, 1.0, "tapered to nothing at the end")
	assert_gt(MountainRelief.ridge_height(_ll_offset(c, 8500.0, 0.0),
			HEALPix.lonlat2vec(c.x, c.y), RADIUS, r), 100.0, "still tall one width from the end")


func test_ridge_asymmetry_makes_the_left_flank_the_wide_one() -> void:
	# Drawn west → east: LEFT is north. asymmetry 0.5 → north flank 3000 m,
	# south flank 1000 m.
	var c := Vector2(12.0, 20.0)
	var r := MountainRelief.prepare_ridge(_ridge(c, 20.0, {"asymmetry": 0.5}), _mpd)
	var d := HEALPix.lonlat2vec(c.x, c.y)
	var north := MountainRelief.ridge_height(_ll_offset(c, 0.0, 1500.0), d, RADIUS, r)
	var south := MountainRelief.ridge_height(_ll_offset(c, 0.0, 1500.0 * -1.0), d, RADIUS, r)
	assert_gt(north, 50.0, "1.5 km north: half-way down the gentle flank")
	assert_eq(south, 0.0, "1.5 km south: past the steep flank's foot")


func test_ridge_is_dropped_on_a_grid_coarser_than_its_width() -> void:
	var c := Vector2(12.0, 20.0)
	var r := MountainRelief.prepare_ridge(_ridge(c, 20.0), _mpd)
	var d := HEALPix.lonlat2vec(c.x, c.y)
	assert_gt(MountainRelief.offset(d, RADIUS, [], [r], 1000.0), 0.0)
	assert_eq(MountainRelief.offset(d, RADIUS, [], [r], 2000.0), 0.0)


# ===================================================================
# Sampler contract on a planet
# ===================================================================

func _chunk_pitch(nside: int) -> float:
	return HEALPix.pixel_side_length(nside, RADIUS) / float(RES)


func test_planet_gate_follows_the_features() -> void:
	assert_false(_pd.has_mountains())
	var base := _pd.sample_height_for_direction(HEALPix.lonlat2vec(_center_ll.x, _center_ll.y))
	_pd.set_mountain_overrides([_zone(_center_ll, 30.0)], [])
	assert_true(_pd.has_mountains())
	assert_ne(_pd.sample_height_for_direction(HEALPix.lonlat2vec(_center_ll.x, _center_ll.y)), base)
	_pd.set_mountain_overrides([], [])
	assert_false(_pd.has_mountains())
	assert_eq(_pd.sample_height_for_direction(HEALPix.lonlat2vec(_center_ll.x, _center_ll.y)), base,
			"without features the sampler is byte-identical to the heightmap")


func test_frame_path_equals_the_gameplay_path_over_a_whole_chunk() -> void:
	# The polygon edge (with its feather) and a ridge both cross the chunk.
	var edge_c := _ll_offset(_center_ll, 12000.0, 0.0)
	_pd.set_mountain_overrides([_zone(edge_c, 12.0, {"feather_m": 3000.0})],
			[_ridge(_ll_offset(_center_ll, 0.0, -1000.0), 40.0, {"roughness": 0.4, "warp_m": 300.0})])
	var frame := _pd.make_tile_frame()
	_pd.prepare_mountain_frame(frame, CHUNK_NSIDE, _hp_ipix)
	assert_true(frame.mtn_ready)
	assert_eq(frame.mtn.size(), 1)
	assert_eq(frame.rdg.size(), 1)
	var pitch := _chunk_pitch(CHUNK_NSIDE)
	assert_almost_eq(pitch, _pd.terrain_vertex_spacing_m(), 1e-9, "the fixture chunk IS the finest grid")
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES)
	var eps := HEALPix.pixel_side_length(CHUNK_NSIDE, 1.0) * (0.25 / float(RES))
	var moved := 0
	var checked := 0
	for yi in RES + 1:
		for xi in RES + 1:
			var dir_c: Vector3 = grid[yi][xi]
			var arbitrary := Vector3.UP if absf(dir_c.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
			var tan_u := dir_c.cross(arbitrary).normalized()
			var tan_v := dir_c.cross(tan_u).normalized()
			var edge := xi == 0 or xi == RES or yi == 0 or yi == RES
			for d in [dir_c, (dir_c - tan_u * eps).normalized(), (dir_c + tan_v * eps).normalized()]:
				var framed: float
				if edge:
					framed = _pd.sample_height_boundary(d, _export_ipix, -1, Vector2i(-1, -1),
							null, EXPORT_NSIDE, frame, pitch)
				else:
					framed = _pd.sample_height_for_direction(d, _export_ipix, -1, Vector2i(-1, -1),
							null, EXPORT_NSIDE, frame, pitch)
				var plain := _pd.sample_height_for_direction(d)
				var base := _pd._base_height_for_direction(d, _export_ipix, -1, Vector2i(-1, -1),
						null, EXPORT_NSIDE, frame)
				checked += 1
				if framed != base:
					moved += 1
				if framed != plain:
					assert_eq(plain, framed, "vertex (%d, %d): frame and gameplay paths differ" % [xi, yi])
					return
	assert_gt(moved, checked / 4, "the mountain must move a good part of the chunk")
	pass_test("%d samples identical on both paths, %d displaced" % [checked, moved])


func test_mesh_and_collision_stand_on_the_same_mountain() -> void:
	var edge_c := _ll_offset(_center_ll, 12000.0, 0.0)
	_pd.set_mountain_overrides([_zone(edge_c, 12.0, {"feather_m": 3000.0, "terrace_step_m": 60.0})],
			[_ridge(_ll_offset(_center_ll, 0.0, -1000.0), 40.0, {"asymmetry": 0.4})])
	var c := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(CHUNK_NSIDE, _hp_ipix) * RADIUS)
	var mesh := PlanetChunk.generate_mesh_healpix(_pd, CHUNK_NSIDE, _hp_ipix, RES, c)
	var shape := PlanetChunk.generate_collision_shape_healpix(_pd, CHUNK_NSIDE, _hp_ipix, RES)
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var seen := {}
	for i in (RES + 1) * (RES + 1):
		seen[verts[i]] = true
	var faces := shape.get_faces()
	assert_gt(faces.size(), 0)
	# The mesh snaps its chunk-local vertices to float32 (_world_to_local);
	# the collision keeps doubles and lets the body offset do it — the same
	# snap on the same numbers must land on the same mesh vertex.
	var missing := 0
	for f in faces:
		if not seen.has(PlanetChunk.snap_to_f32(f)):
			missing += 1
	assert_eq(missing, 0, "every collision vertex is a mesh vertex, bit for bit")
	# And the server's catch (no frame, pitch 0) lands on that very surface.
	var worst := 0.0
	for i in (RES + 1) * (RES + 1):
		var p := Vector3(verts[i]) + c
		var surf := _pd.crack_aware_surface_dist(p / p.length())
		worst = maxf(worst, absf(p.length() - surf))
	assert_lt(worst, 0.01, "below-surface catch vs mesh: %.4f m" % worst)


func test_coarse_chunks_keep_the_massif_and_lose_only_the_fine_octaves() -> void:
	# 200 km base wavelength, 6 octaves down to 6.25 km: the finest chunk
	# (2 km pitch) carries them all, a chunk at nside 2 (64 km pitch) only
	# the first.
	_pd.set_mountain_overrides([_zone(_center_ll, 60.0, {"wavelength_m": 200000.0, "octaves": 6})], [])
	# A chunk two levels ABOVE the export level still gets the zone.
	var coarse_nside := EXPORT_NSIDE / 4
	var coarse_ipix := _export_ipix >> 4
	var frame := _pd.make_tile_frame()
	_pd.prepare_mountain_frame(frame, coarse_nside, coarse_ipix)
	assert_eq(frame.mtn.size(), 1, "coarse chunks read the zone at their own level")
	var d := HEALPix.lonlat2vec(_center_ll.x, _center_ll.y)
	var fine := _pd.sample_height_for_direction(d)
	var coarse := _pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null,
			coarse_nside, frame, _chunk_pitch(coarse_nside))
	var base_f := _pd._base_height_for_direction(d)
	var base_c := _pd._base_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, coarse_nside, frame)
	assert_ne(coarse - base_c, 0.0, "the massif exists from afar")
	assert_ne(coarse - base_c, fine - base_f, "minus the octaves the coarse grid cannot carry")
	# Dropped octaves 1..5 weigh 0.80 of a 1.80 norm: at most 400·0.5·0.80/1.80 ≈ 89 m.
	assert_lt(absf((coarse - base_c) - (fine - base_f)), 90.0, "and only those")


# ===================================================================
# C# twins == GDScript reference
# ===================================================================

func test_native_set_equals_the_gdscript_reference() -> void:
	assert_true(MountainRelief.native_available(), "the C# assembly must be built")
	var c := Vector2(12.0, 20.0)
	var zones: Array = [
		MountainRelief.prepare_zone(_zone(c, 20.0, {"feather_m": 3000.0, "terrace_step_m": 80.0, "warp": 0.3})),
		MountainRelief.prepare_zone(_zone(_ll_offset(c, 5000.0, 0.0), 8.0, {"seed": 4, "lift_m": 60.0, "exponent": 2.0, "ridge": 0.9})),
	]
	var zf := _zone(c, 20.0)
	zf["coverage"] = "full"
	zf.erase("polygon")
	zones.append(MountainRelief.prepare_zone(zf))
	var ridges: Array = [
		MountainRelief.prepare_ridge(_ridge(c, 30.0, {"roughness": 0.4, "warp_m": 200.0, "asymmetry": 0.3, "terrace_step_m": 40.0}), _mpd),
	]
	var mset: RefCounted = MountainRelief.build_set(zones, ridges)
	assert_true(mset != null, "set built")  # GUT cannot stringify a C# object
	assert_eq(mset.ZoneCount(), 3)
	assert_eq(mset.RidgeCount(), 1)
	var worst := 0.0
	var nonzero := 0
	for i in 4000:
		# A cloud over the massif, its feather band, the ridge and outside.
		var ll := _ll_offset(c, fmod(i * 7919.0, 52000.0) - 26000.0, fmod(i * 104729.0, 52000.0) - 26000.0)
		var d := HEALPix.lonlat2vec(ll.x, ll.y)
		for pitch in [30.0, 700.0]:
			var gd := MountainRelief.offset(d, RADIUS, zones, ridges, pitch)
			var cs: float = mset.Offset(d, RADIUS, pitch)
			worst = maxf(worst, absf(gd - cs))
			if gd != 0.0:
				nonzero += 1
	assert_gt(nonzero, 2000)
	assert_lt(worst, 1e-9, "C# and GDScript disagree by %.12f m" % worst)


func test_native_and_gdscript_paths_build_the_same_planet_surface() -> void:
	var edge_c := _ll_offset(_center_ll, 12000.0, 0.0)
	var zs: Array = [_zone(edge_c, 12.0, {"feather_m": 3000.0})]
	var rs: Array = [_ridge(_ll_offset(_center_ll, 0.0, -1000.0), 40.0, {"asymmetry": 0.4})]
	_pd.set_mountain_overrides(zs, rs)
	assert_true(_pd._mtn_override_set != null)
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES)
	var native := PackedFloat64Array()
	for yi in RES + 1:
		for xi in RES + 1:
			native.append(_pd.sample_height_for_direction(grid[yi][xi]))
	MountainRelief.use_native = false
	_pd.set_mountain_overrides(zs, rs)
	assert_true(_pd._mtn_override_set == null)
	var worst := 0.0
	var k := 0
	for yi in RES + 1:
		for xi in RES + 1:
			worst = maxf(worst, absf(native[k] - _pd.sample_height_for_direction(grid[yi][xi])))
			k += 1
	MountainRelief.use_native = true
	assert_lt(worst, 1e-9, "paths disagree by %.12f m" % worst)


# ===================================================================
# Core (the rock impurity provenance)
# ===================================================================

func test_core_is_zero_on_the_plain_scaled_by_the_intensity_and_lod_free() -> void:
	var c := Vector2(12.0, 20.0)
	var z := MountainRelief.prepare_zone(_zone(c, 20.0, {"impurity_intensity": 1.3}))
	var half := MountainRelief.prepare_zone(_zone(c, 20.0, {"impurity_intensity": 0.65}))
	var sterile := MountainRelief.prepare_zone(_zone(c, 20.0, {"impurity_intensity": 0.0}))
	var far := HEALPix.lonlat2vec(c.x + 5.0, c.y)
	assert_eq(MountainRelief.core(far, RADIUS, [z], []), 0.0, "outside the polygon")
	var seen := 0.0
	for i in 200:
		var ll := _ll_offset(c, fmod(i * 7919.0, 30000.0) - 15000.0, fmod(i * 104729.0, 30000.0) - 15000.0)
		var d := HEALPix.lonlat2vec(ll.x, ll.y)
		var v := MountainRelief.core(d, RADIUS, [z], [])
		assert_between(v, 0.0, 1.3 + 1e-9, "envelope × shape × intensity")
		assert_almost_eq(MountainRelief.core(d, RADIUS, [half], []), v * 0.5, 1e-9, "linear in the intensity")
		assert_eq(MountainRelief.core(d, RADIUS, [sterile], []), 0.0, "a sterile massif")
		seen = maxf(seen, v)
	assert_gt(seen, 0.3, "the massif has a core")
	# Unlike offset(), the core takes no pitch: it cannot pop between LODs.
	var dz := HEALPix.lonlat2vec(c.x, c.y)
	assert_eq(MountainRelief.core(dz, RADIUS, [z], []), MountainRelief.core(dz, RADIUS, [z], []))


func test_ridge_core_peaks_on_the_crest_and_fades_to_the_foot() -> void:
	var c := Vector2(12.0, 20.0)
	var r := MountainRelief.prepare_ridge(_ridge(c, 30.0, {"impurity_intensity": 1.0}), _mpd)
	var crest := MountainRelief.core(HEALPix.lonlat2vec(c.x, c.y), RADIUS, [], [r])
	assert_almost_eq(crest, 1.0, 1e-6, "profile 1 × taper 1 on the crest")
	var prev := crest
	for off in [400.0, 1000.0, 1600.0, 1999.0]:
		var ll := _ll_offset(c, 0.0, off)
		var v := MountainRelief.core(HEALPix.lonlat2vec(ll.x, ll.y), RADIUS, [], [r])
		assert_lt(v, prev, "fades down the flank at %.0f m" % off)
		prev = v
	var foot := _ll_offset(c, 0.0, 2100.0)
	assert_eq(MountainRelief.core(HEALPix.lonlat2vec(foot.x, foot.y), RADIUS, [], [r]), 0.0)


func test_native_core_equals_the_gdscript_reference() -> void:
	assert_true(MountainRelief.native_available(), "the C# assembly must be built")
	var c := Vector2(12.0, 20.0)
	var zones: Array = [
		MountainRelief.prepare_zone(_zone(c, 20.0, {"feather_m": 3000.0, "warp": 0.3, "impurity_intensity": 1.2})),
		MountainRelief.prepare_zone(_zone(_ll_offset(c, 5000.0, 0.0), 8.0, {"seed": 4, "exponent": 2.0, "ridge": 0.9, "impurity_intensity": 0.7})),
	]
	var zf := _zone(c, 20.0)
	zf["coverage"] = "full"
	zf.erase("polygon")
	zones.append(MountainRelief.prepare_zone(zf))
	var ridges: Array = [
		MountainRelief.prepare_ridge(_ridge(c, 30.0, {"roughness": 0.4, "warp_m": 200.0, "asymmetry": 0.3, "impurity_intensity": 1.4}), _mpd),
	]
	var mset: RefCounted = MountainRelief.build_set(zones, ridges)
	assert_true(mset != null, "set built")
	var worst := 0.0
	var nonzero := 0
	for i in 4000:
		var ll := _ll_offset(c, fmod(i * 7919.0, 52000.0) - 26000.0, fmod(i * 104729.0, 52000.0) - 26000.0)
		var d := HEALPix.lonlat2vec(ll.x, ll.y)
		var gd := MountainRelief.core(d, RADIUS, zones, ridges)
		var cs: float = mset.Core(d, RADIUS)
		worst = maxf(worst, absf(gd - cs))
		if gd != 0.0:
			nonzero += 1
	assert_gt(nonzero, 2000)
	assert_lt(worst, 1e-9, "C# and GDScript cores disagree by %.12f" % worst)
	# And the planet-level query answers through the same set.
	_pd.set_mountain_overrides([_zone(c, 20.0, {"impurity_intensity": 1.2})], [])
	var d0 := HEALPix.lonlat2vec(c.x, c.y)
	assert_almost_eq(_pd.mountain_core(d0), MountainRelief.core(d0, RADIUS, _pd._mtn_override_zones, []), 1e-9)
	_pd.set_mountain_overrides([], [])
	assert_eq(_pd.mountain_core(d0), 0.0, "no mountains, no core")


func test_mask_is_the_envelope_and_the_ridge_profile_and_fades_the_cracks() -> void:
	assert_true(MountainRelief.native_available(), "the C# assembly must be built")
	var c := Vector2(12.0, 20.0)
	var zones: Array = [MountainRelief.prepare_zone(_zone(c, 20.0, {"feather_m": 3000.0, "impurity_intensity": 0.0}))]
	var ridges: Array = [MountainRelief.prepare_ridge(_ridge(_ll_offset(c, 0.0, 30000.0), 20.0, {"asymmetry": 0.3, "warp_m": 100.0}), _mpd)]
	var mset: RefCounted = MountainRelief.build_set(zones, ridges)
	const FADE := 600.0
	var centre := HEALPix.lonlat2vec(c.x, c.y)
	assert_eq(MountainRelief.mask(centre, RADIUS, zones, ridges, FADE), 1.0, "deep inside the massif")
	var inside := _ll_offset(c, 0.0, 19000.0)   # 1 km inside: past the 600 m fade, though well inside the 3 km feather
	assert_eq(MountainRelief.mask(HEALPix.lonlat2vec(inside.x, inside.y), RADIUS, zones, ridges, FADE), 1.0,
			"the fade is the crack's own 600 m, not the relief's feather")
	var edge := _ll_offset(c, 0.0, 19700.0)     # 300 m inside the outline
	var m_edge := MountainRelief.mask(HEALPix.lonlat2vec(edge.x, edge.y), RADIUS, zones, ridges, FADE)
	assert_between(m_edge, 0.05, 0.95, "300 m inside the outline: a ramp")
	var far := _ll_offset(c, 0.0, 60000.0)
	assert_eq(MountainRelief.mask(HEALPix.lonlat2vec(far.x, far.y), RADIUS, zones, ridges, FADE), 0.0)
	var crest := _ll_offset(c, 0.0, 30000.0)
	assert_almost_eq(MountainRelief.mask(HEALPix.lonlat2vec(crest.x, crest.y), RADIUS, zones, ridges, FADE), 1.0, 1e-6,
			"on the crest line, whatever its impurity")
	var foot := _ll_offset(c, 0.0, 30000.0 + 2000.0 * 1.3 - 200.0)   # 200 m inside the wide flank's foot
	var m_foot := MountainRelief.mask(HEALPix.lonlat2vec(foot.x, foot.y), RADIUS, zones, ridges, FADE)
	assert_between(m_foot, 0.02, 0.98, "200 m inside a ridge's foot: on the ramp")
	var worst := 0.0
	for i in 3000:
		var ll := _ll_offset(c, fmod(i * 7919.0, 60000.0) - 30000.0, fmod(i * 104729.0, 70000.0) - 30000.0)
		var d := HEALPix.lonlat2vec(ll.x, ll.y)
		worst = maxf(worst, absf(MountainRelief.mask(d, RADIUS, zones, ridges, FADE) - float(mset.Mask(d, RADIUS, FADE))))
	assert_lt(worst, 1e-9, "C# and GDScript masks disagree by %.12f" % worst)
	# The planet folds it into the crack depth factor.
	_pd.set_mountain_overrides([_zone(c, 20.0, {"feather_m": 3000.0})], [])
	_pd.corundum_default_biome = true
	assert_eq(_pd.crack_factor(centre), 0.0, "no canyon through a massif")
	assert_eq(_pd.crack_factor(HEALPix.lonlat2vec(far.x, far.y)), 1.0, "full depth on the plain")
	_pd.set_mountain_overrides([], [])
	assert_eq(_pd.crack_factor(centre), 1.0)
