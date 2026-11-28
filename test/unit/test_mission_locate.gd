extends GutTest

## Where a mission is shown on the star chart (MissionLocate): one answer for the kiosk and the DataPad,
## per mission kind, the step under way's place first, and nothing invented when the mission says nothing.
## The objectives are shaped as the universe simulator writes them (publisher.rs, inspections.rs,
## breakdowns.rs).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_mission_locate.gd

const FROM_AT := {"x": 1000.0, "y": 6356000.0, "z": 0.0}
const TO_AT := {"x": 0.0, "y": 0.0, "z": -6356000.0}


## A warehouse transport ("ARES HAULING"): `locationTo.poiUuid` is the warehouse's persistence uuid, the
## points are in the params, and the locations carry the depots' positions and no body.
func _hauling(state: Dictionary = {}, progress: int = 0) -> Dictionary:
	return {
		"type": "transport", "status": "pending", "targetQuantity": 10, "currentProgress": progress, "state": state,
		"locationFrom": {"warehouseId": "w-from", "poiUuid": "w-from", "village": "M0001", "name": "CargoDepot_1",
			"scenename": "scenes/_universe/structures/industrial/cargo_depot.tscn", "position": FROM_AT},
		"locationTo": {"warehouseId": "w-to", "poiUuid": "w-to", "village": "F0002", "name": "CargoDepot_2",
			"position": TO_AT},
		"params": {"via": "warehouse", "source": {"kind": "poi", "poiId": "poi-from"},
			"zone": {"kind": "poi", "poiId": "poi-to"}},
		"payload": {"source": "universesimulator"},
	}


func test_a_hauling_mission_starts_at_its_source_warehouse() -> void:
	var found := MissionLocate.targets({}, [_hauling()])
	assert_eq(found.size(), 2, "the source, then the destination")
	assert_eq(found[0]["why"], MissionLocate.WHY_LOAD)
	assert_eq(found[0]["poi"], "poi-from", "the source's point, from the params")
	assert_eq(found[0]["position"], Vector3(1000.0, 6356000.0, 0.0))
	assert_eq(found[0]["scene"], "", "a warehouse's location names no body: the chart uses the player's")
	assert_eq(found[0]["name"], "M0001 · CargoDepot_1")
	assert_eq(found[1]["why"], MissionLocate.WHY_DELIVER)
	assert_eq(found[1]["poi"], "poi-to")


func test_a_warehouse_uuid_is_never_taken_for_a_point_of_interest() -> void:
	# The bug of the playtest: the kiosk asked the inventory for the warehouse's own uuid.
	for target: Dictionary in MissionLocate.targets({}, [_hauling()]):
		assert_false(str(target["poi"]).begins_with("w-"), "%s is a warehouse uuid" % target["poi"])


func test_once_loaded_a_hauling_mission_goes_to_its_destination() -> void:
	var counted := MissionLocate.targets({}, [_hauling({"loaded": 10})])
	assert_eq(counted[0]["why"], MissionLocate.WHY_DELIVER, "the whole quantity counted out")
	assert_eq(counted.size(), 1, "the source is no longer a place to go")
	var partly := MissionLocate.targets({}, [_hauling({"loaded": 4})])
	assert_eq(partly[0]["why"], MissionLocate.WHY_LOAD, "four crates of ten: still loading")
	var older := MissionLocate.targets({}, [_hauling({"loadedAt": "2026-11-28T10:00:00Z"})])
	assert_eq(older[0]["why"], MissionLocate.WHY_DELIVER, "a service that does not count: a first crate taken")
	assert_eq(MissionLocate.targets({}, [_hauling({}, 3)])[0]["why"], MissionLocate.WHY_DELIVER,
			"crates already delivered")


func test_a_mining_mission_goes_to_the_warehouse_it_fills() -> void:
	var mining := {"type": "deliver_material", "status": "pending", "targetQuantity": 10,
		"locationTo": {"poiUuid": "w-to", "village": "F0002", "name": "CargoDepot_2", "position": TO_AT},
		"params": {"via": "warehouse", "zone": {"kind": "poi", "poiId": "poi-to"}}}
	var found := MissionLocate.targets({}, [mining])
	assert_eq(found.size(), 1)
	assert_eq([found[0]["why"], found[0]["poi"]], [MissionLocate.WHY_DELIVER, "poi-to"])


func test_an_inspection_goes_to_its_zone() -> void:
	var visit := {"type": "visit", "status": "pending",
		"locationTo": {"name": "F0001-A", "scene": "tarsis_3", "village": "F0001", "poiUuid": "poi-site",
			"radiusM": 500.0, "position": {"x": 10.0, "y": 20.0, "z": 30.0}},
		"params": {"zone": {"kind": "poi", "poiId": "poi-site"}}}
	var found := MissionLocate.targets({"zones": [{"kind": "poi", "poiId": "poi-village"}]}, [visit])
	assert_eq(found[0]["why"], MissionLocate.WHY_VISIT)
	assert_eq([found[0]["poi"], found[0]["scene"]], ["poi-site", "tarsis_3"])
	assert_eq(found[0]["position"], Vector3(10.0, 20.0, 30.0), "framed from what the mission says")
	assert_eq(found[1]["poi"], "poi-village", "its village after it")


