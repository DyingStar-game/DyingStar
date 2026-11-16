extends GutTest
## Hair that moves (HairMotion): which guides of a grown cut may move and from how far along them
## (HumanAssetData.strand_free), the few strands that are simulated and how every guide follows them
## (HairMotionBinding).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_hair_motion.gd -gexit


func before_all() -> void:
	HumanBuilder.prepare()  # the C# twins, made on this (main) thread


func _is(code: float, want: float) -> bool:
	return absf(code - want) < 1e-6


func _grown(preset: String) -> HumanAssetData:
	for asset: HumanAssetData in HairGroom.new(HairHead.shared()).grow(HairCut.preset(preset)):
		if asset.style == &"strands":
			return asset
	return null


func test_a_loose_cut_moves_past_its_fixed_length_and_its_fringe_near_the_root() -> void:
	var asset: HumanAssetData = _grown("bob")
	assert_not_null(asset)
	assert_eq(asset.strand_free.size(), asset.color.size(), "one code per guide")
	var fringe: int = 0
	for code in asset.strand_free:
		assert_true(_is(code, HairMotionBinding.GLOBAL_FIXED) or _is(code, HairMotionBinding.FRINGE_FIXED),
				"a loose cut's guide moves past the fixed length, or is its fringe (%f)" % code)
		fringe += 1 if _is(code, HairMotionBinding.FRINGE_FIXED) else 0
	assert_gt(fringe, 0, "a bob's fringe moves near its root")


func test_a_ponytail_moves_its_tail_and_keeps_the_scalp() -> void:
	var asset: HumanAssetData = _grown("ponytail")
	var tail: int = 0
	var rigid: int = 0
	for code in asset.strand_free:
		tail += 1 if _is(code, HairMotionBinding.TAIL_FIXED) else 0
		rigid += 1 if code >= HairMotionBinding.RIGID else 0
	assert_eq(tail, 420, "every hair of the tail swings from the tie")
	assert_gt(rigid, 0, "the scalp's hairs, gathered to the tie, stay put")
	var bun: HumanAssetData = _grown("bun")
	assert_true(Array(bun.strand_free).any(func(c: float) -> bool: return _is(c, HairMotionBinding.BUN_FIXED)),
			"a bun's hairs quiver")


func test_the_binding_follows_the_simulated_strands_it_is_nearest() -> void:
	for preset: String in ["long_straight", "ponytail", "bob"]:
		var asset: HumanAssetData = _grown(preset)
		var t0: int = Time.get_ticks_usec()
		var b: HairMotionBinding = HairMotionBinding.build(asset)
		gut.p("%s: %d guides, binding %.0f ms" % [preset, asset.color.size(), (Time.get_ticks_usec() - t0) / 1000.0])
		assert_not_null(b, "%s moves" % preset)
		assert_lte(b.sims.size(), HairMotionBinding.SIM_GUIDES)
		assert_eq(b.sim_rest.size(), b.sims.size() * HairMotionBinding.DENSE)
		var unique := {}
		for s in b.sims:
			unique[s] = true
			assert_lt(asset.strand_free[s], HairMotionBinding.RIGID, "%s: only guides that move are simulated" % preset)
		assert_eq(unique.size(), b.sims.size(), "%s: each simulated strand once" % preset)
		for k in b.guides:
			var pair: int = int(b.binding[k * 4 + 2])
			assert_lt(pair / 64, b.sims.size())
			assert_lt(pair % 64, b.sims.size())
			assert_between(b.binding[k * 4 + 3], 0.0, 1.0)
		var root: Vector3 = asset.strand_points[b.sims[0] * asset.strand_size]
		assert_almost_eq(b.sim_rest[0], root, Vector3.ONE * 1e-5, "%s: a simulated strand's first point is its root" % preset)
	var tail_cut: HumanAssetData = _grown("ponytail")
	var tb: HairMotionBinding = HairMotionBinding.build(tail_cut)
	for code in tb.sim_free:
		assert_lt(code, HairMotionBinding.RIGID, "a ponytail simulates its tail and its flyaways")


