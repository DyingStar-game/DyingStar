extends GutTest
## What the game needs first is made ready while the menu shows (Warmup): every dispenser's items and the
## places the world spawns, read from their scenes without instancing them.

const DISPENSERS := "res://scenes/_universe/structures/dispenser/"


func test_every_dispenser_s_items_are_warmed() -> void:
	for file in ResourceLoader.list_directory(DISPENSERS):
		if not file.ends_with(".tscn"):
			continue
		var dispenser: Node = (load(DISPENSERS + file) as PackedScene).instantiate()
		if "catalogue_dir" in dispenser:
			var dir: String = str(dispenser.catalogue_dir)
			assert_true(dir in Warmup.CATALOGUES or dir.trim_suffix("/") + "/" in Warmup.CATALOGUES,
					"%s: its items %s are warmed" % [file, dir])
		dispenser.free()
	assert_true("res://scenes/_universe/props/food/food_biscuit.tscn" in Warmup.wanted(), "the ration of the playtest")


func test_a_scene_s_meshes_are_read_without_instancing_it() -> void:
	var meshes: Array = Warmup.meshes_of(load("res://scenes/_universe/props/food/food_biscuit.tscn"))
	assert_gt(meshes.size(), 0, "its model's meshes, through the instanced .glb")
	for entry: Array in meshes:
		assert_true(entry[0] is Mesh)


func test_a_rock_is_warmed_with_the_shader_the_game_gives_it() -> void:
	assert_true(Warmup.ROCK_SCENE in Warmup.wanted())
	var meshes: Array = Warmup.meshes_of(load(Warmup.ROCK_SCENE))
	assert_gt(meshes.size(), 0, "the rock's mesh")
	Warmup.with_rock_shader(meshes)
	for entry: Array in meshes:
		var shaders: Array = (entry[1] as Array).map(func(m: Material) -> Variant: return m.get("shader"))
		assert_true(Warmup.ROCK_SHADER in shaders, "drawn with rock_vein")


func test_the_layouts_read_ahead_are_among_those_loaded() -> void:
	for path: String in Warmup.LAYOUTS:
		assert_true(path in Warmup.wanted(), path)


func test_progress_runs_from_nothing_to_all() -> void:
	assert_eq(Warmup.progress(10, 10, 0, 0), 0.0, "nothing loaded yet")
	assert_eq(Warmup.progress(10, 0, 0, 40), 0.5, "all loaded, nothing drawn")
	assert_eq(Warmup.progress(10, 0, 40, 0), 1.0, "all drawn")


func test_the_scenes_are_loaded_one_at_a_time() -> void:
	# All at once, with sub-threads, the loads deadlocked in exported games: a worker waiting for a mesh's
	# pipelines ran another scene's load, which waited for the GDScript loading lock held below it.
	var first := "res://assets/_universe/audio/music/playlists/capital.tres"
	var second := "res://assets/_universe/audio/music/playlists/combat.tres"
	var warmup := Warmup.new()  # never in the tree: only its loading runs
	warmup._loading = [first, second]
	warmup._request_next()
	assert_ne(ResourceLoader.load_threaded_get_status(first), ResourceLoader.THREAD_LOAD_INVALID_RESOURCE, "first asked for")
	assert_eq(ResourceLoader.load_threaded_get_status(second), ResourceLoader.THREAD_LOAD_INVALID_RESOURCE,
		"the second waits for the first")
	for path in [first, second]:
		var started := Time.get_ticks_msec()
		while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS \
				and Time.get_ticks_msec() - started < 10000:
			OS.delay_msec(5)
		warmup._take_loaded()  # takes it in, and asks for the next
	assert_true(warmup._loading.is_empty(), "both taken in")
	assert_true(Warmup._held.has(first) and Warmup._held.has(second), "and kept")
	Warmup._held.erase(first)
	Warmup._held.erase(second)
	warmup.free()

func test_every_shader_of_a_person_is_drawn_alone_first() -> void:
	# A person's shaders are warmed one a frame (each costs seconds on a cold cache): one left out of the list
	# would compile with the person, all in the same frame again.
	var listed: Array[Shader] = Warmup.person_shaders()
	var constants: Dictionary = (load("res://scenes/_universe/characters/human/character_materials.gd") as GDScript) \
			.get_script_constant_map()
	for key: String in constants:
		if constants[key] is Shader:
			assert_true(constants[key] in listed, "CharacterMaterials.%s" % key)


func test_a_material_s_shader_is_started_without_making_the_material() -> void:
	# Every pass of a chain, a ShaderMaterial (compiled since it was loaded) and a mesh drawn in its own
	# surfaces' materials, or in none, are gone through without an error.
	var standard := StandardMaterial3D.new()
	var shader_pass := ShaderMaterial.new()
	shader_pass.shader = Warmup.SSS_PRIMER
	var last := StandardMaterial3D.new()
	last.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	standard.next_pass = shader_pass
	shader_pass.next_pass = last
	Warmup._compile(standard)
	Warmup._compile(null)
	var mesh := BoxMesh.new()
	mesh.material = standard
	Warmup._start_compiling(mesh, null)
	Warmup._start_compiling(BoxMesh.new(), null)
	Warmup._start_compiling(mesh, shader_pass)
	assert_engine_error_count(0, "no engine error")
