extends GutTest
## The ARES component dispenser: its catalogue (every spec, found on disk), the server's check of what
## a client asks for, the hatch's flap, and its screen.

const SCENE := "res://scenes/_universe/structures/dispenser/component_dispenser.tscn"
const ENGINE := "res://scenes/_universe/vehicles/specs/engine_t1.tres"
const BATTERY := "res://scenes/_universe/vehicles/specs/battery_t1.tres"
const SPECS := "res://scenes/_universe/vehicles/specs/"


func test_the_catalogue_is_every_spec_on_disk() -> void:
	var paths: Array = DispenserCatalog.all(SPECS).map(func(s: Resource) -> String: return s.resource_path)
	assert_has(paths, ENGINE, "the T1 motor")
	assert_has(paths, BATTERY, "the T1 battery")
	for spec: Resource in DispenserCatalog.all(SPECS):
		assert_true(ResourceLoader.exists(spec.scene_path), "%s has a part scene" % spec.resource_path)
		assert_eq(MarkerSpawn.scene_type(load(spec.scene_path)), "vehicle_component", "and it is networked")


func test_a_village_layout_can_place_it() -> void:
	# poi_villages spawns only a layout's networked props: a machine without a PropSync was left out.
	var villages: GDScript = load("res://scenes/_universe/structures/urban/poi_villages.gd")
	for path: String in [SCENE, "res://scenes/_universe/structures/dispenser/food_dispenser.tscn",
			"res://scenes/_universe/structures/dispenser/tool_dispenser.tscn"]:
		var dispenser: Node = (load(path) as PackedScene).instantiate()
		assert_true(villages.is_spawnable(dispenser), "%s is a networked prop" % path.get_file())
		assert_eq(MarkerSpawn.scene_type(load(path)), "simple_building", "of a type Horizon already knows")
		dispenser.free()


func test_only_a_catalogue_part_is_handed_out() -> void:
	assert_not_null(DispenserCatalog.find(SPECS, ENGINE))
	assert_null(DispenserCatalog.find(SPECS, "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"),
			"a client naming any other path gets nothing")
	var dispenser: ItemDispenser = (load(SCENE) as PackedScene).instantiate()
	add_child_autofree(dispenser)
	dispenser.update_screen({"state": "dispense", "spec": "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"})
	assert_null(dispenser._pending, "refused: not a part")
	dispenser.update_screen({"state": "teleport", "spec": ENGINE})
	assert_null(dispenser._pending, "another screen's action: not ours")
	dispenser.update_screen({"state": "dispense", "spec": ENGINE})
	assert_eq(dispenser._pending, DispenserCatalog.find(SPECS, ENGINE), "a part: waits for the next physics frame")


func test_the_flap_swings_open_and_shut() -> void:
	var open_rad: float = deg_to_rad(90.0)
	var a: float = ItemDispenser.flap_angle(0.0, true, 90.0, 200.0, 0.1)
	assert_almost_eq(a, deg_to_rad(20.0), 0.0001, "falling open at its speed")
	assert_almost_eq(ItemDispenser.flap_angle(a, true, 90.0, 200.0, 10.0), open_rad, 0.0001, "no further than open")
	assert_almost_eq(ItemDispenser.flap_angle(open_rad, false, 90.0, 200.0, 10.0), 0.0, 0.0001, "shut again")


func test_the_screen_lists_the_parts_and_asks_for_the_chosen_one() -> void:
	var ui := ItemDispenserUI.new()
	add_child_autofree(ui)
	ui.setup(AresBrand.Subsidiary.HAULING, "%%DISPENSER_TITLE", DispenserCatalog.all(SPECS))
	assert_eq(ui.chosen(), DispenserCatalog.all(SPECS)[0].resource_path, "the first part chosen")
	watch_signals(ui)
	ui._on_dispense_pressed()
	assert_signal_emitted_with_parameters(ui, "dispense_requested", [ui.chosen()])
	assert_true(ui._dispense.disabled, "one request at a time")
	ui.set_tray_full(true)
	assert_eq(ui._status.text, "%%DISPENSER_TAKE_ITEMS", "the hatch is full: take what lies in it")


func test_the_status_line() -> void:
	assert_eq(ItemDispenserUI.status_key(false, false), "%%DISPENSER_PICK")
	assert_eq(ItemDispenserUI.status_key(false, true), "%%DISPENSER_SENT")
	assert_eq(ItemDispenserUI.status_key(true, true), "%%DISPENSER_TAKE_ITEMS", "the hatch first")


