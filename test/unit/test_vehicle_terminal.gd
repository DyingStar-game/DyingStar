extends GutTest
## The garage's vehicle terminal: an ARES Corp item dispenser whose catalogue is the vehicles and whose
## "hatch" is the parking bay beside it -- which a player standing there fills too. It replaced the truck
## kiosk.

const TERMINAL := "res://scenes/_universe/structures/dispenser/vehicle_terminal.tscn"
const GARAGE := "res://scenes/_universe/structures/industrial/garage.tscn"
const PARTS := "res://scenes/_universe/structures/dispenser/component_dispenser.tscn"


func test_it_offers_the_truck_under_ares_corp() -> void:
	var terminal := (load(TERMINAL) as PackedScene).instantiate() as ItemDispenser
	assert_eq(terminal.brand, AresBrand.Subsidiary.CORP, "ARES Corp's colours and logo")
	var items: Array[Resource] = DispenserCatalog.all(terminal.catalogue_dir)
	assert_eq(items.size(), 1, "the truck, for now")
	assert_eq(str(items[0].scene_path), "res://scenes/_universe/vehicles/ground/trucks/truck.tscn")
	assert_ne(MarkerSpawn.scene_type(load(items[0].scene_path)), "", "a networked vehicle")
	terminal.free()


func test_a_player_on_the_bay_fills_it_not_at_a_parts_hatch() -> void:
	var terminal := (load(TERMINAL) as PackedScene).instantiate() as ItemDispenser
	var parts := (load(PARTS) as PackedScene).instantiate() as ItemDispenser
	assert_eq(terminal.tray_mask & (1 << (Globals.LAYER_PLAYER - 1)), 1 << (Globals.LAYER_PLAYER - 1),
			"a truck never lands on a player")
	assert_eq(parts.tray_mask, Globals.MASK_OBSTACLE, "a player leaning into a parts hatch does not fill it")
	assert_gt(terminal.tray_box_size.z, 6.0, "the bay holds a whole truck")
	terminal.free()
	parts.free()


func test_its_screen_speaks_of_a_bay_not_a_hatch() -> void:
	var ui := ItemDispenserUI.new()
	add_child_autofree(ui)
	ui.dispense_key = "%%TERMINAL_REQUEST"
	ui.tray_full_key = "%%TERMINAL_BAY_OCCUPIED"
	ui.setup(AresBrand.Subsidiary.CORP, "%%TERMINAL_VEHICLES_TITLE",
			DispenserCatalog.all("res://scenes/_universe/vehicles/terminal_items/"))
	assert_eq(ui._dispense.text, "%%TERMINAL_REQUEST", "the button")
	ui.set_tray_full(true)
	assert_eq(ui._status.text, "%%TERMINAL_BAY_OCCUPIED", "the bay taken")
	assert_true(ui._dispense.disabled, "nothing more until the bay is free")
	assert_eq(ItemDispenserUI.status_key(true, false), "%%DISPENSER_TAKE_ITEMS", "a dispenser keeps its words")


func test_the_garage_has_the_terminal_and_no_kiosk() -> void:
	var garage := (load(GARAGE) as PackedScene).instantiate() as Node3D
	var terminal := garage.get_node_or_null("VehicleTerminal") as ItemDispenser
	assert_not_null(terminal, "the terminal")
	assert_eq(terminal.tray_marker, garage.get_node("SpawnVehicule"), "the truck comes out on the bay")
	assert_null(garage.get_node_or_null("SpawnKiosk"), "the kiosk is gone")
	garage.free()


func test_its_screen_tilts_up_to_the_player() -> void:
	var terminal := (load(TERMINAL) as PackedScene).instantiate() as Node3D
	var facing: Vector3 = LocalFrame.of(terminal.get_node("Gui3D"), terminal).basis.z.normalized()
	assert_gt(facing.z, 0.5, "out of the machine's front")
	assert_gt(facing.y, 0.3, "tilted up, to the eyes of a player standing at it")
	assert_lt(facing.y, 0.8, "not lying flat")
	terminal.free()


func test_a_vehicle_comes_at_once_no_countdown() -> void:
	var terminal := (load(TERMINAL) as PackedScene).instantiate() as ItemDispenser
	assert_eq(terminal.delivery_s, 0.0, "the order is served on the next physics frame")
	terminal.free()


func test_the_garage_s_terminal_is_found_for_the_old_kiosk_button() -> void:
	# The NPC service's truck routine still sends "kiosk_spawn" with the garage and the old kiosk's path.
	var garage := (load(GARAGE) as PackedScene).instantiate() as Node3D
	assert_eq(ItemDispenser.vehicle_terminal_of(garage), garage.get_node("VehicleTerminal"),
			"the terminal standing where the kiosk was")
	garage.free()


func test_a_building_without_a_terminal_has_none() -> void:
	var parts := (load(PARTS) as PackedScene).instantiate() as Node3D
	var building := Node3D.new()
	building.add_child(parts)
	assert_null(ItemDispenser.vehicle_terminal_of(building), "a parts dispenser is no vehicle terminal")
	assert_null(ItemDispenser.vehicle_terminal_of(null), "no building, no terminal")
	building.free()
