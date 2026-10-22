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


func test_progress_runs_from_nothing_to_all() -> void:
	assert_eq(Warmup.progress(10, 10, 0, 0), 0.0, "nothing loaded yet")
	assert_eq(Warmup.progress(10, 0, 0, 40), 0.5, "all loaded, nothing drawn")
	assert_eq(Warmup.progress(10, 0, 40, 0), 1.0, "all drawn")
