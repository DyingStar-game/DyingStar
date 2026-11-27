extends GutTest
## Hair as hairs (HairStrands): a style's guide strands become one mesh of thin strips -- several hairs per
## guide, two vertices per point, with their own levels of detail -- and fit() carries it onto a head.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_hair_strands.gd -gexit


func _style() -> HumanAssetData:
	var asset := HumanAssetData.new()
	asset.id = &"test_style"
	asset.kind = &"hair"
	asset.style = &"strands"
	asset.strand_size = 4
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	for k in 10:
		var root := Vector3(0.05 * cos(k * 0.6), 1.72, 0.05 * sin(k * 0.6))
		for i in 4:
			points.append(root + Vector3(0.0, -0.02 * i, 0.0) + (root - Vector3(0.0, 1.63, 0.0)).normalized() * 0.005 * i)
		colours.append(Color(1.0, 0.5, float(k) / 9.0, 1.0))
	asset.strand_points = points
	asset.color = colours
	asset.strand_params = {"children": 3, "clump": 0.004, "clump_tip": 0.5, "frizz": 0.001, "longest": 0.07, "centre": [0.0, 1.63, 0.0]}
	return asset


func test_a_style_becomes_strips_of_hair() -> void:
	var asset: HumanAssetData = _style()
	var mesh: ArrayMesh = HairStrands.build(asset)
	var arrays: Array = mesh.surface_get_arrays(0)
	var hairs: int = 10 * 3
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(pos.size(), hairs * 4 * 2, "two vertices per point of every hair")
	assert_eq((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), hairs * 3 * 6)
	for v in range(0, pos.size(), 2):
		assert_eq(pos[v], pos[v + 1], "a strip has no width: the shader gives it one")
	# PACKED_FORMAT: no UV nor tangent; CUSTOM0 = direction + share along; the normal compressed.
	assert_eq(mesh.surface_get_format(0) & HairStrands.PACKED_FORMAT, HairStrands.PACKED_FORMAT, "packed")
	assert_eq(mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_TEX_UV, 0, "no UV")
	# What the GPU holds a vertex: position + normal 12 bytes (the tangent bit the engine sets takes none), colour 4,
	# CUSTOM0 4 -- 20 where the plain layout took 32.
	var held: Dictionary = RenderingServer.mesh_get_surface(mesh.get_rid(), 0)
	assert_eq((held["vertex_data"] as PackedByteArray).size() + (held["attribute_data"] as PackedByteArray).size(),
			pos.size() * 20, "20 bytes a vertex")
	var c0: PackedByteArray = arrays[Mesh.ARRAY_CUSTOM0]
	var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for v in pos.size():
		var share: float = c0.decode_s8(v * 4 + 3) / 127.0
		assert_almost_eq(share, float((v % 8) / 2) / 3.0, 0.005, "how far along the hair, point after point")
		var direction := Vector3(c0.decode_s8(v * 4), c0.decode_s8(v * 4 + 1), c0.decode_s8(v * 4 + 2)) / 127.0
		assert_almost_eq(direction.length(), 1.0, 0.02, "a direction: the shader tells the layout by it")
		assert_almost_eq(nrm[v].dot((pos[v] - Vector3(0.0, 1.63, 0.0)).normalized()), 1.0, 0.001, "away from the centre")
	# The first hair of a guide follows the guide itself, straying a little towards its tip.
	assert_true(pos[0].is_equal_approx(asset.strand_points[0]))
	for i in 4:
		assert_lt(pos[i * 2].distance_to(asset.strand_points[i]), 0.0021)
	# The others are rooted within the clump, and no longer than the guide.
	var third_child_root: Vector3 = pos[(2 * 10) * 4 * 2]
	assert_lt(third_child_root.distance_to(asset.strand_points[0]), 0.0041)
	var colour: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_almost_eq(colour[0].r, 0.0, 1e-6, "a root is at the start of its length")
	assert_gt(colour[6].r, 0.5, "a tip is far along the style's longest strand")
	assert_same(HairStrands.mesh_of(asset), HairStrands.mesh_of(asset), "made once")
	HairStrands.clear()


