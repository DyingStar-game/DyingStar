extends GutTest
## VolcanoRelief: the procedural volcanoes, from the pure cone / crater
## profile up to the sampler contract — they ride the mountain machinery, so
## the mesh, the collision and a gameplay query stand on one volcano, and the
## C# twin (MountainVolcanoNative) is bit-identical to the GDScript reference.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_volcano_relief.gd

const TILE_RES := 16
const EXPORT_NSIDE := 8
const DEPTH := 6
const CHUNK_NSIDE := 64
const RES := 8
const RADIUS := 1000000.0
const MAX_HEIGHT := 500.0

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
	_pd.set_mountain_overrides([], [], [])


func after_all() -> void:
	MountainRelief.use_native = true


func _planet() -> PlanetData:
	var pd := PlanetData.new()
	pd.planet_name = "volcanoes"
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


## A volcano record at [param c] sized for this 1000 km test planet (finest
## pitch ≈ 2 km): 60 km foot, 8 km crater.
func _rec(c: Vector2, over: Dictionary = {}) -> Dictionary:
	var style := {"base_diameter_m": 60000.0, "height_m": 3000.0, "crater_diameter_m": 16000.0,
			"crater_depth_m": 500.0, "seed": 7}
	style.merge(over, true)
	return VolcanoRelief.debug_record("stratovolcano", c, style)


## The same record without any noise: a clean axisymmetric profile.
func _clean(c: Vector2, over: Dictionary = {}) -> VolcanoRelief.Volcano:
	var o := {"roughness": 0.0, "gullies": 0.0, "irregularity": 0.0}
	o.merge(over, true)
	return VolcanoRelief.prepare(_rec(c, o))


func _dir_at(c: Vector2, east_m: float) -> Vector3:
	var ll := _ll_offset(c, east_m, 0.0)
	return HEALPix.lonlat2vec(ll.x, ll.y)


# ===================================================================
# Profile
# ===================================================================

func test_every_type_has_a_rim_a_floor_and_a_foot() -> void:
	var c := Vector2(12.0, 20.0)
	for type: String in VolcanoRelief.PRESETS:
		var z := VolcanoRelief.debug_record(type, c, {"roughness": 0.0, "gullies": 0.0, "irregularity": 0.0})
		var v := VolcanoRelief.prepare(z)
		assert_eq(VolcanoRelief.offset(_dir_at(c, v.rb * 1.01), RADIUS, v, 1.0), 0.0, type + ": past the foot")
		var top := VolcanoRelief.offset(v.c, RADIUS, v, 1.0)
		if v.rc > 0.0 and v.floor_frac > 0.0:
			assert_almost_eq(top, v.h - v.dc, 1e-6, type + ": crater floor")
		elif v.rc <= 0.0:
			assert_almost_eq(top, v.h, 1e-6, type + ": dome summit")
		# Just outside the rim, the full height (less than a metre off on the flank).
		if v.rc > 0.0:
			var rim := VolcanoRelief.offset(_dir_at(c, v.rc + 0.01), RADIUS, v, 1.0)
			assert_almost_eq(rim, v.h, v.h * 0.01, type + ": rim")
		# A noise-free flank only goes down.
		var prev := INF
		for k in 20:
			var r := v.rc + (v.rb - v.rc) * (float(k) + 0.5) / 20.0
			var h := VolcanoRelief.offset(_dir_at(c, r), RADIUS, v, 1.0)
			assert_lt(h, prev, "%s: the flank falls (r = %.0f m)" % [type, r])
			prev = h


func test_flank_exponent_shapes_the_cone() -> void:
	var c := Vector2(12.0, 20.0)
	var mid := 0.5
	var convex := _clean(c, {"flank_exponent": 0.5, "crater_diameter_m": 0.0})
	var concave := _clean(c, {"flank_exponent": 2.0, "crater_diameter_m": 0.0})
	var d := _dir_at(c, convex.rb * mid)
	assert_gt(VolcanoRelief.offset(d, RADIUS, convex, 1.0), VolcanoRelief.offset(d, RADIUS, concave, 1.0),
			"a dome stands fuller at mid-flank than a stratovolcano")
	assert_eq(VolcanoRelief.snap_exponent(1.8), 2.0)
	assert_eq(VolcanoRelief.snap_exponent(0.7), 0.5)


func test_lod_drops_the_crater_then_the_cone_never_fades_them() -> void:
	var c := Vector2(12.0, 20.0)
	var v := _clean(c)
	assert_almost_eq(VolcanoRelief.offset(v.c, RADIUS, v, 100.0), v.h - v.dc, 1e-6)
	assert_eq(VolcanoRelief.offset(v.c, RADIUS, v, v.rc), v.h, "pitch ≥ crater radius: no crater")
	assert_eq(VolcanoRelief.offset(v.c, RADIUS, v, 0.5 * v.rb), 0.0, "pitch ≥ half the foot: no cone")


