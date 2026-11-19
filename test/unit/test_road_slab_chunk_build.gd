extends GutTest
## Integration suite: a real chunk of tarsis_3 (corundum planet, one highway)
## built by PlanetChunk — mesh AND collision — carries the road slab: the
## melted-corundum surface as its own mesh surface (vertex-tinted, parallax
## kept) and the slab's faces in the collision shape, on top of the ground.
##
## Runs on the published planet, read from the tile service like the game reads it, and skips
## cleanly when no service serves it.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_slab_chunk_build.gd

const PlanetDataScript := preload("res://scenes/planet/planet_data.gd")
const ModifierPackScript := preload("res://scenes/planet/modifier_pack.gd")
const PLANET_SCENE := "res://scenes/systems/tarsis/tarsis_3.tscn"
const RES := 16

var _pd: PlanetData
var _ipix: int = -1
## A tile whose roads are all on the ground (no grade profile): their slab hugs the terrain. Every
## highway of tarsis_3 is graded, so the highway tile's collision is a GradeBed, not that slab.
var _flat_ipix: int = -1
var _nside: int = 64
var _mesh: ArrayMesh
var _shape: ConcavePolygonShape3D
## Altitude above the sampled ground of every collision vertex past the grid.
var _slab_alts := PackedFloat64Array()


## Everything that PRINTS runs here: on a machine without the OpenTelemetry
## bridge every print is also an engine error, which GUT counts against
## whichever test it lands in (see test_corundum_default.gd). The chunk is
## built once and the tests only read it.
func before_all() -> void:
	PlanetDataScript.new().warm_biome_cache()
	# The planet as its scene configures it, prepared like the grade bake prepares it: with any
	# other setting the baked chasm crossings do not match (bridge_bake_key) and warm_bridge_plans
	# walks the whole planet's crossings at run time, minutes of it.
	_pd = _scene_planet_data(PLANET_SCENE)
	if _pd == null:
		return
	_pd.apply_chunk_manifest()
	if not _pd.connect_tile_service() or _pd.get_modifier_pack() == null:
		_pd = null  # no tile service: the tiles and the roads are not in the repository
		return
	_pd.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions("tarsis_3"))
	_pd.warm_biome_cache()
	# The first n64 tile holding a highway piece long enough to extrude. Streamed, the tile is
	# fetched now (blocking — a test, off the game's hot path).
	var pack = _pd.get_modifier_pack()
	var mpd := _pd.radius * PI / 180.0
	# Streamed, a level finer than the floor cannot be listed: the candidates are the n64 tiles under
	# the whole roads (read from the floor), sampled along each centerline.
	var candidates: Array[int] = []
	for r: Dictionary in _pd.get_whole_roads():
		var cl: PackedVector2Array = r["centerline"]
		@warning_ignore("integer_division")
		var step: int = maxi(1, cl.size() / 40)
		for k in range(0, cl.size(), step):
			var at := HEALPix.vec2pix_nest(_nside, HEALPix.lonlat2vec(cl[k].x, cl[k].y))
			if not candidates.has(at):
				candidates.append(at)
	for ipix in candidates:
		pack.source.fetch_now(_nside, int(ipix))
		var t: Dictionary = pack.decode_tile(pack.read_tile(_nside, int(ipix)), mpd,
				ModifierPackScript.MASK_ROAD)
		var long_piece := false
		var graded := false
		for r in t["roads"]:
			var extrudes := (r["centerline"] as PackedVector2Array).size() >= 4
			long_piece = long_piece or extrudes
			graded = graded or GradeSettings.is_profiled(r)
			if _ipix < 0 and extrudes and RoadTerrain.get_road_type(r) == "highway":
				_ipix = int(ipix)
		if _flat_ipix < 0 and long_piece and not graded:
			_flat_ipix = int(ipix)
		if _ipix >= 0 and _flat_ipix >= 0:
			break
	if _ipix < 0:
		return
	_pd.warm_bridge_plans()
	_pd.warm_grade_profiles()
	_mesh = PlanetChunk.generate_mesh_healpix(_pd, _nside, _ipix, RES,
			HEALPix.pix2vec_nest(_nside, _ipix) * _pd.radius)
	if _flat_ipix < 0:
		return
	_shape = PlanetChunk.generate_collision_shape(_pd, 0, 0.0, 0.0, 0.0, 0.0,
			RES, _nside, _flat_ipix)
	# Ground altitude under every slab vertex (the faces after the grid's),
	# sampled here because a missing heights.pack makes the sampler print.
	# Without the cracks, as the builder samples it: a slab spans a crack.
	var faces := _shape.get_faces()
	var origin := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(_nside, _flat_ipix) * _pd.radius)
	for i in range(RES * RES * 6, faces.size()):
		var d := (faces[i] + origin).normalized()
		_slab_alts.append((faces[i] + origin).length() - _pd.radius
				- _pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, -1, null, 0.0,
						CrackCarve.NONE))


