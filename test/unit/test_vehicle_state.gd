extends GutTest
## The truck's replicated state, as the admin API and the database see it: every key from the first
## tick with its default value, seats / bays / doors keyed in snake_case, nothing but the truck's own
## doors, and an older save read back under the new keys. The truck is instantiated, not run.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const VEHICLE_DEF := "res://items_def/vehicle_def.json"

var _truck: Vehicle = null


func before_each() -> void:
	_truck = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	_truck._door_state = _truck._own_doors({})  # what _ready does


func after_each() -> void:
	_truck.free()


func test_keys_follow_godots_names_in_snake_case() -> void:
	assert_eq(VehicleNetKey.normalize("SeatDriver"), "seat_driver")
	assert_eq(VehicleNetKey.normalize("SlotFL"), "slot_fl")
	assert_eq(VehicleNetKey.normalize("Slot_FL"), "slot_fl", "an older save finds the same bay")
	assert_eq(VehicleNetKey.normalize("slot_fl"), "slot_fl", "a key stays itself")


func test_every_state_key_is_there_from_the_start() -> void:
	var state : Dictionary = _truck.full_state()
	assert_eq(state["pilot_uuid"], "", "no driver yet: empty, not missing")
	assert_eq(state["headlights"], false)
	assert_eq(state["engine"], false)
	assert_eq(state["seats"], {"seat_driver": "", "seat_passenger": ""})
	assert_eq(state["components"], {"slot_fl": "", "slot_fr": "", "slot_rl": "", "slot_rr": ""})
	var doors : Dictionary = state["doors"]
	assert_eq(doors.size(), 6, "two cab doors and four hatches")
	for id in doors:
		assert_false(doors[id], "%s starts shut" % id)


func test_every_key_sent_is_whitelisted_by_horizon() -> void:
	# A key Horizon does not index is dropped in silence (genericprops.rs): never arrives, never saved.
	var def : Dictionary = JSON.parse_string(FileAccess.get_file_as_string(VEHICLE_DEF))
	var allowed : Array = []
	for channel in def["channels"]:
		allowed.append_array(channel["properties"])
	var sent : Dictionary = _truck.full_state()
	for part in _truck._net_parts():
		part.write_changes(sent)
	for key in sent:
		assert_has(allowed, key, "'%s' must be in vehicle_def.json" % key)


func test_every_inner_key_is_snake_case() -> void:
	var state : Dictionary = _truck.full_state()
	for table in ["seats", "components", "doors"]:
		for key: String in state[table]:
			assert_eq(key, key.to_snake_case(), "%s.%s" % [table, key])


func test_a_door_that_is_not_the_trucks_is_refused() -> void:
	_truck.server_toggle_door("cube_007")
	assert_false(_truck._door_state.has("cube_007"), "a client cannot write a door into the state")
	_truck.server_toggle_door("hatch_fl")
	assert_true(_truck._door_state["hatch_fl"], "its own door opens")


func test_a_saved_state_keeps_only_the_trucks_doors() -> void:
	var restored : Dictionary = _truck._own_doors({"Cube_007": true, "hatch_rl": true})
	assert_false(restored.has("Cube_007"), "an old mesh name is dropped")
	assert_true(restored["hatch_rl"])
	assert_eq(restored.size(), 6, "every door present")


func test_an_older_save_reads_under_the_new_keys() -> void:
	_truck.client_channel_data_update({"seats": {"SeatDriver": "abc"}, "components": {"Slot_FL": "e1"}})
	assert_eq(_truck._net_seats, {"seat_driver": "abc"})
	assert_eq(_truck._net_components, {"slot_fl": "e1"})
	assert_not_null(_truck.bays.find("Slot_FL"), "a part saved with the old slot_id finds its bay")


func test_a_truck_restored_with_its_bays_is_not_refitted() -> void:
	# The factory set is fitted once, ever. A truck coming back from the database with a bay table was
	# equipped already — even with a bay emptied by hand — and must not get a ghost engine.
	_truck.client_channel_data_update({"components": {"slot_fl": "e1", "slot_fr": "", "slot_rl": "", "slot_rr": ""}})
	assert_true(_truck._factory_fitted)


func test_a_restart_puts_each_saved_part_back_in_its_bay() -> void:
	# What a server restart does: the truck's bay table comes back first (each bay waiting for a part),
	# then the parts, each with its slot_id. Each bay must take the part it is waiting for — skipping a
	# bay because it is "taken" left every engine lying on the ground after a restart.
	_truck.client_channel_data_update({"components": {"slot_fl": "e1", "slot_fr": "", "slot_rl": "", "slot_rr": ""}})
	var part : VehicleComponent = (load("res://scenes/_universe/props/vehicles/engine_t1.tscn") as PackedScene).instantiate()
	part.uuid = "e1"
	part.slot_id = "slot_fl"
	_truck.add_child(part)
	assert_eq(_truck.bays.rebind(), 1, "the part is rebound")
	assert_eq(_truck.bays.find("slot_fl").occupant, part, "into the bay that was waiting for it")
	# Seating reads the bay's global transform, which an instantiated, never-added truck has not got.
	assert_engine_error_count(2, "out of the tree: the pose, not the binding")
