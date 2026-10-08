extends GutTest
## RockFieldRelief: the rocky terrain laid over the ground — the pure block /
## butte / strata arithmetic (golden values of the Python twin, zero mean, the
## LOD gate) up to the sampler contract: it rides the mountain machinery, so
## the mesh, the collision and a gameplay query stand on the same rocks, and
## the C# twin (RockFieldNative) is bit-identical to the GDScript reference.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_rock_field_relief.gd

const TILE_RES := 16
const EXPORT_NSIDE := 8
const DEPTH := 6
const CHUNK_NSIDE := 64
const RES := 8
## A 1000 km test planet: its finest pitch is ~2 km, so the planet tests use
## fields scaled up to match (blocks of km, ledges of 100 m).
const RADIUS := 1000000.0
const MAX_HEIGHT := 500.0
## The golden record's sphere (test_rock_field_relief_py.py uses the same).
const GOLDEN_RADIUS := 3467000.0

var _pd: PlanetData = null
var _mpd: float = RADIUS * PI / 180.0
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
	_pd.set_mountain_overrides([], [], [], [])


func after_all() -> void:
	MountainRelief.use_native = true
	RockFieldRelief.use_native = true


func _planet() -> PlanetData:
	var pd := PlanetData.new()
	pd.planet_name = "rocks"
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


func _ll_offset(c: Vector2, east_m: float, north_m: float) -> Vector2:
	return c + Vector2(east_m / _mpd / cos(deg_to_rad(c.y)), north_m / _mpd)


## The record of test_rock_field_relief_py.py's golden values.
func _golden_record() -> Dictionary:
	var c := Vector3(0.3, 0.5, 0.8).normalized()
	return {"coverage": "full", "cell_m": 150.0, "step_m": 12.0, "riser": 0.25,
			"joint_depth_m": 3.0, "joint_width_m": 30.0, "joint_mean_m": 1.0, "butte_rate": 0.3,
			"butte_height_m": 40.0, "butte_cell_m": 600.0, "butte_wall_m": 50.0,
			"butte_mean_m": 0.5, "seed": 7, "cx": c.x, "cy": c.y, "cz": c.z,
			"wx": 0.6, "wy": 0.0, "wz": -0.8, "k": 0.5, "dpx": 0.1, "dpy": -0.05, "dpz": 0.02}


## A debug field scaled for this 1000 km planet (finest pitch ≈ 2 km):
## 9 km blocks, 120 m ledges, 40 km butte lattice.
func _rec(c: Vector2, over: Dictionary = {}, radius_km: float = 60.0) -> Dictionary:
	var props := RockFieldRelief.resolve_debug("very_rugged", "slabs", {})
	props.merge({"cell_m": 9000.0, "step_m": 120.0, "riser": 0.2, "joint_depth_m": 30.0,
			"joint_width_m": 2500.0, "butte_rate": 0.3, "butte_height_m": 250.0,
			"butte_cell_m": 40000.0, "butte_wall_m": 3000.0, "feather_m": 5000.0, "seed": 11},
			true)
	props.merge(over, true)
	return RockFieldRelief.debug_record(c, radius_km, RADIUS, props)


# ===================================================================
# Arithmetic
# ===================================================================

