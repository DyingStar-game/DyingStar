extends GutTest
## ares_city_factory, the layout of the factory POIs (spawn_scene of their poi_village entries in
## Horizon's seed): an industrial zone with no homes. At least two garages, mining depots aligned in
## groups of three or four, at least two cargo depots with stacked containers around them, floodlights,
## two teleporter cabins. Every item is a networked prop, spawned by poi_villages.gd: the direct children,
## and the containers under their storage area.
## Read from the file: its buildings pull in materials that raise engine errors on load.

const FACTORY := "res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn"
const GARAGE := "res://scenes/_universe/structures/industrial/garage.tscn"
const CARGO := "res://scenes/_universe/structures/industrial/cargo_depot.tscn"
const MINING := "res://scenes/_universe/structures/industrial/mines/mining_depot.tscn"
const HOME := "res://scenes/_universe/structures/buildings/spawn_building.tscn"
const FLOODLIGHT := "res://scenes/_universe/props/furniture/furn_floodlight_outdoor_lg.tscn"
const CONTAINERS := "res://scenes/_universe/props/containers/container_"
## Depots further apart than this on one line belong to two groups (side by side: 32 m, apron to apron).
const SIDE_BY_SIDE_M := 40.0

var _items: Array = []  # [scene path, Transform3D in the layout's frame, key] of every networked item


func before_all() -> void:
	var text := FileAccess.get_file_as_string(FACTORY).replace("\r\n", "\n")
	var paths := {}
	for ext in RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"([^\"]+)\" id=\"([^\"]+)\"\\]").search_all(text):
		paths[ext.get_string(2)] = ext.get_string(1)
	var node := RegEx.create_from_string("\\[node name=\"([^\"]+)\" parent=\"([^\"]+)\"[^\\]]*instance=ExtResource\\(\"([^\"]+)\"\\)\\]" \
			+ "\\ntransform = (Transform3D\\([^)]*\\))")
	var frames := {}  # a direct child's name -> its transform: what the items under it are local to
	for m in node.search_all(text):
		var xf: Transform3D = str_to_var(m.get_string(4))
		var key := m.get_string(1)
		if m.get_string(2) == ".":
			frames[key] = xf
		else:
			xf = frames[m.get_string(2)] * xf
			key = "%s/%s" % [m.get_string(2), key]  # poi_villages draws a child's uuid from this key
		_items.append([paths.get(m.get_string(3), ""), xf, key])


func test_it_has_no_homes() -> void:
	assert_eq(_count(HOME), 0, "a factory city houses nobody: Horizon sends new players to the mining villages")


func test_it_has_two_garages_two_cargo_depots_and_floodlights() -> void:
	assert_gte(_count(GARAGE), 2)
	assert_gte(_count(CARGO), 2)
	assert_gte(_count(FLOODLIGHT), 4)


func test_its_mining_depots_stand_in_aligned_groups_of_three_or_four() -> void:
	var rows := {}  # a row: depots with the same heading on one line, keyed by that line
	for item: Array in _items:
		if item[0] == MINING:
			var xf: Transform3D = item[1]
			var key := "%d|%d" % [roundi(xf.basis.get_euler().y * 100.0), roundi(xf.origin.z)]
			rows[key] = rows.get(key, []) + [xf.origin.x]
	# On one line, a group is a run of depots side by side: a wider gap starts the next group.
	var groups: Array = []
	for key: String in rows:
		var xs: Array = rows[key]
		xs.sort()
		var group: Array = [xs[0]]
		for i in range(1, xs.size()):
			if xs[i] - xs[i - 1] > SIDE_BY_SIDE_M:
				groups.append(group)
				group = []
			group.append(xs[i])
		groups.append(group)
	assert_gte(groups.size(), 2, "two groups at least")
	for group: Array in groups:
		assert_true(group.size() == 3 or group.size() == 4, "a group of three or four, got %d" % group.size())
		for i in range(1, group.size()):
			assert_almost_eq(group[i] - group[i - 1], group[1] - group[0], 0.01, "evenly spaced")


func test_containers_are_stacked_around_the_cargo_depots() -> void:
	var containers := _items.filter(func(it: Array) -> bool: return (it[0] as String).begins_with(CONTAINERS))
	assert_gte(containers.size(), 20, "plenty of them")
	var stacked := containers.filter(func(it: Array) -> bool: return (it[1] as Transform3D).origin.y > 1.0)
	assert_gt(stacked.size(), 0, "some stacked two or three high")
	for item: Array in _items:
		if item[0] != CARGO:
			continue
		var depot: Vector3 = (item[1] as Transform3D).origin
		var near := containers.filter(func(it: Array) -> bool:
			return Vector2((it[1] as Transform3D).origin.x - depot.x, (it[1] as Transform3D).origin.z - depot.z).length() < 120.0)
		assert_gte(near.size(), 8, "%s has containers around it" % item[2])


func test_every_item_is_a_networked_prop() -> void:
	assert_gt(_items.size(), 0)
	var seen := {}
	for item: Array in _items:
		var path: String = item[0]
		if seen.has(path):
			continue
		seen[path] = true
		assert_true(_networked(path), "%s has a PropSync" % path)


func test_every_name_is_unique() -> void:
	var names := {}
	for item: Array in _items:
		assert_false(names.has(item[2]), "%s twice: its uuid is drawn from the name" % item[2])
		names[item[2]] = true


## A scene with a PropSync, its own or the one of the scene it inherits.
func _networked(path: String) -> bool:
	var text := FileAccess.get_file_as_string(path)
	if text.contains("prop_sync.gd"):
		return true
	var base := RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"([^\"]+\\.tscn)\" id=\"([^\"]+)\"\\]").search(text)
	var root := RegEx.create_from_string("\\[node name=\"[^\"]+\" instance=ExtResource\\(\"([^\"]+)\"\\)\\]").search(text)
	return base != null and root != null and base.get_string(2) == root.get_string(1) and _networked(base.get_string(1))


func _count(path: String) -> int:
	return _items.filter(func(it: Array) -> bool: return it[0] == path).size()
