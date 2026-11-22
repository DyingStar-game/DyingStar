extends GutTest
## A trip to a village ends at the village's own teleporter cabin, not on its centre: the mining
## villages have their cargo depot across the centre, and travellers arrived inside it (playtest
## 2026-11-20). VillageArrival finds the cabin in the layout and lands the traveller before its door.

const VILLAGE := "res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn"
const FACTORY := "res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn"
const PoiVillagesScript := preload("res://scenes/_universe/structures/urban/poi_villages.gd")
## A body's radius, and a village standing on it away from every axis.
const RADIUS_M: float = 6.0e6
const CENTRE := Vector3(0.48, 0.6, 0.64)
## How much free ground the landing must have around it (m).
const CLEAR_M: float = 1.0


func _zone(layout: String = VILLAGE, basis: Basis = Basis.IDENTITY) -> Dictionary:
	return {"local_pos": CENTRE.normalized() * RADIUS_M, "basis": basis, "layout": layout}


# ---------------------------------------------------------------------------
# The cabin, read from the layout
# ---------------------------------------------------------------------------

func test_the_cabin_is_read_from_the_layout_without_instantiating_it() -> void:
	var cabin: Variant = VillageArrival.cabin_of(VILLAGE)
	assert_true(cabin is Transform3D, "the mining village has a cabin")
	var layout: Node3D = load(VILLAGE).instantiate()
	var node := layout.get_node("Teleporter") as Node3D
	assert_true((cabin as Transform3D).is_equal_approx(node.transform), "and it is where the scene puts it")
	layout.free()


func test_a_path_without_res_reads_the_same() -> void:
	assert_eq(VillageArrival.cabin_of(VILLAGE.trim_prefix("res://")), VillageArrival.cabin_of(VILLAGE))


func test_a_scene_without_a_cabin_has_none() -> void:
	assert_null(VillageArrival.cabin_of(VillageArrival.CABIN_SCENE), "the cabin itself holds no cabin")
	assert_null(VillageArrival.cabin_of("res://no/such/layout.tscn"))
	assert_null(VillageArrival.cabin_of(""))


## The landing is before the DOOR: on the side of the cabin its doorway opens on, clear of its walls.
func test_the_landing_is_before_the_door() -> void:
	var cabin: Node3D = load(VillageArrival.CABIN_SCENE).instantiate()
	var doorway := cabin.get_node("Blockout/Doorway") as Node3D
	var shell := cabin.get_node("Blockout") as CSGBox3D
	var landing: Vector3 = VillageArrival.landing_of(Transform3D.IDENTITY)
	assert_lt(doorway.position.z, 0.0, "the doorway opens on the cabin's -Z")
	assert_almost_eq(VillageArrival.DOOR_M, shell.size.z * 0.5, 0.01, "DOOR_M is the cabin's half length")
	assert_lt(landing.z, -shell.size.z * 0.5 - CLEAR_M, "outside, on that side")
	assert_almost_eq(landing.x, 0.0, 0.001, "facing the door")
	cabin.free()


# ---------------------------------------------------------------------------
# Free ground
# ---------------------------------------------------------------------------

## Is [param at] (x, z) within [param margin] of the levelled ground whose four corners are
## [param box], as LayoutFootprint._ground_corners gives them: (-,-), (-,+), (+,-), (+,+)?
func _on_ground(at: Vector2, box: Array[Vector3], margin: float) -> bool:
	var origin := Vector2(box[0].x, box[0].z)
	var along := Vector2(box[2].x, box[2].z) - origin
	var across := Vector2(box[1].x, box[1].z) - origin
	var u: float = (at - origin).dot(along.normalized())
	var v: float = (at - origin).dot(across.normalized())
	return u > -margin and u < along.length() + margin and v > -margin and v < across.length() + margin


## The items of [param layout] whose levelled ground the landing of [param path] falls on.
func _standing_on(path: String) -> PackedStringArray:
	var on: PackedStringArray = []
	var landing: Vector3 = VillageArrival.landing_of(VillageArrival.cabin_of(path))
	var layout: Node = load(path).instantiate()
	for item: Node in PoiVillagesScript.top_items(layout):
		var items: Array[Node] = [item]
		items.append_array(PoiVillagesScript.layout_children(item, layout))
		for it: Node in items:
			var corners: Array[Vector3] = LayoutFootprint._ground_corners(it, layout)
			for first: int in range(0, corners.size() - 3, 4):
				if _on_ground(Vector2(landing.x, landing.z), corners.slice(first, first + 4), CLEAR_M):
					on.append(str(it.name))
	layout.free()
	return on