func test_lobes_and_gullies_move_the_flank() -> void:
	var c := Vector2(12.0, 20.0)
	var clean := _clean(c)
	var rough := VolcanoRelief.prepare(_rec(c, {"gullies": 1.0, "irregularity": 0.3, "roughness": 0.0}))
	var differ := 0
	for k in 36:
		var a := TAU * k / 36.0
		var ll := _ll_offset(c, cos(a) * 20000.0, sin(a) * 20000.0)
		var d := HEALPix.lonlat2vec(ll.x, ll.y)
		if VolcanoRelief.offset(d, RADIUS, rough, 10.0) != VolcanoRelief.offset(d, RADIUS, clean, 10.0):
			differ += 1
	assert_gt(differ, 30, "gullies and lobes change the flank all around")


# ===================================================================
# Core / mask
# ===================================================================

func test_core_is_zero_at_the_foot_and_deepest_in_the_crater() -> void:
	var c := Vector2(12.0, 20.0)
	var v := _clean(c, {"impurity_intensity": 1.0})
	assert_eq(VolcanoRelief.core(_dir_at(c, v.rb * 1.05), RADIUS, v), 0.0)
	var flank := VolcanoRelief.core(_dir_at(c, (v.rc + v.rb) * 0.5), RADIUS, v)
	assert_almost_eq(flank, 0.5, 1e-3, "halfway down the flank")
	assert_almost_eq(VolcanoRelief.core(v.c, RADIUS, v), 1.0 + VolcanoRelief.CRATER_CORE_BONUS, 1e-9)
	var sterile := _clean(c, {"impurity_intensity": 0.0})
	assert_eq(VolcanoRelief.core(v.c, RADIUS, sterile), 0.0)


func test_mask_fades_the_cracks_from_the_foot() -> void:
	var c := Vector2(12.0, 20.0)
	var v := _clean(c)
	assert_eq(VolcanoRelief.mask(_dir_at(c, v.rb * 1.05), RADIUS, v, 600.0), 0.0)
	assert_eq(VolcanoRelief.mask(v.c, RADIUS, v, 600.0), 1.0)
	var m := VolcanoRelief.mask(_dir_at(c, v.rb - 300.0), RADIUS, v, 600.0)
	assert_between(m, 0.3, 0.7, "a ramp over fade_m inside the foot")


# ===================================================================
# C# twin == GDScript reference, bit for bit
# ===================================================================

func test_native_set_is_bit_identical_to_the_gdscript_reference() -> void:
	assert_true(VolcanoRelief.native_available(), "the C# assembly must be built")
	var c := Vector2(12.0, 20.0)
	var vols: Array = [
		VolcanoRelief.prepare(_rec(c, {"gullies": 0.8, "irregularity": 0.3, "roughness": 0.1})),
		VolcanoRelief.prepare(VolcanoRelief.debug_record("lava_dome", _ll_offset(c, 20000.0, 5000.0),
				{"base_diameter_m": 15000.0, "height_m": 800.0, "seed": 3})),
		VolcanoRelief.prepare(VolcanoRelief.debug_record("caldera", _ll_offset(c, -15000.0, -8000.0),
				{"base_diameter_m": 30000.0, "seed": 9, "impurity_intensity": 1.3})),
	]
	var mset: RefCounted = MountainRelief.build_set([], [], vols)
	assert_true(mset != null, "set built")  # GUT cannot stringify a C# object
	assert_eq(mset.VolcanoCount(), 3)
	var mismatches := 0
	var nonzero := 0
	for i in 4000:
		var ll := _ll_offset(c, fmod(i * 7919.0, 80000.0) - 40000.0, fmod(i * 104729.0, 80000.0) - 40000.0)
		var d := HEALPix.lonlat2vec(ll.x, ll.y)
		for pitch in [2.0, 30.0, 700.0, 4000.0]:
			var gd := MountainRelief.offset(d, RADIUS, [], [], pitch, vols)
			var cs: float = mset.Offset(d, RADIUS, pitch)
			if gd != cs:
				mismatches += 1
			if gd != 0.0:
				nonzero += 1
		if MountainRelief.core(d, RADIUS, [], [], vols) != float(mset.Core(d, RADIUS)):
			mismatches += 1
		if MountainRelief.mask(d, RADIUS, [], [], 600.0, vols) != float(mset.Mask(d, RADIUS, 600.0)):
			mismatches += 1
	assert_gt(nonzero, 4000)
	assert_eq(mismatches, 0, "C# and GDScript must agree bit for bit")