func test_a_delivery_takes_its_time_and_runs_one_at_a_time() -> void:
	var dispenser: ItemDispenser = (load(SCENE) as PackedScene).instantiate()
	add_child_autofree(dispenser)
	dispenser.update_screen({"state": "dispense", "spec": ENGINE})
	assert_eq(dispenser._delivery_left_s, dispenser.delivery_s, "the part comes after the delivery")
	dispenser.update_screen({"state": "dispense", "spec": BATTERY})
	assert_eq(dispenser._pending, DispenserCatalog.find(SPECS, ENGINE), "a second request while it runs: refused")


func test_the_screen_shows_the_delivery_as_a_filling_ring() -> void:
	var ui := ItemDispenserUI.new()
	add_child_autofree(ui)
	ui.setup(AresBrand.Subsidiary.HAULING, "%%DISPENSER_TITLE", DispenserCatalog.all(SPECS))
	ui.start_delivery(3.2, 5.0)
	assert_false(ui._rows.visible, "the parts give way")
	assert_true(ui._ring.visible, "to the ring")
	assert_eq(ui._ring.seconds, 4, "the whole seconds left in its middle")
	assert_almost_eq(ui._ring.progress, 0.36, 0.001, "filled as far as the delivery went")
	assert_true(ui._dispense.disabled, "no other request meanwhile")


func test_a_player_leaning_into_the_hatch_does_not_fill_it() -> void:
	var dispenser: ItemDispenser = (load(SCENE) as PackedScene).instantiate()
	add_child_autofree(dispenser)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(0.2, 0.2, 0.2)
	body.add_child(shape)
	add_child_autofree(body)
	body.global_position = dispenser.tray_marker.global_position
	body.collision_layer = 1 << (Globals.LAYER_PLAYER - 1)
	await wait_physics_frames(2)
	assert_null(dispenser._tray_blocker(), "a player pressed against the machine: the flap stays shut")
	body.collision_layer = 1 << (Globals.LAYER_PROP - 1)
	await wait_physics_frames(2)
	assert_not_null(dispenser._tray_blocker(), "a part in the hatch: it is full")


func test_the_building_walls_do_not_fill_the_hatch_but_an_item_parented_to_it_does() -> void:
	var building := Node3D.new()
	var building_sync := PropSync.new()
	building_sync.name = "PropSync"
	building_sync.uuid = "garage-uuid"
	building.add_child(building_sync)
	var dispenser: ItemDispenser = (load(SCENE) as PackedScene).instantiate()
	building.add_child(dispenser)
	var wall := _box_body(Globals.LAYER_PROP)  # the garage's model reaches into the hatch
	building.add_child(wall)
	add_child_autofree(building)
	wall.global_position = dispenser.tray_marker.global_position
	await wait_physics_frames(2)
	assert_null(dispenser._tray_blocker(), "the building's own body: the flap stays shut")
	var item := _box_body(Globals.LAYER_PROP)
	var item_sync := PropSync.new()
	item_sync.name = "PropSync"
	item_sync.uuid = "tool-uuid"
	item.add_child(item_sync)
	building.add_child(item)  # handed out: parented to the nearest networked node, the building
	item.global_position = dispenser.tray_marker.global_position
	await wait_physics_frames(2)
	assert_true(dispenser._tray_blocker() == item, "an item in the hatch, parented to the building: it is full")


func _box_body(layer: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(0.2, 0.2, 0.2)
	body.add_child(shape)
	body.collision_layer = 1 << (layer - 1)
	return body


func test_every_machine_hums_for_who_walks_past() -> void:
	for path: String in [SCENE, "res://scenes/_universe/structures/dispenser/food_dispenser.tscn",
			"res://scenes/_universe/structures/dispenser/tool_dispenser.tscn"]:
		var machine: Node = (load(path) as PackedScene).instantiate()
		var hum := machine.get_node_or_null("IdleHum") as AmbientLoop3D
		assert_not_null(hum, "%s: an idle hum" % path.get_file())
		if hum != null:
			assert_not_null(hum.sound, "with its sound")
			if hum.sound != null:
				assert_not_null(hum.sound.stream, "with its sample")
				assert_lte(hum.sound.distance, 10.0, "heard passing by, not across the garage")
		machine.free()


func test_a_batch_lies_side_by_side_across_the_hatch() -> void:
	assert_eq(ItemDispenser.batch_offset(0, 1, 0.1), 0.0, "one item: in the middle")
	assert_almost_eq(ItemDispenser.batch_offset(0, 3, 0.1), -0.1, 0.0001)
	assert_almost_eq(ItemDispenser.batch_offset(2, 3, 0.1), 0.1, 0.0001, "three: either side of the middle one")


func test_each_subsidiary_has_its_colour_and_name() -> void:
	assert_eq(AresBrand.colour(AresBrand.Subsidiary.MINING), Color(1.0, 0.4, 0.0), "Mining: orange")
	assert_eq(AresBrand.name_of(AresBrand.Subsidiary.ENERGY), "ENERGY")
