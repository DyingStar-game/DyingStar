extends GutTest
## The networked shelves every cargo depot spawns (cargo_depot.gd spawn_shelves): the layout they are
## read from, and the uuids that keep a server restart from piling a second set.

const CargoDepot := preload("res://scenes/_universe/structures/industrial/cargo_depot.gd")


func _layout() -> Array:
	var layout = JSON.parse_string(FileAccess.get_file_as_string(CargoDepot.SHELVES_LAYOUT))
	assert_eq(typeof(layout), TYPE_ARRAY, "the shelf layout is a JSON array")
	return layout if typeof(layout) == TYPE_ARRAY else []


func test_layout_lists_every_shelf_once() -> void:
	var layout := _layout()
	assert_eq(layout.size(), 193, "temp zone shelf + 8 rows of 24")
	var names := {}
	for shelf: Dictionary in layout:
		assert_true(shelf.has("position") and shelf.has("rotation"), "%s has a pose" % shelf.get("name"))
		names[str(shelf["name"])] = true
	assert_eq(names.size(), layout.size(), "shelf names are unique (they seed the uuids)")


func test_shelf_scene_exists() -> void:
	assert_true(ResourceLoader.exists("res://" + CargoDepot.SHELF_SCENE))


func test_shelf_uuid_is_stable_and_per_depot() -> void:
	var a := CargoDepot.shelf_uuid_for("depot-a", "shelf_cargo_row1_1")
	assert_eq(a, CargoDepot.shelf_uuid_for("depot-a", "shelf_cargo_row1_1"), "same seed, same uuid")
	assert_ne(a, CargoDepot.shelf_uuid_for("depot-b", "shelf_cargo_row1_1"), "another depot, another shelf")
	assert_ne(a, CargoDepot.shelf_uuid_for("depot-a", "shelf_cargo_row1_2"), "another name, another shelf")