func test_a_short_cut_does_not_move() -> void:
	var buzz: HumanAssetData = _grown("buzz")
	assert_true(buzz == null or HairMotionBinding.build(buzz) == null, "a buzz cut has nothing to swing")
	var b: HairMotionBinding = HairMotionBinding.build(_grown("short_crop"))
	if b != null:
		for length in b.sim_length:
			assert_gt(length, HairMotionBinding.FIXED_LENGTH * 0.5, "only the longer hairs of a crop move")


func test_a_moving_style_keeps_room_for_its_swing() -> void:
	var asset: HumanAssetData = _grown("long_straight")
	var mesh: ArrayMesh = HairStrands.build(asset)
	assert_true(mesh.has_meta(&"hair_motion"))
	var lod: Dictionary = mesh.get_meta(&"hair_lod")
	assert_true(mesh.custom_aabb.encloses((lod["bounds"] as AABB).grow(HairMotionBinding.MAX_SWING * 0.99)),
			"the bounds keep room for the hairs' swing")
	assert_eq(int(lod["guides"]), asset.color.size())


func test_the_binding_twins_agree() -> void:
	assert_true(HairMotionBinding.native_instance() != null, "the C# twin is built (or this tests nothing: rebuild the C#)")
	for preset: String in ["long_straight", "ponytail", "curly"]:
		var asset: HumanAssetData = _grown(preset)
		var t0: int = Time.get_ticks_usec()
		var fast: HairMotionBinding = HairMotionBinding.build(asset, true)
		var t1: int = Time.get_ticks_usec()
		var slow: HairMotionBinding = HairMotionBinding.build(asset, false)
		gut.p("%s: binding C# %.1f ms, GDScript %.0f ms" % [preset, (t1 - t0) / 1000.0, (Time.get_ticks_usec() - t1) / 1000.0])
		assert_eq(fast.sims, slow.sims, "%s: the same strands simulated" % preset)
		assert_eq(fast.sim_free, slow.sim_free)
		assert_eq(fast.binding.size(), slow.binding.size())
		var worst: float = 0.0
		for i in fast.binding.size():
			worst = maxf(worst, absf(fast.binding[i] - slow.binding[i]))
		assert_lt(worst, 1e-5, "%s: the same binding" % preset)
		var far: float = 0.0
		for i in fast.sim_rest.size():
			far = maxf(far, fast.sim_rest[i].distance_to(slow.sim_rest[i]))
		assert_lt(far, 1e-6, "%s: the same points at rest" % preset)


# --- the simulation (HairMotionNative.Step) -------------------------------------------------------------------------

const WIDTH: int = HairMotionBinding.SIM_GUIDES * HairMotionBinding.SAMPLES


func _sim(binding: HairMotionBinding) -> Object:
	var sim: Object = HairMotionBinding.native_instance()
	var head: HairHead = HairHead.shared()
	sim.call("Configure", head.sdf, head.sdf_origin, head.sdf_cell, head.sdf_size, head.centre.y - 0.1)
	sim.call("SetAvatar", 0, binding.sim_rest, binding.sim_free, binding.sim_length, HairMotionBinding.FIXED_LENGTH)
	return sim


