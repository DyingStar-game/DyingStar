extends GutTest
## ares_village_mining, the layout of the mining POIs, follows the village sketch (level design >
## village MVP, digitised in services/npc config/village/mining_village.yaml): the mine to the west,
## the village along one avenue for vehicles, pedestrian alleys closed by bollards. Each building is
## its own scene (CSG placeholders), a networked fixed prop (simple_building) that levels its ground;
## everything a client shows of it lives in the scene, since the layout's overrides are not replicated.
## Read from the file: its buildings pull in materials that raise engine errors on load.

const LAYOUT := "res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn"
const S := "res://scenes/_universe/structures/"
const LOCALISATION := "res://tools/localization/localisation.csv"
## Every building of the sketch, by its scene.
const BUILDINGS := [
	"industrial/mines/mine_portal.tscn", "industrial/mines/spoil_heap.tscn", "industrial/mines/crusher.tscn",
	"industrial/mines/changing_rooms.tscn", "industrial/mines/mine_administration.tscn",
	"industrial/mines/mine_maintenance.tscn", "industrial/mines/mining_depot.tscn",
	"industrial/power/transformer_station.tscn", "industrial/power/battery_park.tscn",
	"industrial/power/wind_farm.tscn", "industrial/storage/imports_warehouse.tscn",
	"industrial/cargo_depot.tscn", "industrial/garage.tscn",
	"buildings/civic/town_hall.tscn", "buildings/civic/guard_post.tscn", "buildings/civic/school.tscn",
	"buildings/civic/infirmary.tscn", "buildings/civic/security_fire_station.tscn",
	"buildings/civic/server_room.tscn", "buildings/civic/geology_department.tscn",
	"buildings/civic/municipal_services.tscn", "buildings/civic/cemetery.tscn",
	"buildings/commerce/bar.tscn", "buildings/commerce/canteen.tscn", "buildings/commerce/retail_shop.tscn",
	"buildings/houses/worker_houses.tscn", "buildings/houses/dormitory.tscn",
	"buildings/spawn_building.tscn",
]
## The placeholder scenes added for the village MVP (the refinery waits for the factory city).
const PLACEHOLDERS := [
	"industrial/mines/mine_portal.tscn", "industrial/mines/crusher.tscn", "industrial/refinery/refinery.tscn",
	"industrial/mines/changing_rooms.tscn", "industrial/mines/mine_administration.tscn",
	"industrial/mines/mine_maintenance.tscn", "industrial/power/transformer_station.tscn",
	"industrial/power/battery_park.tscn", "industrial/storage/imports_warehouse.tscn",
	"buildings/civic/town_hall.tscn", "buildings/civic/guard_post.tscn", "buildings/civic/school.tscn",
	"buildings/civic/infirmary.tscn", "buildings/civic/security_fire_station.tscn",
	"buildings/civic/server_room.tscn", "buildings/civic/geology_department.tscn",
	"buildings/civic/municipal_services.tscn", "buildings/civic/cemetery.tscn",
	"buildings/commerce/bar.tscn", "buildings/commerce/canteen.tscn", "buildings/commerce/retail_shop.tscn",
	"buildings/houses/worker_houses.tscn", "buildings/houses/dormitory.tscn",
	"urban/streets/avenue_segment_12x40.tscn", "urban/walls/wall_segment_20m.tscn",
]
## Placeholders with no name to show.
const NO_SIGN := ["urban/streets/avenue_segment_12x40.tscn", "urban/walls/wall_segment_20m.tscn"]
## Placed without levelled ground: a heap, a field of masts, posts sunk in the soil.
const NO_PAD := ["industrial/mines/spoil_heap.tscn", "industrial/power/wind_farm.tscn",
		"urban/streets/bollard_row_6m.tscn"]
const MACHINE := S + "industrial/refinery/ore_processor_machine.tscn"
const AVENUE := S + "urban/streets/avenue_segment_12x40.tscn"
const BOLLARDS := S + "urban/streets/bollard_row_6m.tscn"
const WALL := S + "urban/walls/wall_segment_20m.tscn"
## A wall segment: its length along its X, and its thickness with a margin.
const WALL_HALF := Vector2(10.0, 0.5)
const AVENUE_HALF_WIDTH_M := 6.0
## The farthest a building stands from the village origin (m): the sketch is about 560 m across.
const MAX_REACH_M := 320.0

var _items: Array = []  # [scene path, Transform3D, name] of every direct child of the layout


func before_all() -> void:
	var text := FileAccess.get_file_as_string(LAYOUT).replace("\r\n", "\n")
	var paths := {}
	for ext in RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"([^\"]+)\" id=\"([^\"]+)\"\\]").search_all(text):
		paths[ext.get_string(2)] = ext.get_string(1)
	var node := RegEx.create_from_string("\\[node name=\"([^\"]+)\" parent=\"\\.\"[^\\]]*instance=ExtResource\\(\"([^\"]+)\"\\)\\]" \
			+ "\\ntransform = (Transform3D\\([^)]*\\))")
	for m in node.search_all(text):
		_items.append([paths.get(m.get_string(2), ""), str_to_var(m.get_string(3)), m.get_string(1)])


