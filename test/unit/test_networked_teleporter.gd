extends GutTest
## The teleporter is a networked building: every mining village spawns one from its layout
## (poi_villages.gd), and the station's comes from Horizon's seed. A cabin dropped into a world scene
## by hand would not be networked — every machine would load its own copy from the scene file, with
## no uuid — so no scene holds one except the village layout.

const TELEPORTER := "res://scenes/_universe/structures/buildings/teleporter/teleporter.tscn"
const VILLAGE := "res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn"
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
	var text := FileAccess.get_file_as_string(VILLAGE)
	var ref := RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"%s\" id=\"([^\"]+)\"\\]" % TELEPORTER)
	var found := ref.search(text)
	assert_not_null(found, "the layout references the cabin's scene")
	if found == null:
		return
	var instanced := "parent=\".\" instance=ExtResource(\"%s\")" % found.get_string(1)
	assert_eq(text.count(instanced), 1, "one cabin, a direct child of the layout")


func test_no_scene_but_the_village_layout_places_a_cabin() -> void:
	var holders: PackedStringArray = []
	for root: String in SCENE_ROOTS:
		holders.append_array(_scenes_referencing(root, TELEPORTER))
	assert_eq(holders, PackedStringArray([VILLAGE]),
			"a hand-placed cabin is not networked: put it in the village layout or in Horizon's seed")


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