## One frame of the avatar in slot 0: its displacements (Vector3 per strand point, mesh frame).
func _step(sim: Object, at: Transform3D, gravity: Vector3, wind: Vector3, caps: Array = [], reset: bool = false) -> PackedVector3Array:
	var v := PackedFloat64Array([0.0, 1.0 if reset else 0.0, 1.0])
	for axis in [at.basis.x, at.basis.y, at.basis.z, at.origin]:
		v.append_array([axis.x, axis.y, axis.z])
	v.append_array([gravity.x, gravity.y, gravity.z, wind.x, wind.y, wind.z, float(caps.size())])
	for c: Array in caps:
		v.append_array([c[0].x, c[0].y, c[0].z, c[1].x, c[1].y, c[1].z, c[2]])
	var floats: PackedFloat32Array = (sim.call("Step", 1.0 / 60.0, v, 1, WIDTH) as PackedByteArray).to_float32_array()
	var out := PackedVector3Array()
	for k in WIDTH:
		out.append(Vector3(floats[k * 4], floats[k * 4 + 1], floats[k * 4 + 2]))
	return out


## Whether sample [param j] of a simulated strand moves: all but the first, where the strand stops staying put.
func _free_at(_b: HairMotionBinding, _s: int, j: int) -> bool:
	return j > 0


## Sample [param j] of simulated strand [param s] at rest, as HairMotionNative.SetAvatar takes it from the dense points.
func _sample_rest(b: HairMotionBinding, s: int, j: int) -> Vector3:
	var length: float = b.sim_length[s]
	var free: float = minf(HairMotionBinding.free_length(b.sim_free[s], HairMotionBinding.FIXED_LENGTH), length)
	var at: float = (free + (length - free) * j / (HairMotionBinding.SAMPLES - 1)) / maxf(length, 1e-9) * (HairMotionBinding.DENSE - 1)
	var i: int = clampi(int(at), 0, HairMotionBinding.DENSE - 2)
	return b.sim_rest[s * HairMotionBinding.DENSE + i].lerp(b.sim_rest[s * HairMotionBinding.DENSE + i + 1], clampf(at - i, 0.0, 1.0))


func test_at_rest_with_nothing_on_it_the_hair_stays_put() -> void:
	var b: HairMotionBinding = HairMotionBinding.build(_grown("long_straight"))
	var sim: Object = _sim(b)
	var d := PackedVector3Array()
	for i in 30:
		d = _step(sim, Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO)
	var worst: float = 0.0
	for p in d:
		worst = maxf(worst, p.length())
	assert_lt(worst, 0.002, "no force, no motion (%.4f m)" % worst)


func test_the_fixed_length_rides_the_head_and_the_rest_lags() -> void:
	var b: HairMotionBinding = HairMotionBinding.build(_grown("long_straight"))
	var sim: Object = _sim(b)
	_step(sim, Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, [], true)
	var d := PackedVector3Array()
	for i in 10:  # the head runs sideways at 3 m/s
		d = _step(sim, Transform3D(Basis.IDENTITY, Vector3(0.05 * (i + 1), 0.0, 0.0)), Vector3.ZERO, Vector3.ZERO)
	var lag: float = 0.0
	for s in b.sims.size():
		for j in HairMotionBinding.SAMPLES:
			var p: Vector3 = d[s * HairMotionBinding.SAMPLES + j]
			if not _free_at(b, s, j):
				assert_lt(p.length(), 1e-5, "within its fixed length a hair rides the head")
			else:
				lag = minf(lag, p.x)
	assert_lt(lag, -0.005, "past it, the hair lags behind the running head (%.3f m)" % lag)