func test_every_building_of_the_sketch_stands_in_the_village() -> void:
	for scene: String in BUILDINGS:
		assert_gt(_count(S + scene), 0, "%s is placed" % scene.get_file())


func test_names_are_unique_keys() -> void:
	var seen := {}
	for item: Array in _items:
		assert_false(seen.has(item[2]), "%s: poi_villages draws its uuid from the name" % item[2])
		seen[item[2]] = true


func test_the_village_keeps_to_its_area() -> void:
	for item: Array in _items:
		var at: Vector3 = (item[1] as Transform3D).origin
		assert_lt(Vector2(at.x, at.z).length(), MAX_REACH_M, "%s within %d m" % [item[2], MAX_REACH_M])


func test_one_straight_avenue_runs_through() -> void:
	var xs: Array = []
	var z := NAN
	for item: Array in _items:
		if item[0] == AVENUE:
			var at: Vector3 = (item[1] as Transform3D).origin
			if is_nan(z):
				z = at.z
			assert_almost_eq(at.z, z, 0.01, "on one line")
			xs.append(at.x)
	assert_gte(xs.size(), 10, "the whole length of the village")
	xs.sort()
	for i in range(1, xs.size()):
		assert_almost_eq(xs[i] - xs[i - 1], 40.0, 0.01, "end to end, 40 m segments")


func test_pedestrian_alleys_are_closed_by_bollards() -> void:
	assert_gte(_count(BOLLARDS), 6)


## The mine is walled in (north, east, south; the cliff of its entrance to the west), and the avenue
## goes through the wall at the guard post: the gate the vehicles take.
func test_the_mine_is_walled_and_the_avenue_goes_through_its_gate() -> void:
	var avenue_z := NAN
	for item: Array in _items:
		if item[0] == AVENUE:
			avenue_z = (item[1] as Transform3D).origin.z
	var walls := _items.filter(func(it: Array) -> bool: return it[0] == WALL)
	assert_gte(walls.size(), 15, "three sides of the mine")
	for item: Array in walls:
		var xf: Transform3D = item[1]
		var half := Vector2(absf(xf.basis.x.x) * WALL_HALF.x + absf(xf.basis.z.x) * WALL_HALF.y,
				absf(xf.basis.x.z) * WALL_HALF.x + absf(xf.basis.z.z) * WALL_HALF.y)
		var across_the_avenue := half.x < half.y  # runs north-south, as the east wall does
		var crosses := across_the_avenue and xf.origin.z - half.y < avenue_z + AVENUE_HALF_WIDTH_M \
				and xf.origin.z + half.y > avenue_z - AVENUE_HALF_WIDTH_M
		assert_false(crosses, "%s leaves the gate open to the avenue" % item[2])


func test_the_placeholders_are_networked_and_named() -> void:
	var keys := FileAccess.get_file_as_string(LOCALISATION)
	for scene: String in PLACEHOLDERS:
		var root: Node3D = load(S + scene).instantiate()
		var sync := PropSync.of(root)
		assert_not_null(sync, "%s: a layout spawns it" % scene.get_file())
		if sync != null:
			assert_eq(sync.type_name, "simple_building", scene.get_file())
		var sign := root.get_node_or_null("NeonSign") as NeonSign
		if scene not in NO_SIGN:
			assert_not_null(sign, "%s: its name in neon" % scene.get_file())
		if sign != null:
			assert_true(keys.contains("\n" + sign.text_key + ","), "%s: %s translated" % [scene.get_file(), sign.text_key])
		root.free()


func test_the_ground_is_levelled_under_each_building() -> void:
	for scene: String in PLACEHOLDERS:
		if scene in NO_PAD:
			continue
		var root: Node3D = load(S + scene).instantiate()
		var ground := root.get_node_or_null("TerrainPad/Ground") as CSGBox3D
		assert_not_null(ground, "%s: a TerrainPad with its Ground box" % scene.get_file())
		if ground != null:
			assert_lt(ground.position.y + ground.size.y * 0.5, 0.0, "%s: under the floor" % scene.get_file())
		root.free()


func test_crusher_and_refinery_are_one_machine_under_another_sign() -> void:
	var signs := []
	for scene: String in ["industrial/mines/crusher.tscn", "industrial/refinery/refinery.tscn"]:
		var root: Node3D = load(S + scene).instantiate()
		var machine := root.get_node_or_null("OreProcessorMachine")
		assert_not_null(machine, scene.get_file())
		if machine != null:
			assert_eq(machine.scene_file_path, MACHINE, "the shared placeholder machine")
		signs.append((root.get_node("NeonSign") as NeonSign).text_key)
		root.free()
	assert_ne(signs[0], signs[1], "told apart by their sign only")


func _count(scene: String) -> int:
	return _items.filter(func(it: Array) -> bool: return it[0] == scene).size()