## THE regression: nothing stands where the traveller lands. A building's ground is its TerrainPad, so
## a landing on no pad is a landing in no building -- the depot's pad is the one it used to fall on.
func test_the_landing_in_a_mining_village_is_on_free_ground() -> void:
	assert_eq(_standing_on(VILLAGE), PackedStringArray(), "nothing stands before the cabin's door")


func test_the_landing_in_a_factory_city_is_on_free_ground() -> void:
	assert_eq(_standing_on(FACTORY), PackedStringArray(), "nothing stands before the cabin's door")


func test_the_centre_of_a_mining_village_is_not_free_ground() -> void:
	var layout: Node = load(VILLAGE).instantiate()
	var depot := layout.get_node("cargo_depot")
	var corners: Array[Vector3] = LayoutFootprint._ground_corners(depot, layout)
	assert_true(_on_ground(Vector2.ZERO, corners.slice(0, 4), 0.0),
			"the depot lies across the layout's origin: why the centre is not where one lands")
	layout.free()


# ---------------------------------------------------------------------------
# In the planet's frame
# ---------------------------------------------------------------------------

## A village asleep is known by its data alone, with whatever rotation was stored: its frame is built
## as the village builds it on waking (PoiVillages._stand_on_ground) -- upright on the radial.
func test_the_village_frame_stands_on_the_radial() -> void:
	var tilted := Basis(Vector3(1, 0, 0), 0.7)
	var frame: Transform3D = VillageArrival.frame_of(CENTRE.normalized() * RADIUS_M, tilted)
	assert_almost_eq(frame.basis.y.dot(CENTRE.normalized()), 1.0, 0.0001, "+Y is the radial")
	assert_almost_eq(frame.basis.x.dot(frame.basis.y), 0.0, 0.0001)
	assert_almost_eq(frame.basis.z.dot(frame.basis.y), 0.0, 0.0001)
	assert_gt(frame.basis.z.dot(tilted.z), 0.0, "the heading is kept")
	assert_almost_eq(frame.basis.determinant(), 1.0, 0.0001, "a rotation, not a mirror")


func test_the_cabin_is_placed_as_the_village_places_its_items() -> void:
	var zone: Dictionary = _zone()
	var cabin: Transform3D = VillageArrival.cabin_in_planet(zone)
	var in_layout: Transform3D = VillageArrival.cabin_of(VILLAGE)
	var frame: Transform3D = VillageArrival.frame_of(zone["local_pos"], zone["basis"])
	assert_true(cabin.is_equal_approx(frame * in_layout), "village frame * item transform (poi_villages.gd)")
	var landing: Vector3 = VillageArrival.landing_of(cabin)
	assert_almost_eq(landing.distance_to(cabin.origin), VillageArrival.DOOR_M + VillageArrival.FRONT_M, 0.01)
	assert_almost_eq((landing - cabin.origin).normalized().dot(CENTRE.normalized()), 0.0, 0.001,
			"level with the cabin: along the ground, not up or down")


func test_a_village_without_a_cabin_has_no_arrival() -> void:
	assert_null(VillageArrival.cabin_in_planet(_zone(VillageArrival.CABIN_SCENE)))


# ---------------------------------------------------------------------------
# Which destination is a village
# ---------------------------------------------------------------------------

func test_a_destination_on_a_village_centre_is_that_village() -> void:
	var zone: Dictionary = _zone()
	var found: Dictionary = VillageArrival.zone_at([zone], CENTRE.normalized(), RADIUS_M)
	assert_eq(found.get("layout", ""), VILLAGE)


func test_a_point_typed_in_beside_a_village_is_left_alone() -> void:
	var zone: Dictionary = _zone()
	var frame: Transform3D = VillageArrival.frame_of(zone["local_pos"], zone["basis"])
	var beside: Vector3 = (frame * Vector3(200.0, 0.0, 0.0)).normalized()
	assert_true(VillageArrival.zone_at([zone], beside, RADIUS_M).is_empty(), "200 m out: not its centre")
	assert_true(VillageArrival.zone_at([], CENTRE.normalized(), RADIUS_M).is_empty(), "no village at all")


func test_the_nearest_of_two_villages_answers() -> void:
	var near: Dictionary = _zone(VILLAGE)
	var frame: Transform3D = VillageArrival.frame_of(near["local_pos"], near["basis"])
	var other: Dictionary = {"local_pos": frame * Vector3(20.0, 0.0, 0.0), "basis": Basis.IDENTITY,
			"layout": FACTORY}
	var found: Dictionary = VillageArrival.zone_at([other, near], CENTRE.normalized(), RADIUS_M)
	assert_eq(found.get("layout", ""), VILLAGE)
