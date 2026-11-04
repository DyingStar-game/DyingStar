extends GutTest
## ares_city_factory, the layout of the factory POIs (spawn_scene of their poi_village entries in
## Horizon's seed), laid out after the factory city sketch (level design > village MVP, screen 2): a
## civic centre around the crossroads of an avenue and three roads, quarters of housing, the fenced
## factory south of the avenue (its main road between two control posts), the logistics and municipal
## zones along the south road, the fenced Dedurium refinery at its end, a wind field to the south-west.
## Every item is a networked prop, spawned by poi_villages.gd: the direct children, and the containers
## under their storage area. Nobody lives here as a player: the homes are scenery, not spawn buildings.
## Read from the file: its buildings pull in materials that raise engine errors on load.

const FACTORY := "res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn"
const S := "res://scenes/_universe/structures/"
const GARAGE := S + "industrial/garage.tscn"
const CARGO := S + "industrial/cargo_depot.tscn"
const MINING := S + "industrial/mines/mining_depot.tscn"
const TELEPORTER := S + "buildings/teleporter/teleporter.tscn"
const HOME := S + "buildings/spawn_building.tscn"
const LAMPPOST := "res://scenes/_universe/props/furniture/furn_lamppost_outdoor_3.4m.tscn"
const CONTAINERS := "res://scenes/_universe/props/containers/container_"
## Every building of the sketch, by its scene.
const BUILDINGS := [
	"buildings/civic/prison.tscn", "buildings/civic/cemetery.tscn", "buildings/civic/school.tscn",
	"buildings/civic/sports_hall.tscn", "buildings/civic/gymnasium.tscn", "buildings/civic/place_of_worship.tscn",
	"buildings/civic/fire_station.tscn", "buildings/civic/courthouse.tscn", "buildings/civic/town_hall.tscn",
	"buildings/civic/police_station.tscn", "buildings/civic/clinic.tscn", "buildings/civic/geology_department.tscn",
	"buildings/civic/security_fire_station.tscn", "buildings/civic/infirmary.tscn", "buildings/civic/guard_post.tscn",
	"buildings/civic/municipal_services.tscn",
	"buildings/commerce/grocery_store.tscn", "buildings/commerce/clothing_store.tscn",
	"buildings/commerce/hardware_store.tscn", "buildings/commerce/bank.tscn", "buildings/commerce/small_bar.tscn",
	"buildings/commerce/party_hall_cinema.tscn", "buildings/commerce/driving_school.tscn",
	"buildings/commerce/car_dealership.tscn", "buildings/commerce/canteen.tscn",
	"buildings/houses/refugee_shelters.tscn", "buildings/houses/worker_houses.tscn", "buildings/houses/dormitory.tscn",
	"buildings/houses/executive_houses.tscn", "buildings/houses/motel.tscn",
	"industrial/modules/prefab_module_factory.tscn", "industrial/storage/imports_warehouse.tscn",
	"industrial/storage/cold_storage.tscn", "industrial/storage/water_reserve.tscn",
	"industrial/recycling/recycling_centre.tscn", "industrial/cargo_depot.tscn", "industrial/garage.tscn",
	"industrial/mines/mining_depot.tscn", "industrial/mines/changing_rooms.tscn",
	"industrial/mines/mine_maintenance.tscn", "industrial/power/transformer_station.tscn",
	"industrial/power/battery_park.tscn", "industrial/power/wind_field_block.tscn",
	"industrial/metallurgy/arc_furnace.tscn", "industrial/metallurgy/blast_furnace.tscn",
	"industrial/metallurgy/oxygen_plant.tscn", "industrial/metallurgy/pierce_smith_converter.tscn",
	"industrial/metallurgy/electrolytic_refinery.tscn", "industrial/metallurgy/casting_hall_iron.tscn",
	"industrial/metallurgy/casting_hall_copper.tscn", "industrial/metallurgy/casting_hall_rare_earths.tscn",
	"industrial/metallurgy/pelletizing_plant.tscn", "industrial/metallurgy/factory_office.tscn",
	"industrial/metallurgy/loading_bay_iron.tscn", "industrial/metallurgy/loading_bay_copper.tscn",
	"industrial/metallurgy/loading_bay_rare_earths.tscn", "industrial/refinery/refinery.tscn",
	"urban/streets/parking_lot.tscn", "buildings/teleporter/teleporter.tscn",
]
## The farthest an item stands from the crossroads (m): the sketch is about 1.1 km by 1.4 km.
const MAX_REACH_M := 950.0
## Depots further apart than this along one row belong to two groups (side by side: 32 m).
const SIDE_BY_SIDE_M := 40.0
## Depots this close across their heading stand on one row.
const ROW_M := 1.0

var _items: Array = []  # [scene path, Transform3D in the layout's frame, key] of every networked item


func before_all() -> void:
	for it: Dictionary in LayoutFile.items(FACTORY):
		_items.append([it["scene"], it["xform"], it["key"]])