func test_offset_matches_the_python_twin() -> void:
	var golden := {
		0.0: [26.443037170598878, 2.5718848638778127, -3.708317237013702, 1.968365625182191,
				0.02666837863876026, -3.5847115675763974, -1.1980966065874548,
				-0.16047086626908502],
		25.0: [26.443037170598878, 2.5718848638778127, -3.708317237013702, 1.968365625182191,
				0.02666837863876026, -3.5847115675763974, -1.1980966065874548,
				-0.16047086626908502],
		60.0: [27.47338218262058, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5],
	}
	for use_native in [false, true]:
		RockFieldRelief.use_native = use_native
		var f := RockFieldRelief.prepare(_golden_record())
		for pitch: float in golden:
			var want: Array = golden[pitch]
			for i in 8:
				var d := Vector3(0.3 + 0.0001 * i, 0.5 - 0.00013 * i, 0.8 + 0.00007 * i).normalized()
				var h_below := 1000.0 + 37.5 * i
				var got := RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, pitch, h_below)
				assert_almost_eq(got, float(want[i]), 1e-9, "pitch %s, point %d" % [pitch, i])
				if f.native != null:
					assert_eq(float(f.native.FieldOffset(d, GOLDEN_RADIUS, pitch, h_below)), got,
							"C#, pitch %s, point %d" % [pitch, i])
	RockFieldRelief.use_native = true


func test_chalk_knobs_match_the_python_twin() -> void:
	var rec := _golden_record()
	rec.merge({"step_m": 0.0, "joint_depth_m": 0.0, "joint_mean_m": 0.0, "butte_rate": 0.0,
			"butte_height_m": 0.0, "butte_mean_m": 0.0, "dpx": 0.0, "dpy": 0.0, "dpz": 0.0,
			"lump_m": 5.0, "lump_wavelength_m": 160.0}, true)
	var golden := {
		25.0: [-0.17320621486957039, -2.761124710363702, -3.791354638811648, -3.297374426876215],
		60.0: [0.18393195299612142, -2.5375770651884686, -3.6749888031056717, -4.853436800186989],
		100.0: [0.0, 0.0, 0.0, 0.0],
	}
	for use_native in [false, true]:
		RockFieldRelief.use_native = use_native
		var f := RockFieldRelief.prepare(rec)
		for pitch: float in golden:
			for i in 4:
				var d := Vector3(0.3 + 0.0001 * i, 0.5 - 0.00013 * i, 0.8 + 0.00007 * i).normalized()
				var got := RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, pitch, 1000.0)
				assert_almost_eq(got, float(golden[pitch][i]), 1e-9, "pitch %s, point %d" % [pitch, i])
				if f.native != null:
					assert_eq(float(f.native.FieldOffset(d, GOLDEN_RADIUS, pitch, 1000.0)), got,
							"C#, pitch %s, point %d" % [pitch, i])
	RockFieldRelief.use_native = true


func test_chalk_style_resolves_to_knobs_and_its_shader_code() -> void:
	var props := RockFieldRelief.resolve_debug("rugged", "chalk", {})
	assert_eq(props["step_m"], 0.0, "no ledges")
	assert_eq(props["joint_depth_m"], 0.0, "no grooves")
	assert_eq(props["butte_rate"], 0.0, "no buttes")
	assert_eq(props["lump_m"], 5.0)
	var f := RockFieldRelief.prepare(RockFieldRelief.debug_record(Vector2(10.0, 20.0), 1.0,
			GOLDEN_RADIUS, props))
	assert_eq(RockFieldRelief.shader_code(f), 3 + 8 * 4, "level 3 + 8 × chalk")


func test_voronoi_matches_the_python_twin() -> void:
	var v := RockFieldRelief.voronoi(1234.56, -789.01, 42.42, 7)
	assert_eq(v.slice(0, 6), [1234, -790, 42, 1235, -790, 42])
	assert_almost_eq(float(v[6]), 0.19644441893865838, 1e-12)


func test_terms_are_zero_mean_on_the_flat_and_on_a_slope() -> void:
	var rec := _golden_record()
	rec["butte_rate"] = 0.0
	rec["joint_depth_m"] = 0.0
	var f := RockFieldRelief.prepare(rec)
	var c := f.c
	var a := Vector3(0.0, 1.0, 0.0)
	var u := c.cross(a).normalized()
	var v := c.cross(u)
	for slope in [0.0, 0.7]:
		var acc := 0.0
		var n := 0
		for ia in 60:
			for ib in 60:
				var su := (ia - 30.0) * 37.0
				var sv := (ib - 30.0) * 41.0
				var d := (c * GOLDEN_RADIUS + u * su + v * sv).normalized()
				acc += RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, 25.0, 500.0 + slope * su)
				n += 1
		assert_almost_eq(acc / n, 0.0, 0.08 * f.step_m,
				"the blocks neither raise nor sink the ground (slope %s)" % slope)


