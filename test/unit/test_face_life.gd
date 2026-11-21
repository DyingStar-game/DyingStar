extends GutTest
## A face seen close up comes alive: its head is baked again with blend shapes (HumanBuilder.LIFE_SHAPES)
## that meet the body at the neck without a crack, HumanAppearance swaps the two heads, FaceLife drives
## the shapes (blinks, gaze, voice), and VoiceMeter reads a speaker's level on a bus of its own.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_face_life.gd -gexit

const PUPPET := "res://scenes/_universe/characters/humanoids/human_puppet.tscn"


func before_all() -> void:
	HumanBuilder.generate_lods = false  # most of a bake's time, and not what is tested here


func after_all() -> void:
	HumanBuilder.generate_lods = true


func _puppet(look: CharacterAppearance, life: bool) -> Node3D:
	var puppet: Node3D = (load(PUPPET) as PackedScene).instantiate()
	add_child_autofree(puppet)
	var looks: HumanAppearance = puppet.get_node("HumanAppearance")
	looks.face_life = life
	looks.set_appearance_now(look)
	return puppet


func test_a_live_head_is_the_plain_head_plus_its_shapes() -> void:
	var look: CharacterAppearance = CharacterAppearance.random(41)
	var plain: HumanBuilder.Baked = HumanMeshCache.build_now(look, false)
	var live: HumanBuilder.Baked = HumanMeshCache.build_now(look, false, true)
	assert_true(live.live)
	assert_null(live.mesh, "a live bake is the head alone")
	assert_eq(plain.mesh.get_blend_shape_count(), 0, "the body never carries a blend shape")
	assert_eq(live.head_mesh.get_blend_shape_count(), HumanBuilder.LIFE_SHAPES.size())
	for k in HumanBuilder.LIFE_SHAPES.size():
		assert_eq(live.head_mesh.get_blend_shape_name(k), HumanBuilder.LIFE_SHAPES[k][0])
	assert_eq(live.head_mesh.get_surface_count(), plain.head_mesh.get_surface_count())
	assert_eq(live.head_surface_assets, plain.head_surface_assets, "same zones, same order: same materials")
	for s in live.head_mesh.get_surface_count():
		var a: PackedVector3Array = plain.head_mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		var b: PackedVector3Array = live.head_mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		assert_eq(a, b, "surface %d: the same head at rest" % s)


func test_every_shape_moves_the_face_and_none_moves_the_neck() -> void:
	var look: CharacterAppearance = CharacterAppearance.random(43)
	var plain: HumanBuilder.Baked = HumanMeshCache.build_now(look, false)
	var live: HumanBuilder.Baked = HumanMeshCache.build_now(look, false, true)
	# The body's vertices at the neck: what the head must keep meeting.
	var body_points: Dictionary = {}
	for s in plain.mesh.get_surface_count():
		if plain.surface_assets[s] is StringName:
			for v: Vector3 in plain.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				body_points[v] = true
	var shared: int = 0
	var moved: PackedFloat32Array = []
	moved.resize(HumanBuilder.LIFE_SHAPES.size())
	for s in live.head_mesh.get_surface_count():
		var base: Array = live.head_mesh.surface_get_arrays(s)
		var at_rest: PackedVector3Array = base[Mesh.ARRAY_VERTEX]
		var shapes: Array = live.head_mesh.surface_get_blend_shape_arrays(s)
		for i in at_rest.size():
			var on_neck: bool = body_points.has(at_rest[i])
			shared += 1 if on_neck else 0
			for k in shapes.size():
				var d: float = (shapes[k][Mesh.ARRAY_VERTEX][i] as Vector3).distance_to(at_rest[i])
				moved[k] = maxf(moved[k], d)
				if on_neck and d > 0.0:
					fail_test("%s moves a neck vertex by %f m" % [HumanBuilder.LIFE_SHAPES[k][0], d])
					return
	assert_gt(shared, 20, "the head and the body share the neck's vertices")
	for k in moved.size():
		assert_between(moved[k], 0.002, 0.06, "%s moves the face by millimetres to centimetres" % HumanBuilder.LIFE_SHAPES[k][0])