func test_every_building_of_the_sketch_stands_in_the_city() -> void:
	for scene: String in BUILDINGS:
		assert_gt(_count(S + scene), 0, "%s is placed" % scene.get_file())


func test_it_has_no_homes() -> void:
	assert_eq(_count(HOME), 0, "a factory city houses no player: Horizon sends new players to the mining villages")


func test_its_gameplay_buildings_are_there() -> void:
	assert_gte(_count(GARAGE), 2)
	assert_gte(_count(CARGO), 2)
	assert_gte(_count(TELEPORTER), 2)
	assert_gte(_count(LAMPPOST), 20, "the roads are lit")


func test_the_city_keeps_to_its_area() -> void:
	for item: Array in _items:
		var at: Vector3 = (item[1] as Transform3D).origin
		assert_lt(Vector2(at.x, at.z).length(), MAX_REACH_M, "%s within %d m" % [item[2], MAX_REACH_M])


## The ore yards: the mining depots stand in rows of three or four, evenly spaced, one heading per row.
func test_its_mining_depots_stand_in_aligned_groups_of_three_or_four() -> void:
	var depots: Array = []  # [heading, offset across the row, position along it]
	for item: Array in _items:
		if item[0] != MINING:
			continue
		var xf: Transform3D = item[1]
		var along := Vector2(xf.basis.x.x, xf.basis.x.z).normalized()
		var p := Vector2(xf.origin.x, xf.origin.z)
		depots.append([xf.basis.get_euler().y, p.dot(Vector2(-along.y, along.x)), p.dot(along)])
	# A row: the depots of one heading on one line (within ROW_M); a wider gap along it starts a group.
	var rows: Array = []
	for d: Array in depots:
		var row: Array = []
		for r: Array in rows:
			if absf(angle_difference(r[0][0], d[0])) < 0.01 and absf(r[0][1] - d[1]) < ROW_M:
				row = r
		if row.is_empty():
			rows.append([d])
		else:
			row.append(d)
	var groups: Array = []
	for row: Array in rows:
		var xs: Array = row.map(func(d: Array) -> float: return d[2])
		xs.sort()
		var group: Array = [xs[0]]
		for i in range(1, xs.size()):
			if xs[i] - xs[i - 1] > SIDE_BY_SIDE_M:
				groups.append(group)
				group = []
			group.append(xs[i])
		groups.append(group)
	assert_gte(groups.size(), 2, "the iron yard and the copper yard")
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


func test_four_roads_meet_and_leave_the_city_at_its_snaps() -> void:
	var roads := LayoutRoads.of(FACTORY)
	assert_eq(roads.size(), 6, "the avenue, the north, south-west and south roads, the factory's two")
	var snaps := LayoutSnaps.all().get(FACTORY.trim_prefix("res://"), {}).get("snaps", []) as Array
	assert_eq(snaps.size(), 4, "a snap where each outer road leaves")
	for snap: Dictionary in snaps:
		var p := Vector2(float(snap["position"][0]), float(snap["position"][2]))
		var on_an_end := roads.any(func(r: Dictionary) -> bool:
			var pts: PackedVector2Array = r["points"]
			return p.distance_to(pts[0]) < 0.5 or p.distance_to(pts[pts.size() - 1]) < 0.5)
		assert_true(on_an_end, "%s at the end of a road" % snap["name"])
	for r: Dictionary in roads:
		assert_eq(str(r["road_type"]), "road", "for vehicles")
		assert_gte(float(r["width"]), 8.0)
	KnownEngineErrors.forgive_floor_material(self)  # the layout's buildings load the floor material


## The factory and the refinery are fenced; their roads go through: a fence opens where a road crosses.
func test_the_fences_open_at_their_gates() -> void:
	var roads := LayoutRoads.of(FACTORY)
	var fences := LayoutFences.of(FACTORY)
	assert_eq(fences.size(), 2, "the factory's and the refinery's")
	for f: Dictionary in fences:
		var open := VillageFence.open_panels(f["points"], roads)
		var gates := 0
		for k in open.size():
			if open[k] and (k == 0 or not open[k - 1]):
				gates += 1
		assert_gte(gates, 1, "a fence a road goes through")
		assert_lt(open.count(true), open.size() / 4.0, "mostly closed: no road runs along it")
	KnownEngineErrors.forgive_floor_material(self)


func test_every_item_is_a_networked_prop() -> void:
	assert_gt(_items.size(), 0)
	var seen := {}
	for item: Array in _items:
		var path: String = item[0]
		if seen.has(path):
			continue
		seen[path] = true
		assert_true(LayoutFile.is_networked(path), "%s has a PropSync" % path)
	KnownEngineErrors.forgive_floor_material(self)  # loading the cargo depot loads its floor material


func test_every_name_is_unique() -> void:
	var names := {}
	for item: Array in _items:
		assert_false(names.has(item[2]), "%s twice: its uuid is drawn from the name" % item[2])
		names[item[2]] = true


func _count(path: String) -> int:
	return _items.filter(func(it: Array) -> bool: return it[0] == path).size()