func test_each_term_is_dropped_past_its_cell_never_faded() -> void:
	var f := RockFieldRelief.prepare(_golden_record())
	var d := Vector3(0.3, 0.5, 0.8).normalized()
	# Blocks (150 m cells) go at 50 m, buttes (600 m) at 200 m.
	assert_ne(RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, 49.0, 1000.0),
			RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, 51.0, 1000.0))
	assert_eq(RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, 200.0, 1000.0), 0.0)
	assert_eq(RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, 5000.0, 1000.0), 0.0)


func test_a_slope_becomes_ledges() -> void:
	# Along a 45° slope the terraced ground climbs by flats and walls: most
	# 5 m steps rise far less than the slope, a few far more.
	var rec := _golden_record()
	rec["butte_rate"] = 0.0
	rec["joint_depth_m"] = 0.0
	rec["riser"] = 0.1
	var f := RockFieldRelief.prepare(rec)
	var c := f.c
	var u := c.cross(Vector3(0.0, 1.0, 0.0)).normalized()
	var flat := 0
	var steep := 0
	var prev := NAN
	for i in 400:
		var s := i * 5.0
		var d := (c * GOLDEN_RADIUS + u * s).normalized()
		var h := s + RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, 25.0, s)
		if not is_nan(prev):
			var rise := h - prev
			if rise < 1.0:
				flat += 1
			elif rise > 10.0:
				steep += 1
		prev = h
	assert_gt(flat, 120, "ledges: much of the run is (nearly) flat")
	assert_gt(steep, 10, "walls: some 5 m steps climb more than twice the slope")


func test_the_ground_is_continuous_across_block_edges() -> void:
	var rec := _golden_record()
	rec["butte_rate"] = 0.0
	var f := RockFieldRelief.prepare(rec)
	var c := f.c
	var u := c.cross(Vector3(0.0, 1.0, 0.0)).normalized()
	var v := c.cross(u)
	var jumps := 0
	var n := 0
	for row in 20:
		var prev := NAN
		for i in 600:
			var d := (c * GOLDEN_RADIUS + u * (i * 0.5) + v * (row * 53.0)).normalized()
			var h := RockFieldRelief.field_offset(d, GOLDEN_RADIUS, f, 25.0, 700.0)
			if not is_nan(prev) and absf(h - prev) > 0.25 * f.step_m:
				jumps += 1
			prev = h
			n += 1
	assert_lt(float(jumps) / n, 0.002, "no step between two points 0.5 m apart (only Voronoi corners)")


func test_native_set_is_bit_identical_to_the_gdscript_reference() -> void:
	assert_true(RockFieldRelief.native_available(), "the C# assembly must be built")
	var c := Vector2(12.0, 20.0)
	var fields: Array = [
		RockFieldRelief.prepare(_rec(c)),
		RockFieldRelief.prepare(_rec(_ll_offset(c, 30000.0, 5000.0),
				{"dip_deg": 15.0, "elongation": 3.0, "seed": 3}, 40.0)),
	]
	var mset: RefCounted = MountainRelief.build_set([], [], [], fields)
	assert_true(mset != null, "set built")  # GUT cannot stringify a C# object
	assert_eq(mset.RockCount(), 2)
	var mismatches := 0
	var nonzero := 0
	for i in 3000:
		var ll := _ll_offset(c, fmod(i * 7919.0, 140000.0) - 70000.0,
				fmod(i * 104729.0, 140000.0) - 70000.0)
		var d := HEALPix.lonlat2vec(ll.x, ll.y)
		var h_below := 300.0 + fmod(i * 13.0, 900.0)
		for pitch in [100.0, 2000.0, 5000.0]:
			var gd := RockFieldRelief.offset(d, RADIUS, fields, pitch, h_below)
			var cs: float = mset.Rock(d, RADIUS, pitch, h_below)
			if gd != cs:
				mismatches += 1
			if gd != 0.0:
				nonzero += 1
		var sg := RockFieldRelief.surface(d, RADIUS, fields)
		var sc: Vector3 = mset.RockSurface(d, RADIUS)
		if not sg.is_equal_approx(sc):
			mismatches += 1
	assert_gt(nonzero, 2000)
	assert_eq(mismatches, 0, "C# and GDScript must agree bit for bit")