func test_life_swaps_the_heads() -> void:
	var puppet: Node3D = _puppet(CharacterAppearance.random(47), false)
	var looks: HumanAppearance = puppet.get_node("HumanAppearance")
	var head: MeshInstance3D = looks.head_mesh()
	var plain: Mesh = head.mesh
	assert_false(looks.is_live())
	assert_eq(looks.face_shape_index(&"jaw_open"), -1)
	looks.set_life(true)
	looks._process(0.0)  # the head is baked on a worker: wait for it
	for _i in 400:
		if looks.is_live():
			break
		await get_tree().process_frame
	assert_true(looks.is_live(), "the live head came")
	assert_same(looks.head_mesh(), head, "the same node: shadows and layers set on it stay")
	assert_ne(head.mesh, plain)
	assert_ne(looks.face_shape_index(&"jaw_open"), -1)
	looks.set_face_shape(&"jaw_open", 0.5)
	assert_almost_eq(head.get_blend_shape_value(looks.face_shape_index(&"jaw_open")), 0.5, 1e-6)
	assert_not_null(head.get_surface_override_material(0), "the live head is dressed")
	looks.set_life(false)
	assert_false(looks.is_live())
	assert_same(head.mesh, plain, "the plain head is back")


func test_face_life_drives_the_shapes() -> void:
	var puppet: Node3D = _puppet(CharacterAppearance.random(53), true)
	var looks: HumanAppearance = puppet.get_node("HumanAppearance")
	var face: FaceLife = puppet.get_node("FaceLife")
	assert_true(looks.is_live())
	face.voice_level = 1.0
	var jaw: float = 0.0
	var blinked: bool = false
	face.blink()
	for _i in 30:
		face._process(1.0 / 60.0)
		jaw = maxf(jaw, looks.head_mesh().get_blend_shape_value(looks.face_shape_index(&"jaw_open")))
		blinked = blinked or looks.head_mesh().get_blend_shape_value(looks.face_shape_index(&"blink_left")) > 0.9
	assert_gt(jaw, 0.2, "a voice opens the mouth")
	assert_true(blinked, "a blink shuts the lids")
	face.voice_level = 0.0
	for _i in 120:
		face._process(1.0 / 60.0)
	assert_almost_eq(looks.head_mesh().get_blend_shape_value(looks.face_shape_index(&"jaw_open")), 0.0, 1e-6, "silence shuts it")
	for value: float in face.shape_values().values():
		assert_between(value, -0.001, 1.0)


func test_a_blink_is_fast_down_and_slower_up() -> void:
	assert_eq(FaceLife.blink_weight(0.0), 0.0)
	assert_eq(FaceLife.blink_weight(FaceLife.BLINK_CLOSE_S + FaceLife.BLINK_SHUT_S * 0.5), 1.0)
	var total: float = FaceLife.BLINK_CLOSE_S + FaceLife.BLINK_SHUT_S + FaceLife.BLINK_OPEN_S
	assert_almost_eq(FaceLife.blink_weight(total), 0.0, 1e-6)
	assert_lt(total, 0.4, "a blink lasts a few tenths of a second")
	assert_gt(FaceLife.BLINK_OPEN_S, FaceLife.BLINK_CLOSE_S)


func test_gaze_and_speech_weights() -> void:
	var left: Dictionary = FaceLife.gaze_weights(Vector2(9.0, 0.0))
	assert_almost_eq(left[&"look_left"], 9.0 / FaceLife.LOOK_LEFT_DEG, 1e-6)
	assert_eq(left[&"look_right"], 0.0)
	var far: Dictionary = FaceLife.gaze_weights(Vector2(-90.0, -90.0))
	assert_eq(far[&"look_right"], 1.0, "a shape never goes past its full weight")
	assert_eq(far[&"look_down"], 1.0)
	assert_eq(far[&"look_up"], 0.0)
	for t in 50:
		var silent: Dictionary = FaceLife.speech_weights(0.0, t * 0.037)
		var loud: Dictionary = FaceLife.speech_weights(1.0, t * 0.037)
		for shape: StringName in silent:
			assert_eq(silent[shape], 0.0)
			assert_between(loud[shape], 0.0, 0.85)


