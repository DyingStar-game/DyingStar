extends GutTest
## The outdoor floodlight is placed in village layouts: a networked fixed prop (simple_building) that
## levels the ground under its base. Its model comes from Sketchfab under CC BY, which requires the
## credit the .txt beside it carries.

const SCENE := "res://scenes/_universe/props/furniture/furn_floodlight_outdoor_lg.tscn"
const MODEL := "res://assets/_universe/props/furniture/furn_floodlight_outdoor_lg.glb"
const HUM := "res://assets/_universe/audio/sfx/machine/generator-loop.ogg"
## The base plate of the model, measured in the glTF: x -0.29..0.50, z -0.94..0.16 (metres).
const BASE := AABB(Vector3(-0.29, 0.0, -0.94), Vector3(0.79, 0.14, 1.1))


func test_it_is_a_networked_fixed_prop() -> void:
	var lamp: Node3D = load(SCENE).instantiate()
	var sync := PropSync.of(lamp)
	assert_not_null(sync, "networked: a village layout can spawn it")
	if sync != null:
		assert_eq(sync.type_name, "simple_building")
		assert_false(sync.enable_carry, "a 4.7 m pole is not carried by hand")
	lamp.free()


func test_the_levelled_ground_covers_the_base_and_stays_under_it() -> void:
	var lamp: Node3D = load(SCENE).instantiate()
	var ground := lamp.get_node_or_null("TerrainPad/Ground") as CSGBox3D
	assert_not_null(ground, "a TerrainPad with its Ground box")
	if ground != null:
		var pad := AABB(ground.position - ground.size * 0.5, ground.size)
		assert_lt(pad.end.y, 0.0, "the levelled ground stays under the base (y = 0)")
		for corner: Vector3 in [BASE.position, BASE.end]:
			var flat := Vector2(corner.x, corner.z)
			assert_true(Rect2(pad.position.x, pad.position.z, pad.size.x, pad.size.z).has_point(flat),
					"the whole base plate stands on levelled ground")
	lamp.free()


func test_its_generator_hums() -> void:
	var lamp: Node3D = load(SCENE).instantiate()
	var hum: AmbientLoop3D = null
	for child in lamp.get_children():
		if child is AmbientLoop3D:
			hum = child
	assert_not_null(hum, "the electrical box at its base hums")
	if hum != null:
		assert_eq(hum.stream.resource_path, HUM, "the generator loop")
		assert_lt(hum.position.y, 1.0, "the sound comes from the box at the base, not the lamps")
	lamp.free()


func test_the_model_is_credited() -> void:
	var credit := MODEL.get_basename() + ".txt"
	assert_true(FileAccess.file_exists(credit), "CC BY: the author is credited beside the model")
	var line := FileAccess.get_file_as_string(credit).strip_edges()
	var third_party := RegEx.create_from_string("^[^-]+ - [^-]+ - https?://\\S+ - .+$")
	assert_not_null(third_party.search(line), "<Site> - <author> - <URL> - <licence>")