func test_a_repair_goes_to_its_machine_then_its_village() -> void:
	var repair := {"type": "manual", "status": "pending", "params": {},
		"locationTo": {"name": "M0001", "scene": "tarsis_3", "village": "M0001", "poiUuid": "poi-village",
			"machineId": "m-1"},
		"payload": {"machineId": "m-1"}}
	var found := MissionLocate.targets({"zones": [{"kind": "poi", "poiId": "poi-village"}]}, [repair])
	assert_eq(found.size(), 1, "the zone is the same village: not tried twice")
	assert_eq([found[0]["why"], found[0]["machine"], found[0]["poi"]], [MissionLocate.WHY_REPAIR, "m-1", "poi-village"])


func test_the_step_under_way_comes_first() -> void:
	var done := {"type": "visit", "status": "completed",
		"locationTo": {"poiUuid": "poi-done", "position": {"x": 1.0, "y": 0.0, "z": 0.0}, "scene": "tarsis_3"},
		"params": {"zone": {"kind": "poi", "poiId": "poi-done"}}}
	var now := {"type": "visit", "status": "pending",
		"locationTo": {"poiUuid": "poi-now", "position": {"x": 0.0, "y": 1.0, "z": 0.0}, "scene": "tarsis_3"},
		"params": {"zone": {"kind": "poi", "poiId": "poi-now"}}}
	var later := {"type": "visit", "status": "pending",
		"locationTo": {"poiUuid": "poi-later", "position": {"x": 0.0, "y": 0.0, "z": 1.0}, "scene": "tarsis_3"},
		"params": {"zone": {"kind": "poi", "poiId": "poi-later"}}}
	var found := MissionLocate.targets({}, [done, now, later])
	assert_eq(found.map(func(t: Dictionary) -> String: return t["poi"]), ["poi-now", "poi-later"],
			"a step done is no place to go; the next ones in their order")


func test_a_mission_read_from_a_list_row_has_its_zones() -> void:
	var found := MissionLocate.targets({"zones": [{"kind": "system", "system": "tarsis"},
		{"kind": "poi", "poiId": "poi-a", "poiName": "M0001"}, {"kind": "poi", "poiId": "poi-a"}]}, [])
	assert_eq(found.size(), 1, "a system is no place on a body, and a point is tried once")
	assert_eq([found[0]["why"], found[0]["poi"], found[0]["name"]], [MissionLocate.WHY_ZONE, "poi-a", "M0001"])


func test_missing_data_names_no_place() -> void:
	assert_true(MissionLocate.targets(null, null).is_empty())
	assert_true(MissionLocate.targets({}, ["not an objective", {}]).is_empty(), "an empty objective")
	assert_true(MissionLocate.targets({}, [{"type": "visit", "locationTo": {"position": {"x": 1.0}}}]).is_empty(),
			"a position missing two of its axes is no position")
	assert_true(MissionLocate.targets({}, [{"locationTo": {"poiUuid": null, "position": null}}]).is_empty(),
			"nulls are not names")


func test_a_village_alone_is_still_a_place() -> void:
	var found := MissionLocate.targets({}, [{"type": "transport_passenger", "locationTo": {"village": "F0003"}}])
	assert_eq(found.size(), 1)
	assert_eq([found[0]["village"], found[0]["poi"]], ["F0003", ""], "the chart looks the town up by its name")


func test_a_request_carries_the_targets_and_the_raw_data() -> void:
	var mission := {"id": "mis-1", "zones": []}
	var objectives := [_hauling()]
	var request := MissionLocate.request(mission, objectives)
	assert_eq(request["mission_id"], "mis-1")
	assert_eq((request["targets"] as Array).size(), 2)
	assert_same(request["mission"], mission, "references, not copies")
	assert_eq(MissionLocate.request(null, "nonsense")["objectives"], [])


func test_a_place_is_named_by_its_village_and_its_name() -> void:
	assert_eq(MissionLocate.place_name({"village": "F0001", "name": "CargoDepot_2"}), "F0001 · CargoDepot_2")
	assert_eq(MissionLocate.place_name({"village": "F0001", "name": "F0001"}), "F0001")
	assert_eq(MissionLocate.place_name({"name": "Depot"}), "Depot")
	assert_eq(MissionLocate.place_name({"village": null, "name": null}), "")
	assert_eq(MissionLocate.place_name("nope"), "")