func test_the_hair_keeps_out_of_a_capsule_and_out_of_the_head() -> void:
	var b: HairMotionBinding = HairMotionBinding.build(_grown("long_straight"))
	var sim: Object = _sim(b)
	var s: int = 0
	var tip: Vector3 = b.sim_rest[s * HairMotionBinding.DENSE + HairMotionBinding.DENSE - 1]
	# Its axis a millimetre beside the tip: a point right on it has no way out.
	var cap: Array = [tip + Vector3(0.001, 0.05, 0.0), tip + Vector3(0.001, -0.05, 0.0), 0.03]
	_step(sim, Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, [cap], true)
	var d: PackedVector3Array = _step(sim, Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, [cap])
	var moved: Vector3 = tip + d[s * HairMotionBinding.SAMPLES + HairMotionBinding.SAMPLES - 1]
	assert_gt(Vector2(moved.x - tip.x - 0.001, moved.z - tip.z).length(), 0.03 - 1e-3, "a tip inside a capsule is pushed out of it")
	# A strong wind towards the face for a second: no point may end up inside the head.
	var head: HairHead = HairHead.shared()
	var inside: int = 0
	for i in 60:
		d = _step(sim, Transform3D.IDENTITY, Vector3(0.0, -9.81, 0.0), Vector3(0.0, 0.0, 12.0))
	for k in d.size():
		var rest_point: Vector3 = _sample_rest(b, k / HairMotionBinding.SAMPLES, k % HairMotionBinding.SAMPLES)
		var p: Vector3 = rest_point + d[k]
		var rest: float = minf(float(head.surface(rest_point)[0]), 0.0)
		if p.y > head.centre.y - 0.1 and float(head.surface(p)[0]) < rest - 0.001:
			inside += 1
	assert_eq(inside, 0, "no strand point further inside the head than it lies at rest")


func test_the_swing_dies_out_without_wind() -> void:
	var b: HairMotionBinding = HairMotionBinding.build(_grown("long_straight"))
	var sim: Object = _sim(b)
	_step(sim, Transform3D.IDENTITY, Vector3(0.0, -9.81, 0.0), Vector3.ZERO, [], true)
	var peak: float = 0.0
	var d := PackedVector3Array()
	for i in 30:
		d = _step(sim, Transform3D.IDENTITY, Vector3(0.0, -9.81, 0.0), Vector3(8.0, 0.0, 0.0))
	for p in d:
		peak = maxf(peak, p.length())
	var sway: Array[PackedVector3Array] = []
	for i in 240:
		sway.append(_step(sim, Transform3D.IDENTITY, Vector3(0.0, -9.81, 0.0), Vector3.ZERO))
	# What still moves after 4 s: the last frame against the one before.
	var still: float = 0.0
	for k in sway[239].size():
		still = maxf(still, sway[239][k].distance_to(sway[238][k]))
	assert_gt(peak, 0.02, "the wind blows the hair (%.3f m)" % peak)
	assert_lt(still, 0.0005, "4 s after the wind, it has settled (%.5f m per frame)" % still)


# --- the body's capsules (HumanBuilder._hair_colliders) ---------------------------------------------------------------

func test_a_dressed_body_gives_its_hair_capsules_round_its_neck_and_shoulders() -> void:
	HumanBuilder.generate_lods = false
	var puppet: Node3D = (load("res://scenes/_universe/characters/humanoids/human_puppet.tscn") as PackedScene).instantiate()
	add_child_autofree(puppet)
	var looks: HumanAppearance = puppet.get_node("HumanAppearance")
	looks.set_appearance_now(CharacterAppearance.random(5))
	HumanBuilder.generate_lods = true
	var capsules: Array = looks.hair_colliders()
	assert_eq(capsules.size(), HumanBuilder.HAIR_COLLIDERS.size(), "a capsule per bone the hair may lie on")
	var skeleton: Skeleton3D = looks.skeleton()
	for c: Array in capsules:
		assert_between(float(c[3]), 0.02, 0.15, "%s: a body's girth (%.3f m)" % [c[0], c[3]])
		gut.p("%s: radius %.3f m" % [c[0], c[3]])
		if c[0] == "Neck":
			var pose: Transform3D = skeleton.get_bone_global_rest(skeleton.find_bone("Neck"))
			var a: Vector3 = pose * (c[1] as Vector3)
			var head: Vector3 = skeleton.get_bone_global_rest(skeleton.find_bone("Head")).origin
			assert_lt(a.distance_to(pose.origin), 0.01, "the neck's capsule starts at its joint")
			assert_lt((pose * (c[2] as Vector3)).distance_to(head), 0.01, "and ends at the head's")