# ===================================================================
# Planet contract
# ===================================================================

func test_the_sampler_sees_the_rocks_and_forgets_them() -> void:
	var d := HEALPix.lonlat2vec(_center_ll.x, _center_ll.y)
	var base := _pd.sample_height_for_direction(d)
	assert_false(_pd.has_mountains())
	_pd.set_mountain_overrides([], [], [], [_rec(_center_ll)])
	assert_true(_pd.has_mountains(), "a rock field alone switches the mountain machinery on")
	var moved := 0
	for i in 40:
		var ll := _ll_offset(_center_ll, i * 1000.0, i * 500.0)
		var di := HEALPix.lonlat2vec(ll.x, ll.y)
		if _pd.sample_height_for_direction(di) != _pd._base_height_for_direction(di):
			moved += 1
	assert_gt(moved, 30, "the field moves the ground")
	assert_gt(_pd.rock_surface(d).x, 0.0, "the shader sees the field")
	_pd.set_mountain_overrides([], [], [], [])
	assert_eq(_pd.sample_height_for_direction(d), base)
	assert_eq(_pd.rock_surface(d), Vector3.ZERO)


func test_rocks_lay_over_a_mountain() -> void:
	var mtn := {"coverage": "full", "amplitude_m": 2000.0, "wavelength_m": 60000.0,
			"octaves": 3, "lift_m": 500.0, "seed": 4, "feather_m": 250.0}
	_pd.set_mountain_overrides([mtn], [], [], [])
	var frame_less: PackedFloat64Array = []
	var ds: Array[Vector3] = []
	for i in 30:
		var ll := _ll_offset(_center_ll, i * 2300.0, -i * 700.0)
		ds.append(HEALPix.lonlat2vec(ll.x, ll.y))
		frame_less.append(_pd.sample_height_for_direction(ds[i]))
	_pd.set_mountain_overrides([mtn], [], [], [_rec(_center_ll)])
	var pitch := _pd.terrain_vertex_spacing_m()
	var f := RockFieldRelief.prepare(_rec(_center_ll))
	for i in 30:
		var want := frame_less[i] + RockFieldRelief.offset(ds[i], RADIUS, [f],
				maxf(0.0, pitch), frame_less[i])
		assert_almost_eq(_pd.sample_height_for_direction(ds[i]), want, 1e-6,
				"the rocks terrace the mountain's ground (sample %d)" % i)


