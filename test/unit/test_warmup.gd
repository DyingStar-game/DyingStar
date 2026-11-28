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


func test_every_terrain_material_with_a_noise_texture_is_loaded_first() -> void:
	# A NoiseTexture2D makes its image the first time on the thread that loads it, at once: a material of the terrain
	# the warm-up does not load ahead is noise made on the main thread at the arrival on a planet (0.8 s a water).
	for dir: String in ["res://scenes/planet/", "res://assets/_universe/environment/terrain/",
			"res://assets/_universe/_shared/materials/"]:
		for file in ResourceLoader.list_directory(dir):
			if not file.ends_with(".tres"):
				continue
			if FileAccess.get_file_as_string(dir + file).contains("type=\"NoiseTexture2D\""):
				assert_true(dir + file in Warmup.NOISE_MATERIALS, "%s%s is loaded ahead" % [dir, file])
	var wanted := Warmup.wanted()
	for i in Warmup.NOISE_MATERIALS.size():
		assert_eq(wanted[i], Warmup.NOISE_MATERIALS[i], "before the scenes")


func test_the_biomes_and_the_bodies_scripts_are_loaded_before_the_places() -> void:
	# Both were loaded on the main thread in the frame the player's planet arrived (2.3 s of scripts, 1.3 s of biomes).
	var wanted := Warmup.wanted()
	var first_place := wanted.find(Warmup.SCENES[0])
	for path: String in ["res://scenes/planet/biomes/outcrop-plateau.tres", "res://scenes/planet/planet_terrain.gd"]:
		assert_true(path in wanted, path)
		assert_lt(wanted.find(path), first_place, "%s before the places" % path)
	assert_gt(Warmup.folder_resources(Warmup.BIOMES_DIR).size(), 100, "every biome, read from the folder")


func test_every_script_and_material_of_a_body_scene_is_loaded_ahead_but_no_body_is_kept() -> void:
	# A body's scene kept by the warm-up would keep its PlanetData alive: a body made again would reuse it, caches
	# and all. Its scripts are what costs.
	for file in ResourceLoader.list_directory("res://scenes/systems/tarsis/"):
		if not file.ends_with(".tscn"):
			continue
		var text := FileAccess.get_file_as_string("res://scenes/systems/tarsis/" + file)
		for line in text.split("\n"):
			if line.begins_with("[ext_resource type=\"Script\"") or line.begins_with("[ext_resource type=\"Material\""):
				var path := line.get_slice("path=\"", 1).get_slice("\"", 0)
				assert_true(path in Warmup.BODY_RESOURCES, "%s: %s compiled ahead" % [file, path])
	for path: String in Warmup.wanted():
		assert_false(path.begins_with("res://scenes/systems/"), "%s: no body's scene is kept" % path)


func test_the_services_panels_are_compiled_before_the_places() -> void:
	# TerminalUI loads each panel as the player appears: they compiled there, with every class they name.
	var wanted := Warmup.wanted()
	var first_place := wanted.find(Warmup.SCENES[0])
	for path: String in ["res://ui/services/profile_panel.gd", "res://ui/services/inventory_panel.gd"]:
		assert_true(path in wanted, path)
		assert_lt(wanted.find(path), first_place, "%s before the places" % path)
	var listed: Array = (load("res://ui/services/terminal_ui.gd") as GDScript).get_script_constant_map().get("APPS", [])
	for app: Dictionary in listed:
		assert_true(str(app.get("path", "")) in wanted, "%s is compiled ahead" % app.get("path", ""))


func test_the_loads_wait_for_a_menu_stage_being_built() -> void:
	# The stage's world and biomes loading on workers with the warm-up's water materials hung the start at 1 %
	# (2026-11-27): the warm-up loads nothing while a stage is being built.
	var tree := get_tree()
	assert_false(Warmup.waits_for_menu_stage(tree), "no stage being built: the loads start")
	var stage := Node.new()
	add_child_autofree(stage)
	stage.add_to_group(MenuStage.BUILDING_GROUP)
	assert_true(Warmup.waits_for_menu_stage(tree), "a stage being built: they wait")
	stage.remove_from_group(MenuStage.BUILDING_GROUP)
	assert_false(Warmup.waits_for_menu_stage(tree), "built (or given up): they start")


func test_while_it_waits_the_line_says_so_without_a_figure() -> void:
	# "0 %" while the menu stage is built (a minute on a slow PC) would read as a hang.
	var warmup := Warmup.new()
	add_child_autofree(warmup)  # _ready puts out the primer; nothing is asked for until the stage is up
	warmup._show_progress()
	assert_eq(warmup._label.text, tr("%%MENU_WARMUP_WAITING"), "the waiting line")
	assert_false(warmup._label.text.contains("%"), "no figure: %s" % warmup._label.text)
	var csv := FileAccess.get_file_as_string("res://tools/localization/localisation.csv")
	assert_true(csv.contains("\n%%MENU_WARMUP_WAITING,"), "translated")


func test_the_surfaces_built_at_run_time_are_warmed() -> void:
	for path: String in Warmup.RUNTIME_SURFACES:
		assert_has(Warmup.wanted(), path, "%s is loaded by the warm-up" % path)
	var surfaces: Array = (load(Warmup.RUNTIME_SURFACES[0]) as Script).call("warm_surfaces")
	var materials: Array = []
	for entry: Array in surfaces:
		assert_true(entry[0] is Mesh, "a mesh to draw")
		materials.append_array(entry[1])
	assert_has(materials, BuildingWalkways._rail_mat(), "the railings' metal")
	assert_has(materials, BuildingWalkways._plate(), "the decks' plate")
	var batch_format: int = (surfaces[0][0] as Mesh).surface_get_format(0)
	var facade: StaticBody3D = autofree(StaticBody3D.new())
	BuildingWalkways._build_facade(facade, 10.0, 2, 2.6)
	var railings := facade.get_node(NodePath(BuildingWalkways.RAILINGS_NAME)) as MeshInstance3D
	assert_eq(batch_format, railings.mesh.surface_get_format(0), "drawn on the railings' own vertex format")


func test_the_sky_shaders_are_loaded_and_compiled_ahead() -> void:
	for path: String in Warmup.BY_USE_SHADERS:
		assert_has(Warmup.wanted(), path, "%s is loaded by the warm-up" % path)
		assert_true(load(path) is Shader, "%s is a shader" % path)
	var users := FileAccess.get_file_as_string("res://scenes/player/atmosphere_renderer.gd") \
			+ FileAccess.get_file_as_string("res://scenes/ui/star_map/star_map.gd") \
			+ FileAccess.get_file_as_string("res://scenes/ui/star_map/ecliptic_grid.gd")
	for path: String in Warmup.BY_USE_SHADERS:
		assert_string_contains(users, path, "%s is what the sky or the chart loads" % path.get_file())