func test_voice_meter_gives_a_speaker_its_own_bus_and_takes_it_back() -> void:
	assert_eq(VoiceMeter.level_of_db(-80.0), 0.0)
	assert_eq(VoiceMeter.level_of_db(0.0), 1.0)
	assert_between(VoiceMeter.level_of_db(-30.0), 0.3, 0.9)
	var buses: int = AudioServer.bus_count
	var speaker := AudioStreamPlayer.new()
	speaker.bus = &"Master"
	add_child(speaker)
	assert_between(VoiceMeter.level(speaker), 0.0, 1.0)
	assert_eq(AudioServer.bus_count, buses + 1)
	assert_ne(speaker.bus, &"Master")
	assert_eq(AudioServer.get_bus_send(AudioServer.get_bus_index(speaker.bus)), &"Master", "heard where it was")
	VoiceMeter.level(speaker)
	assert_eq(AudioServer.bus_count, buses + 1, "one bus per speaker, however often it is read")
	VoiceMeter.release(speaker)
	assert_eq(AudioServer.bus_count, buses)
	assert_eq(speaker.bus, &"Master")
	# A speaker freed with its player: its bus goes at the next sweep.
	VoiceMeter.level(speaker)
	speaker.free()
	VoiceMeter.sweep()
	assert_eq(AudioServer.bus_count, buses)
	assert_eq(VoiceMeter.metered_count(), 0)


func test_every_expression_is_made_of_life_shapes() -> void:
	var names: Array = HumanBuilder.LIFE_SHAPES.map(func(shape: Array) -> StringName: return shape[0])
	assert_true(FaceLife.EXPRESSIONS.has(&"neutral"))
	assert_true((FaceLife.EXPRESSIONS[&"neutral"] as Dictionary).is_empty(), "neutral holds nothing")
	for key: StringName in FaceLife.EXPRESSIONS:
		for shape: StringName in FaceLife.EXPRESSIONS[key]:
			assert_has(names, shape, "%s: %s is a life shape" % [key, shape])
			assert_between(float(FaceLife.EXPRESSIONS[key][shape]), 0.01, FaceLife.MAX_SHAPE_WEIGHT)


func test_a_held_expression_eases_in_and_out_over_the_idle_life() -> void:
	var puppet: Node3D = _puppet(CharacterAppearance.random(53), true)
	var looks: HumanAppearance = puppet.get_node("HumanAppearance")
	var face: FaceLife = puppet.get_node("FaceLife")
	var shape := func(name: StringName) -> float:
		return looks.head_mesh().get_blend_shape_value(looks.face_shape_index(name))
	face.expression = &"surprise"
	face._process(1.0 / 60.0)
	assert_lt(shape.call(&"eyes_wide"), 0.5, "an expression eases in, it does not snap")
	for _i in 60:
		face._process(1.0 / 60.0)
	assert_almost_eq(shape.call(&"eyes_wide"), 1.0, 1e-4)
	assert_almost_eq(shape.call(&"brows_up"), 1.0, 1e-4)
	assert_almost_eq(shape.call(&"sad"), 0.0, 1e-4, "the idle temper steps aside")
	face.expression = &"sad"
	for _i in 60:
		face._process(1.0 / 60.0)
	assert_almost_eq(shape.call(&"sad"), 2.0, 1e-4, "a faint shape is held past its full weight")
	assert_almost_eq(shape.call(&"eyes_wide"), 0.0, 1e-4, "the previous expression is gone")
	face.expression = &"wink"
	var shut: float = 1.0
	for _i in 300:
		face._process(1.0 / 60.0)
		if _i > 30:
			shut = minf(shut, shape.call(&"blink_left"))
	assert_almost_eq(shut, 1.0, 1e-4, "a wink's eye stays shut through the blinks")
	face.expression = &"laugh"
	var jaw := Vector2(INF, -INF)
	for _i in 120:
		face._process(1.0 / 60.0)
		if _i > 30:
			jaw = Vector2(minf(jaw.x, shape.call(&"jaw_open")), maxf(jaw.y, shape.call(&"jaw_open")))
	assert_gt(jaw.y - jaw.x, 0.1, "a laugh shakes the jaw")
	face.expression = &"neutral"
	for _i in 60:
		face._process(1.0 / 60.0)
	for name: StringName in [&"eyes_wide", &"cheeks_raised", &"lips_apart", &"disgusted", &"scared"]:
		assert_almost_eq(shape.call(name), 0.0, 1e-4, "%s gone with the expression" % name)