func test_frame_path_equals_the_gameplay_path_over_a_whole_chunk() -> void:
	_pd.set_mountain_overrides([], [], [], [_rec(_center_ll, {"dip_deg": 10.0})])
	var frame := _pd.make_tile_frame()
	_pd.prepare_mountain_frame(frame, CHUNK_NSIDE, _hp_ipix)
	assert_eq(frame.rck.size(), 1)
	var pitch := _pd.terrain_vertex_spacing_m()
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES)
	var moved := 0
	var checked := 0
	for yi in RES + 1:
		for xi in RES + 1:
			var d: Vector3 = grid[yi][xi]
			# A rim vertex goes through the boundary sampler, as in the chunk builders: the
			# tile it is forced into and its canonical tile can disagree by an ulp, which the
			# rocks (unlike a large positive relief) do not round away.
			var framed: float
			if xi == 0 or yi == 0 or xi == RES or yi == RES:
				framed = _pd.sample_height_boundary(d, _export_ipix, -1, Vector2i(-1, -1), null,
						EXPORT_NSIDE, frame, pitch)
			else:
				framed = _pd.sample_height_for_direction(d, _export_ipix, -1, Vector2i(-1, -1),
						null, EXPORT_NSIDE, frame, pitch)
			var plain := _pd.sample_height_for_direction(d)
			checked += 1
			if framed != _pd._base_height_for_direction(d):
				moved += 1
			if framed != plain:
				assert_eq(plain, framed, "vertex (%d, %d): frame and gameplay paths differ" % [xi, yi])
				return
	assert_gt(moved, checked / 2, "the field covers the chunk")


func test_mesh_and_collision_stand_on_the_same_rocks() -> void:
	_pd.set_mountain_overrides([], [], [], [_rec(_center_ll)])
	var c := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(CHUNK_NSIDE, _hp_ipix) * RADIUS)
	var mesh := PlanetChunk.generate_mesh_healpix(_pd, CHUNK_NSIDE, _hp_ipix, RES, c)
	var shape := PlanetChunk.generate_collision_shape_healpix(_pd, CHUNK_NSIDE, _hp_ipix, RES)
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var seen := {}
	for i in (RES + 1) * (RES + 1):
		seen[verts[i]] = true
	var faces := shape.get_faces()
	assert_gt(faces.size(), 0)
	var missing := 0
	for f in faces:
		if not seen.has(PlanetChunk.snap_to_f32(f)):
			missing += 1
	assert_eq(missing, 0, "every collision vertex is a mesh vertex, bit for bit")


func test_native_and_gdscript_paths_build_the_same_planet_surface() -> void:
	_pd.set_mountain_overrides([], [], [], [_rec(_center_ll, {"elongation": 2.5})])
	assert_true(_pd._mtn_override_set != null)
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES)
	var native := PackedFloat64Array()
	for yi in RES + 1:
		for xi in RES + 1:
			native.append(_pd.sample_height_for_direction(grid[yi][xi]))
	MountainRelief.use_native = false
	_pd.set_mountain_overrides([], [], [], [_rec(_center_ll, {"elongation": 2.5})])
	assert_true(_pd._mtn_override_set == null, "GDScript path forced")
	var k := 0
	var mismatches := 0
	for yi in RES + 1:
		for xi in RES + 1:
			if _pd.sample_height_for_direction(grid[yi][xi]) != native[k]:
				mismatches += 1
			k += 1
	MountainRelief.use_native = true
	assert_eq(mismatches, 0)


func test_debug_injection_builds_one_field_per_level() -> void:
	_pd.debug_rock_enabled = true
	_pd.debug_rock_lonlat = _center_ll
	_pd.debug_rock_radius_km = 1.5
	_pd.set_mountain_overrides([], [], [], [])
	_pd._build_debug_mountains()
	assert_eq(_pd._mtn_override_rocks.size(), RockFieldRelief.LEVELS.size())
	for i in RockFieldRelief.LEVELS.size():
		var f: RockFieldRelief.Field = _pd._mtn_override_rocks[i]
		assert_eq(f.level, i)
		assert_eq(f.ruggedness, RockFieldRelief.LEVELS[i])
	assert_eq((_pd._mtn_override_rocks[0] as RockFieldRelief.Field).step_m, 0.0, "flat has no ledges")
	assert_gt((_pd._mtn_override_rocks[4] as RockFieldRelief.Field).joint_mean_m, 0.0,
			"the joint mean is measured")
	_pd.debug_rock_enabled = false
	_pd.set_mountain_overrides([], [], [], [])