# ===================================================================
# Planet contract
# ===================================================================

func test_the_sampler_sees_the_volcano_and_forgets_it() -> void:
	var d := HEALPix.lonlat2vec(_center_ll.x, _center_ll.y)
	var base := _pd.sample_height_for_direction(d)
	assert_false(_pd.has_mountains())
	_pd.set_mountain_overrides([], [], [_rec(_ll_offset(_center_ll, 10000.0, 0.0))])
	assert_true(_pd.has_mountains(), "a volcano alone switches the mountain machinery on")
	assert_gt(_pd.sample_height_for_direction(d), base + 100.0)
	assert_gt(_pd.mountain_core(d), 0.0)
	assert_gt(_pd.mountain_mask(d), 0.0)
	_pd.set_mountain_overrides([], [], [])
	assert_eq(_pd.sample_height_for_direction(d), base)


func test_frame_path_equals_the_gameplay_path_over_a_whole_chunk() -> void:
	_pd.set_mountain_overrides([], [], [_rec(_ll_offset(_center_ll, 9000.0, 3000.0),
			{"gullies": 0.8, "irregularity": 0.2, "roughness": 0.08})])
	var frame := _pd.make_tile_frame()
	_pd.prepare_mountain_frame(frame, CHUNK_NSIDE, _hp_ipix)
	assert_eq(frame.vol.size(), 1)
	var pitch := _pd.terrain_vertex_spacing_m()
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES)
	var moved := 0
	var checked := 0
	for yi in RES + 1:
		for xi in RES + 1:
			var d: Vector3 = grid[yi][xi]
			var framed := _pd.sample_height_for_direction(d, _export_ipix, -1, Vector2i(-1, -1),
					null, EXPORT_NSIDE, frame, pitch)
			var plain := _pd.sample_height_for_direction(d)
			var base := _pd._base_height_for_direction(d)
			checked += 1
			if framed != base:
				moved += 1
			if framed != plain:
				assert_eq(plain, framed, "vertex (%d, %d): frame and gameplay paths differ" % [xi, yi])
				return
	assert_gt(moved, checked / 2, "the volcano covers the chunk")


func test_mesh_and_collision_stand_on_the_same_volcano() -> void:
	_pd.set_mountain_overrides([], [], [_rec(_ll_offset(_center_ll, 9000.0, 3000.0))])
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
	_pd.set_mountain_overrides([], [], [_rec(_ll_offset(_center_ll, 9000.0, 3000.0),
			{"gullies": 0.8, "roughness": 0.08})])
	assert_true(_pd._mtn_override_set != null)
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES)
	var native := PackedFloat64Array()
	for yi in RES + 1:
		for xi in RES + 1:
			native.append(_pd.sample_height_for_direction(grid[yi][xi]))
	MountainRelief.use_native = false
	_pd.set_mountain_overrides([], [], [_rec(_ll_offset(_center_ll, 9000.0, 3000.0),
			{"gullies": 0.8, "roughness": 0.08})])
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


func test_each_volcano_is_owned_by_one_chunk_per_level() -> void:
	var c := _ll_offset(_center_ll, 9000.0, 3000.0)
	_pd.set_mountain_overrides([], [], [_rec(c)])
	var d := HEALPix.lonlat2vec(c.x, c.y)
	for ns in [2, EXPORT_NSIDE, CHUNK_NSIDE]:
		var home := HEALPix.vec2pix_nest(ns, d)
		assert_eq(_pd.volcanoes_owned_by(ns, home).size(), 1, "n%d: the summit's chunk owns it" % ns)
		var others := 0
		var nbs := {}
		for nb in HEALPix.get_neighbors_nest(ns, home).values():
			nbs[int(nb)] = true
		nbs.erase(home)  # a coarse face corner can list the pixel itself
		for nb in nbs:
			if int(nb) >= 0:
				others += _pd.volcanoes_owned_by(ns, int(nb)).size()
		assert_eq(others, 0, "n%d: no neighbour owns it too" % ns)


func test_debug_injection_builds_a_volcano() -> void:
	var pd := _planet()
	pd.debug_volcano_enabled = true
	pd.debug_volcano_lonlat = _center_ll
	pd.debug_volcano_type = "shield"
	pd.debug_volcano_style = {"base_diameter_m": 50000.0}
	pd.warm_mountains()
	assert_true(pd.has_mountains())
	assert_eq(pd._mtn_override_volcanoes.size(), 1)
	var v: VolcanoRelief.Volcano = pd._mtn_override_volcanoes[0]
	assert_eq(v.type, "shield")
	assert_eq(v.rb, 25000.0)
	assert_eq(pd._mtn_override_zones.size(), 0, "no debug massif unless asked")


