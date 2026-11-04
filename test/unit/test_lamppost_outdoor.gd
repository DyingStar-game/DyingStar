extends GutTest
## The 3.4 m outdoor lamppost lights the village and city layouts in place of the floodlight (kept for
## later use): a networked fixed prop (simple_building) that levels the ground under its base, its lamp
## switched by a Photocell. The model is a member's contribution, credited in the .txt beside it.

const SCENE := "res://scenes/_universe/props/furniture/furn_lamppost_outdoor_3.4m.tscn"
const MODEL := "res://assets/_universe/props/furniture/furn_lamppost_outdoor_3.4m.glb"
const FLOODLIGHT := "res://scenes/_universe/props/furniture/furn_floodlight_outdoor_lg.tscn"
const LAYOUTS := [
	"res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn",
	"res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn",
	"res://levels/menu_stage/menu_stage_world.tscn",
]
## The base plate of the model, measured in the glTF: x -0.36..0.44, z -0.45..0.45 (metres).
const BASE := AABB(Vector3(-0.36, 0.0, -0.45), Vector3(0.8, 0.2, 0.9))


func test_it_is_a_networked_fixed_prop() -> void:
	var lamp: Node3D = load(SCENE).instantiate()
	var sync := PropSync.of(lamp)
	assert_not_null(sync, "networked: a village layout can spawn it")
	if sync != null:
		assert_eq(sync.type_name, "simple_building")
		assert_false(sync.enable_carry, "a 3.4 m pole is not carried by hand")
	lamp.free()


func test_the_levelled_ground_covers_the_base_and_stays_under_it() -> void:
	var lamp: Node3D = load(SCENE).instantiate()
	var ground := lamp.get_node_or_null("TerrainPad/Ground") as CSGBox3D
	assert_not_null(ground, "a TerrainPad with its Ground box")
	if ground != null:
		var pad := AABB(ground.position - ground.size * 0.5, ground.size)
		assert_lt(pad.end.y, 0.0, "the levelled ground stays under the base (y = 0)")
		var flat := Rect2(pad.position.x, pad.position.z, pad.size.x, pad.size.z)
		for corner: Vector3 in [BASE.position, BASE.end]:
			assert_true(flat.has_point(Vector2(corner.x, corner.z)), "the whole base stands on levelled ground")
	lamp.free()


func test_its_lamp_points_down() -> void:
	var lamp: Node3D = load(SCENE).instantiate()
	var light := lamp.get_node_or_null("SpotLight3D") as SpotLight3D
	assert_not_null(light, "a spot in the lamp head")
	if light != null:
		assert_gt(light.position.y, 2.5, "in the head, not at the foot")
		assert_lt((-light.transform.basis.z).y, -0.3, "lighting the ground")
	lamp.free()


func test_the_model_is_credited() -> void:
	var credit := MODEL.get_basename() + ".txt"
	assert_true(FileAccess.file_exists(credit), "the author is credited beside the model")
	var line := FileAccess.get_file_as_string(credit).strip_edges()
	assert_not_null(RegEx.create_from_string("^Discord - \\S+ - \\d+$").search(line), "Discord - <name> - <id>")


func test_the_layouts_use_it_instead_of_the_floodlight() -> void:
	for layout: String in LAYOUTS:
		var text := FileAccess.get_file_as_string(layout)
		assert_false(text.contains(FLOODLIGHT), "%s: no floodlight left" % layout.get_file())
		assert_true(text.contains(SCENE), "%s: lit by the lamppost" % layout.get_file())