# ===================================================================
# Shader mask and scree
# ===================================================================

func test_chunk_mesh_carries_the_rock_mask_only_under_a_field() -> void:
	var c := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(CHUNK_NSIDE, _hp_ipix) * RADIUS)
	var bare := PlanetChunk.generate_mesh_healpix(_pd, CHUNK_NSIDE, _hp_ipix, RES, c)
	assert_eq(bare.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM1, 0, "no field, no CUSTOM1")
	_pd.set_mountain_overrides([], [], [], [_rec(_center_ll)])
	var mesh := PlanetChunk.generate_mesh_healpix(_pd, CHUNK_NSIDE, _hp_ipix, RES, c)
	assert_ne(mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM1, 0, "the field's mask is baked")
	var custom: PackedFloat32Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_CUSTOM1]
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(custom.size(), verts.size() * 4)
	assert_gt(custom[0], 0.0, "intensity")
	assert_eq(custom[2], 4.0, "level 4 (very rugged) + 8 × type 0 (slabs)")
	assert_almost_eq(custom[3], (c + verts[0]).length() - RADIUS, 0.01, "the vertex's altitude")
	assert_false(mesh.has_meta("rock_scree"), "a 2 km pitch is far too coarse for scree")


func _grid(res: int, tilt: float) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var rock := PackedFloat32Array()
	var n := Vector3(tilt, 1.0, 0.0).normalized()
	for yi in res + 1:
		for xi in res + 1:
			var x := xi * 5.0
			verts.append(Vector3(x, x * tilt, yi * 5.0))
			normals.append(Vector3(-n.x, n.y, 0.0))
			rock.append_array([1.0 if xi < res / 2 + 1 else 0.0, 6.0, 4.0, 0.0])
	return [verts, normals, rock]


func test_scree_is_deterministic_and_stays_in_the_field() -> void:
	var g := _grid(16, 0.0)
	var a := RockFieldScree.place(g[0], g[1], PackedColorArray(), g[2], 16, 1234, Vector3.UP)
	var b := RockFieldScree.place(g[0], g[1], PackedColorArray(), g[2], 16, 1234, Vector3.UP)
	assert_eq(a, b)
	assert_gt(a.size(), 0)
	assert_eq(a.size() % RockFieldScree.STRIDE, 0)
	for i in a.size() / RockFieldScree.STRIDE:
		assert_lt(a[i * RockFieldScree.STRIDE], 16 * 5.0 * 0.5 + 5.0, "only where the mask is")
	assert_ne(RockFieldScree.place(g[0], g[1], PackedColorArray(), g[2], 16, 999, Vector3.UP), a, "per chunk")


func test_scree_gathers_on_the_slopes() -> void:
	var flat := _grid(16, 0.0)
	var steep := _grid(16, 1.2)
	var nf := RockFieldScree.place(flat[0], flat[1], PackedColorArray(), flat[2], 16, 7, Vector3.UP).size()
	var ns := RockFieldScree.place(steep[0], steep[1], PackedColorArray(), steep[2], 16, 7, Vector3.UP).size()
	assert_gt(float(ns), nf * 1.5)


func test_scree_node_builds_from_the_meta() -> void:
	var g := _grid(16, 0.5)
	var mesh := ArrayMesh.new()
	var rocks := RockFieldScree.place(g[0], g[1], PackedColorArray(), g[2], 16, 3, Vector3.UP)
	mesh.set_meta("rock_scree", RockFieldScree.pack(rocks))
	var node := RockFieldScree.build(mesh, Vector3(0.0, 1000.0, 0.0))
	assert_not_null(node)
	var total := 0
	for ch in node.get_children():
		total += (ch as MultiMeshInstance3D).multimesh.instance_count
	assert_eq(total, rocks.size() / RockFieldScree.STRIDE)
	node.free()
	assert_null(RockFieldScree.build(ArrayMesh.new(), Vector3.ZERO))