func test_lake_shore_radius_matches_the_exporter() -> void:
	var v := VolcanoRelief.prepare(VolcanoRelief.debug_record("stratovolcano", Vector2.ZERO,
			{"has_lava_lake": 1}))
	# Golden value of test_modifier_pack_py.py (volcanoes.lake_shore_radius).
	assert_almost_eq(VolcanoRelief.lake_shore_radius(v), 131.1180221884, 1e-6)
	var dry := VolcanoRelief.prepare(VolcanoRelief.debug_record("stratovolcano", Vector2.ZERO, {}))
	assert_eq(VolcanoRelief.lake_shore_radius(dry), -1.0)


func test_a_flow_starting_by_a_lake_starts_on_its_shore() -> void:
	var c := Vector2(12.0, 20.0)
	var v := VolcanoRelief.prepare(VolcanoRelief.debug_record("stratovolcano", c,
			{"has_lava_lake": 1, "roughness": 0.0, "gullies": 0.0, "irregularity": 0.0}))
	var r := VolcanoRelief.lake_shore_radius(v)
	var far := _ll_offset(c, 3000.0, 0.0)
	var inside := VolcanoRelief.snap_flow_to_lakes(
			PackedVector2Array([_ll_offset(c, 20.0, 0.0), far]), [v], RADIUS)
	assert_eq(inside.size(), 2, "a source inside the lake is replaced")
	var d0 := HEALPix.lonlat2vec(inside[0].x, inside[0].y)
	assert_almost_eq((d0 - v.c).length() * RADIUS, r, 0.01)
	var near := VolcanoRelief.snap_flow_to_lakes(
			PackedVector2Array([_ll_offset(c, r + 150.0, 0.0), far]), [v], RADIUS)
	assert_eq(near.size(), 3, "150 m from the shore: the shore is prepended")
	var away := VolcanoRelief.snap_flow_to_lakes(
			PackedVector2Array([_ll_offset(c, r + 250.0, 0.0), far]), [v], RADIUS)
	assert_eq(away.size(), 2, "250 m away: untouched")
	# The shore is at the lake's level: the crater wall meets the lava there.
	assert_almost_eq(VolcanoRelief.offset(d0, RADIUS, v, 1.0), v.h - v.dc + v.fill, 0.05)


func test_a_flow_leaving_the_lake_tilts_the_rim() -> void:
	var c := Vector2(12.0, 20.0)
	var rec := VolcanoRelief.debug_record("stratovolcano", c,
			{"has_lava_lake": 1, "roughness": 0.0, "gullies": 0.0, "irregularity": 0.0})
	var flow := PackedVector2Array([_ll_offset(c, 20.0, 0.0), _ll_offset(c, 3000.0, 0.0)])
	var br := VolcanoRelief.lake_breach(rec, [flow], RADIUS)
	assert_false(br.is_empty())
	rec.merge(br, true)
	var v := VolcanoRelief.prepare(rec)
	var lake := v.h - v.dc + v.fill
	# The rim just outside the crater, on the flow's side (east) and opposite.
	var east := VolcanoRelief.offset(_dir_at(c, v.rc + 0.01), RADIUS, v, 1.0)
	var west := VolcanoRelief.offset(_dir_at(c, -(v.rc + 0.01)), RADIUS, v, 1.0)
	assert_almost_eq(east, lake + VolcanoRelief.RIM_FREEBOARD_M, 1.0, "rim 2 m above the lake")
	assert_almost_eq(west, v.h, v.h * 0.01, "opposite rim untouched")
	assert_almost_eq(VolcanoRelief.offset(v.c, RADIUS, v, 1.0), v.h - v.dc, 1e-6, "same floor")
	# The flow now starts near the lowered rim, and the C# twin agrees bit for bit.
	var snapped := VolcanoRelief.snap_flow_to_lakes(flow, [v], RADIUS)
	var d0 := HEALPix.lonlat2vec(snapped[0].x, snapped[0].y)
	assert_gt((d0 - v.c).length() * RADIUS, VolcanoRelief.lake_shore_radius(v) + 20.0)
	var mset: RefCounted = MountainRelief.build_set([], [], [v])
	var mismatches := 0
	for i in 2000:
		var ll := _ll_offset(c, fmod(i * 7919.0, 1600.0) - 800.0, fmod(i * 104729.0, 1600.0) - 800.0)
		var d := HEALPix.lonlat2vec(ll.x, ll.y)
		for pitch in [1.0, 30.0, 700.0]:
			if MountainRelief.offset(d, RADIUS, [], [], pitch, [v]) != float(mset.Offset(d, RADIUS, pitch)):
				mismatches += 1
	assert_eq(mismatches, 0)