func test_fit_carries_roots_to_a_head() -> void:
	var from := PackedVector3Array()
	var to := PackedVector3Array()
	# A head 10 % wider, 5 % taller, moved: any linear change is found exactly.
	var change := Transform3D(Basis(Vector3(1.1, 0.0, 0.0), Vector3(0.02, 1.05, 0.0), Vector3(0.0, 0.0, 0.97)), Vector3(0.01, -0.03, 0.02))
	for k in 40:
		var p := Vector3(0.09 * sin(k * 1.7), 1.6 + 0.1 * cos(k * 0.9), 0.09 * cos(k * 2.3))
		from.append(p)
		to.append(change * p)
	var found: Transform3D = HairStrands.fit(from, to)
	for k in 40:
		assert_lt((found * from[k]).distance_to(to[k]), 1e-6)
	assert_eq(HairStrands.fit(PackedVector3Array([Vector3.ZERO]), PackedVector3Array([Vector3.ONE])), Transform3D.IDENTITY,
			"too few points: left alone")


func test_every_style_of_the_bank_fits_real_heads() -> void:
	var morph: HumanMorph = HumanBuilder.prepare()
	var worst: float = 0.0
	for seed_value in [3, 14, 27]:
		var look: CharacterAppearance = CharacterAppearance.random(seed_value)
		var order: HumanBuilder.Order = HumanBuilder.order_for(look, false)
		var points: PackedVector3Array = morph.morph(order.targets, order.weights)
		for asset: HumanAssetData in morph.bank.assets:
			if asset.style != &"strands":
				continue
			var roots: PackedVector3Array = HairStrands.neutral_roots(asset)
			var on_head: PackedVector3Array = morph.fit(points, asset)
			var found: Transform3D = HairStrands.fit(roots, on_head)
			for k in range(0, roots.size(), 37):
				worst = maxf(worst, (found * roots[k]).distance_to(on_head[k]))
	assert_lt(worst, 0.006, "a style's roots land within millimetres of the scalp (%.1f mm)" % (worst * 1000.0))


func test_the_csharp_twin_makes_the_same_hairs() -> void:
	HumanBuilder.prepare()  # makes the C# twin on this (main) thread
	assert_true(HairGroom.native_twin() != null, "HairGroomNative.cs must load (rebuild the C#)")
	var asset: HumanAssetData = HairGroom.assets_for(HairCut.preset("medium_wavy"))[1]
	var started: int = Time.get_ticks_usec()
	var fast: ArrayMesh = HairStrands.build(asset, true)
	var fast_ms: float = (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var slow: ArrayMesh = HairStrands.build(asset, false)
	var slow_ms: float = (Time.get_ticks_usec() - started) / 1000.0
	var a: Array = fast.surface_get_arrays(0)
	var b: Array = slow.surface_get_arrays(0)
	assert_eq(a[Mesh.ARRAY_INDEX], b[Mesh.ARRAY_INDEX], "same strips")
	var pa: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var pb: PackedVector3Array = b[Mesh.ARRAY_VERTEX]
	var worst: float = 0.0
	for k in range(0, mini(pa.size(), pb.size()), 13):
		worst = maxf(worst, pa[k].distance_to(pb[k]))
	assert_lt(worst, 1e-5, "C# and GDScript place the hairs alike (worst %s m)" % String.num_scientific(worst))
	assert_eq(a[Mesh.ARRAY_COLOR], b[Mesh.ARRAY_COLOR], "same colours")
	assert_eq(a[Mesh.ARRAY_CUSTOM0], b[Mesh.ARRAY_CUSTOM0], "same directions, packed alike")
	gut.p("hairs: C# %.0f ms, GDScript %.0f ms" % [fast_ms, slow_ms])


func test_the_csharp_twin_packs_the_same_bytes() -> void:
	HumanBuilder.prepare()  # makes the C# twin on this (main) thread
	assert_true(HairGroom.native_twin() != null, "HairGroomNative.cs must load (rebuild the C#)")
	var tan := PackedFloat32Array()
	var uv := PackedVector2Array()
	for v in 200:
		var a := float(v) * 0.37
		tan.append_array([sin(a), cos(a * 1.3), -0.5, 1.0])
		uv.append(Vector2(float(v % 2), fmod(float(v) / 199.0, 1.0)))
	# Halfway values too: both twins round them away from zero.
	tan[0] = 0.5 / 127.0
	tan[1] = -0.5 / 127.0
	assert_eq(HairStrands.pack(tan, uv, true), HairStrands.pack(tan, uv, false), "CUSTOM0 alike")