## The PlanetData [param scene] gives its planet, read from the scene's state and copied (the
## sub-resource is shared with every instance of the scene), like tools/bake_grade_profiles.gd.
func _scene_planet_data(scene: String) -> PlanetData:
	var st := (load(scene) as PackedScene).get_state()
	for ni in st.get_node_count():
		for pi in st.get_node_property_count(ni):
			if st.get_node_property_name(ni, pi) == &"planet_data":
				var res: Variant = st.get_node_property_value(ni, pi)
				if res is PlanetData:
					return (res as PlanetData).duplicate(true)
	return null


func _skip() -> bool:
	if _pd != null and _ipix >= 0:
		return false
	pass_test("skipped: no tile service serving tarsis_3, or no highway piece at n%d" % _nside)
	return true


func test_highway_pieces_are_lane_sized() -> void:
	if _skip():
		return
	var roads := _pd.get_roads_for_chunk(_nside, _ipix)
	var seen := 0
	for r in roads:
		if RoadTerrain.get_road_type(r) != "highway":
			continue
		seen += 1
		assert_almost_eq(float(r["half_width_m"]), 7.25, 1e-6,
				"the decoder sizes the highway from its lanes, not the stored 12 m")
	assert_gt(seen, 0)


func test_mesh_carries_the_corundum_slab_surface() -> void:
	if _skip():
		return
	var mesh := _mesh
	assert_not_null(mesh)
	var found := false
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		if mat is StandardMaterial3D and (mat as StandardMaterial3D).vertex_color_use_as_albedo \
				and (mat as StandardMaterial3D).heightmap_enabled:
			found = true
			var arrays := mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			assert_eq(colors.size(), verts.size(), "the tint is baked per vertex")
			assert_true(arrays[Mesh.ARRAY_TANGENT] != null, "tangents for the normal map")
			# The ground's own colour (PlanetChunk.road_ground_tint): milky, iron or a dark emery
			# outcrop, so only "tinted at all" holds everywhere.
			var c := colors[0]
			assert_true(c != Color.WHITE and c.r + c.g + c.b > 0.1,
					"the ground's corundum tint, neither white nor black: %s" % c)
			assert_eq((mat as StandardMaterial3D).cull_mode, BaseMaterial3D.CULL_DISABLED)
	assert_true(found, "one surface uses the melted-corundum material with parallax kept")
	var side_found := false
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		if mat is StandardMaterial3D and (mat as StandardMaterial3D).vertex_color_use_as_albedo \
				and not (mat as StandardMaterial3D).heightmap_enabled \
				and (mat as StandardMaterial3D).normal_texture == null:
			side_found = true
	assert_true(side_found, "the flanks / skirts use the plain melted corundum, no engraving")


func test_collision_holds_the_slab_above_the_ground() -> void:
	if _skip():
		return
	if _flat_ipix < 0:
		pass_test("no n%d tile with only ungraded roads in this export" % _nside)
		return
	var shape := _shape
	assert_not_null(shape)
	var faces := shape.get_faces()
	var grid_faces := RES * RES * 6
	assert_gt(faces.size(), grid_faces, "the slab's faces come after the grid's")
	# The slab's top sits 8 cm above the ground it was sampled on, its
	# flanks 10 cm below: the extra faces span exactly that band around the
	# terrain (checked against the sampler the builder used).
	var above := 0
	var below := 0
	assert_eq(_slab_alts.size(), faces.size() - grid_faces)
	for alt in _slab_alts:
		if absf(alt - RoadTerrain.SURFACE_THICKNESS_M) < 0.02:
			above += 1
		elif absf(alt + RoadTerrain.RIBBON_BURY_M) < 0.02:
			below += 1
	assert_gt(above, 0, "top vertices at +8 cm")
	assert_gt(below, 0, "flank bottoms at -10 cm")
	assert_eq(above + below, faces.size() - grid_faces, "every slab vertex is one or the other")
