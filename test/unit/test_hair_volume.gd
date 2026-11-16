extends GutTest
## The light a head of hair stops (HairVolume): its hairs' cross-section per unit of volume, made once per
## style with its mesh, and the ambient light that gets in between them.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_hair_volume.gd -gexit


## A slab of straight hairs, [param count] x [param count], 5 cm long along x, laid 1 mm apart in y and z:
## two vertices per point, as HairStrands builds them. [param thin] hairs have a root density that makes the
## shader drop them.
func _slab(count: int, thin: bool = false) -> Array:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for j in count:
		for k in count:
			for i in 6:
				var p := Vector3(0.01 * i, 0.001 * j, 0.001 * k)
				pos.append(p)
				pos.append(p)
				var density: float = 0.0 if thin else 1.0
				col.append(Color(0.0, 0.5, 0.5, density))
				col.append(Color(0.0, 0.5, 0.5, density))
	return [pos, col]


func test_a_slab_of_hair_stops_light_by_its_cross_section() -> void:
	var slab: Array = _slab(20)
	var v: HairVolume = HairVolume.build(slab[0], slab[1], 6, 0.0008)
	assert_false(v.data.is_empty())
	assert_lte(maxi(v.dims.x, maxi(v.dims.y, v.dims.z)), HairVolume.RESOLUTION)
	# The box holds every hair, with a cell to spare.
	assert_lt(v.origin.x, 0.0)
	assert_gt(v.origin.x + v.size.x, 0.05)
	# 400 hairs of 5 cm, 0.8 mm wide, over the slab's volume (5 cm x 2 cm x 2 cm, blurred a little wider).
	var total: float = 0.0
	for i in range(0, v.data.size(), 2):
		total += v.data[i]
	var cross_section: float = 400.0 * 0.05 * 0.0008
	assert_almost_eq(total * pow(v.cell, 3.0), cross_section, cross_section * 0.02, "the cross-section is kept")
	# Denser in the middle than at the edge, nothing outside.
	var middle := Vector3(0.025, 0.0095, 0.0095)
	assert_gt(v.extinction_at(middle), 0.0)
	assert_eq(v.extinction_at(Vector3(0.025, 0.5, 0.0)), 0.0, "outside the box")
	# The ambient light: less of it inside than at the surface.
	var corner_cell := v.origin + Vector3.ONE * (0.5 * v.cell)
	assert_gt(v.ambient_at(corner_cell), v.ambient_at(middle), "the middle of the hair is darker")
	assert_lt(v.ambient_at(middle), 0.5, "deep in a dense slab, little ambient light gets in")


func test_hairs_the_shader_drops_stop_no_light() -> void:
	var slab: Array = _slab(10, true)
	var v: HairVolume = HairVolume.build(slab[0], slab[1], 6, 0.0008)
	var total: float = 0.0
	for i in range(0, v.data.size(), 2):
		total += v.data[i]
	assert_eq(total, 0.0, "a density of 0 drops every hair (COLOR.g 0.5 > 0.1)")


func test_a_head_of_hair_carries_its_volume() -> void:
	var cut := HairCut.preset("medium_wavy")
	var assets: Array = HairGroom.assets_for(cut)
	var strands: HumanAssetData = assets[1]
	var t0: int = Time.get_ticks_usec()
	var mesh: ArrayMesh = HairStrands.mesh_of(strands)
	var built_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	var v: HairVolume = HairStrands.volume_of(strands)
	assert_not_null(v, "a head of hair's mesh comes with its volume")
	assert_same(v, HairStrands.volume_of(strands), "made once, with the mesh")
	assert_true(mesh.has_meta(&"hair_volume"))
	# The hair's volume covers the mesh's box.
	var box: AABB = mesh.get_aabb()
	assert_true(AABB(v.origin, v.size).grow(0.001).encloses(box), "the volume holds the hairs")
	var arrays: Array = mesh.surface_get_arrays(0)
	t0 = Time.get_ticks_usec()
	HairVolume.build(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_COLOR], strands.strand_size, HairStrands.HAIR_WIDTH)
	var volume_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	gut.p("mesh + volume %.0f ms (volume %.0f ms), %s cells of %.1f mm" % [built_ms, volume_ms, v.dims, v.cell * 1000.0])
	assert_not_null(v.texture())
	assert_eq(v.texture().get_depth(), v.dims.z)
	HairStrands.forget(strands)
	assert_null(HairStrands.volume_of(strands), "forgotten with its mesh")


func test_the_csharp_twin_makes_the_same_volume() -> void:
	HumanBuilder.prepare()  # makes the C# twin on this (main) thread
	assert_true(HairGroom.native_twin() != null, "HairGroomNative.cs must load (rebuild the C#)")
	var asset: HumanAssetData = HairGroom.assets_for(HairCut.preset("long_straight"))[1]
	var arrays: Array = HairStrands.build(asset).surface_get_arrays(0)
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var col: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var started: int = Time.get_ticks_usec()
	var fast: HairVolume = HairVolume.build(pos, col, asset.strand_size, HairStrands.HAIR_WIDTH, true)
	var fast_ms: float = (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var slow: HairVolume = HairVolume.build(pos, col, asset.strand_size, HairStrands.HAIR_WIDTH, false)
	var slow_ms: float = (Time.get_ticks_usec() - started) / 1000.0
	assert_eq(fast.dims, slow.dims, "same grid")
	assert_true(fast.origin.is_equal_approx(slow.origin), "same corner")
	assert_almost_eq(fast.cell, slow.cell, 1e-9)
	assert_eq(fast.data.size(), slow.data.size())
	var worst: float = 0.0
	for i in fast.data.size():
		worst = maxf(worst, absf(fast.data[i] - slow.data[i]) / maxf(absf(slow.data[i]), 1.0))
	assert_lt(worst, 1e-4, "C# and GDScript stop the same light (worst %s)" % String.num_scientific(worst))
	gut.p("volume: C# %.1f ms, GDScript %.0f ms" % [fast_ms, slow_ms])
