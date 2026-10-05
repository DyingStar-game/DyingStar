extends GutTest
## The teleporter is a networked building: every mining village spawns one from its layout
## (poi_villages.gd), every factory city two, and the station's comes from Horizon's seed. A cabin
## dropped into a world scene by hand would not be networked — every machine would load its own copy
## from the scene file, with no uuid — so no scene holds one except those layouts.

const TELEPORTER := "res://scenes/_universe/structures/buildings/teleporter/teleporter.tscn"
const VILLAGE := "res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn"
const FACTORY := "res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn"
## Where world scenes live.
const SCENE_ROOTS: Array[String] = ["res://scenes", "res://levels"]


func test_the_cabin_is_a_networked_building_that_levels_its_ground() -> void:
	var cabin: Node3D = load(TELEPORTER).instantiate()
	var sync := PropSync.of(cabin)
	assert_not_null(sync, "a PropSync makes it a networked prop")
	if sync != null:
		assert_eq(sync.type_name, "simple_building")
	assert_true(FileAccess.file_exists("res://items_def/simple_building_def.json"), "its definition ships")
	var box := cabin.get_node_or_null("TerrainPad/Ground") as CSGBox3D
	var shell := cabin.get_node("Blockout") as CSGBox3D
	assert_not_null(box, "a TerrainPad with its Ground box")
	if box != null:
		assert_lt(box.position.y + box.size.y * 0.5, 0.0, "the levelled ground stays under the floor (y = 0)")
		assert_true(box.size.x >= shell.size.x and box.size.z >= shell.size.z, "the whole footprint is levelled")
	cabin.free()


## poi_villages.gd spawns each direct child of the layout that has a PropSync and comes from a scene: a
## cabin instanced right under the layout's root is one per village. Read from the file rather than
## instantiated: the layout's buildings pull in every material they use, for nothing this test asks.
func test_every_mining_village_spawns_a_teleporter() -> void:
	assert_eq(_cabins_in(VILLAGE), 1, "one cabin, a direct child of the layout")


func test_every_factory_city_spawns_two_teleporters() -> void:
	assert_eq(_cabins_in(FACTORY), 2, "two cabins, direct children of the layout")


func test_no_scene_but_the_layouts_places_a_cabin() -> void:
	var holders: PackedStringArray = []
	for root: String in SCENE_ROOTS:
		holders.append_array(_scenes_referencing(root, TELEPORTER))
	holders.sort()
	assert_eq(holders, PackedStringArray([FACTORY, VILLAGE]),
			"a hand-placed cabin is not networked: put it in a layout or in Horizon's seed")


## How many cabins are direct children of [param layout]: the ones poi_villages.gd spawns.
func _cabins_in(layout: String) -> int:
	var text := FileAccess.get_file_as_string(layout)
	var ref := RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"%s\" id=\"([^\"]+)\"\\]" % TELEPORTER)
	var found := ref.search(text)
	assert_not_null(found, "%s references the cabin's scene" % layout.get_file())
	if found == null:
		return 0
	# The editor writes a unique_id (and may write more) between parent and instance: match any.
	var instanced := RegEx.create_from_string(
			"\\[node name=\"[^\"]+\" parent=\"\\.\"[^\\]]*instance=ExtResource\\(\"%s\"\\)\\]" % found.get_string(1))
	return instanced.search_all(text).size()


## The .tscn files under [param dir] that reference [param scene_path].
func _scenes_referencing(dir: String, scene_path: String) -> PackedStringArray:
	var found: PackedStringArray = []
	for file: String in DirAccess.get_files_at(dir):
		var path := dir.path_join(file)
		if file.ends_with(".tscn") and path != scene_path \
				and FileAccess.get_file_as_string(path).contains("path=\"%s\"" % scene_path):
			found.append(path)
	for sub: String in DirAccess.get_directories_at(dir):
		found.append_array(_scenes_referencing(dir.path_join(sub), scene_path))
	return found
