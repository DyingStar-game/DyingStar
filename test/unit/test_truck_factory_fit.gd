extends GutTest
## The MVP truck's factory fit, checked against the design sheet.
##
## test_vehicle_drive_spec.gd pins the MODEL; this pins the TRUCK — that its scene still carries
## the engines it leaves the works with, and that those engines plus its chassis land on the
## numbers the sheet designed. A hand edit to the .tscn, a renamed export or a tweaked chassis
## value would otherwise change how the truck drives with nothing to say so.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const SHEET_EMPTY_MASS := 1500.0   # mVide of the MVP column
const SANDBOX_GRAVITY := 6.867

var _truck: Vehicle = null

func before_each() -> void:
	# Instantiated but NOT added to the tree: we want the exported values, not a running vehicle
	# (_ready would build wheels, cameras, audio and a loading zone we have no use for here).
	var packed: PackedScene = load(TRUCK)
	assert_not_null(packed, "truck.tscn must load")
	_truck = packed.instantiate() as Vehicle


func after_each() -> void:
	if _truck != null:
		_truck.free()
		_truck = null


## Build the sizing model the same way the vehicle does, from the scene's own values.
func _spec() -> VehicleDriveSpec:
	var spec := VehicleDriveSpec.new()
	spec.motors.assign(_truck.factory_engines)
	spec.wheel_radius = _truck.wheel_radius
	spec.pump_efficiency = _truck.pump_efficiency
	spec.hydraulic_efficiency = _truck.hydraulic_efficiency
	spec.torque_factor = _truck.torque_factor
	spec.drag_coefficient = _truck.drag_coefficient
	spec.frontal_area = _truck.frontal_area_m2
	spec.rolling_coefficient = _truck.rolling_coefficient
	spec.rolling_factor = _truck.rolling_factor
	spec.air_density = _truck.air_density
	spec.gravity = SANDBOX_GRAVITY
	return spec


func test_truck_leaves_the_works_with_three_t1_motors() -> void:
	assert_eq(_truck.factory_engines.size(), 3, "the MVP column of the sheet says 3 T1 motors")
	for e in _truck.factory_engines:
		assert_not_null(e, "no empty slot in the factory fit")
		assert_eq(e.torque_nm, 600.0, "a T1 produces 600 Nm")
		assert_eq(e.power_w, 100000.0, "a T1 draws 100 kW")
		assert_eq(e.tier, 1, "a T1 is tier 1")


func test_chassis_matches_the_mvp_column() -> void:
	assert_almost_eq(_truck.drag_coefficient, 1.0, 0.001, "Cx")
	assert_almost_eq(_truck.frontal_area_m2, 3.0, 0.001, "frontal area (m2)")
	assert_almost_eq(_truck.pump_efficiency * _truck.hydraulic_efficiency, 0.64, 0.001,
			"transmission efficiency, which with the motor's 0.9 gives the sheet's 0.576")
	assert_almost_eq(_truck.torque_factor, 1.0, 0.001, "torque factor")
	assert_almost_eq(_truck.rolling_coefficient, 0.01, 0.0001, "ground rolling resistance")


func test_factory_fit_produces_the_sheet_figures() -> void:
	var spec := _spec()
	assert_true(spec.is_valid(), "a factory-fitted truck is drivable")
	assert_almost_eq(spec.mech_power_w() / 1000.0, 172.8, 0.1, "mech power (kW)")
	assert_almost_eq(spec.mech_torque_nm(), 1800.0, 1.0, "mech torque (Nm)")
	assert_almost_eq(spec.tractive_force_n(), 6000.0, 5.0, "tractive force (N)")
	assert_almost_eq(spec.v_max_motor_ms() * 3.6, 103.68, 0.1, "top speed (km/h)")
	assert_eq(spec.limiting_factor(SHEET_EMPTY_MASS), "MOTOR", "engine-limited, not drag-limited")
	assert_almost_eq(spec.max_acceleration(SHEET_EMPTY_MASS), 3.93, 0.02, "acceleration (m/s2)")
	assert_almost_eq(rad_to_deg(spec.max_slope_rad(SHEET_EMPTY_MASS)), 34.92, 0.05, "slope (deg)")


func test_wheel_radius_follows_the_sheet() -> void:
	# The sheet says 0.30 m and the team decided the sheet wins, so the wheel MESH is due a rescale
	# to 0.60 m diameter. Until that export lands the visible wheel overhangs the physical one by
	# 4 cm — cosmetic, and it changes no measurement. This assertion is what will catch a silent
	# revert to the old 0.34.
	assert_almost_eq(_truck.wheel_radius, 0.30, 0.001,
			"wheel radius must follow the sheet, not the current mesh")


func test_truck_has_four_generic_bays() -> void:
	# The four hatches are four identical boxes, so no bay declares what it takes. How many engines
	# the chassis will run is the CHASSIS's business (max_engines), which keeps game design out of
	# the scene and keeps a bay's node name — the key of the persisted table — a statement about
	# WHERE it is, never about what someone put in it.
	var bays: Array = _truck.bays().all()
	assert_eq(bays.size(), 4, "the mini truck model carries four hatches")
	for b in bays:
		assert_ne(b.door_id, "", "every bay names the hatch guarding it: %s" % b.name)
		assert_true(b.is_free(), "a bay starts empty: %s" % b.name)
		assert_false("Engine" in str(b.name) or "Battery" in str(b.name),
				"a bay is named for its place, not its contents: %s" % b.name)


func test_the_chassis_caps_the_engine_count_at_the_sheet_figure() -> void:
	# The sheet says "Nb moteur T1 = 3" for the MVP. With four bays available, something has to
	# refuse the fourth engine, and it has to say WHY — a refusal the player cannot read is
	# indistinguishable from a bug.
	assert_eq(_truck.max_engines, 3, "the MVP column of the sheet says 3 T1 motors")
	var bays := _truck.bays()
	bays.max_engines = _truck.max_engines
	var engine := VehicleEngineSpec.new()
	engine.display_name = "T1 Electric Motor"
	assert_eq(bays.fitted_count(VehicleComponentSpec.Kind.ENGINE), 0, "nothing fitted yet")
	assert_eq(bays.refuse_reason(engine), "", "an empty chassis takes an engine")
	assert_ne(bays.refuse_reason(null), "", "and refuses something that is not a part at all")
	# A kind with no limit declared is never refused, so shipping a battery needs no new rule.
	var battery := VehicleComponentSpec.new()
	battery.kind = VehicleComponentSpec.Kind.BATTERY
	assert_eq(bays.limit_for(VehicleComponentSpec.Kind.BATTERY), -1, "no cap on batteries yet")
	assert_eq(bays.refuse_reason(battery), "", "so a battery is accepted")


func test_every_bay_hatch_has_a_handle_to_open_it() -> void:
	# A bay names the hatch guarding it by door_id; without a matching VehicleDoorHandle that hatch
	# can never be opened, so the bay would be sealed for good — and nothing would say why.
	var handles: Array = _truck.find_children("*", "VehicleDoorHandle", true, false)
	var by_door := {}
	for h in handles:
		by_door[h.door_id] = h
	for b in _truck.bays().all():
		assert_true(by_door.has(b.door_id),
				"%s is guarded by '%s', which needs a handle" % [b.name, b.door_id])
	# The two cab doors keep theirs, and each bay adds one: six in all.
	assert_eq(handles.size(), 6, "two cab doors plus four hatches")


func test_hatch_meshes_named_by_the_handles_exist_in_the_model() -> void:
	# door_id is resolved against the GLB by NAME. A typo fails silently: the door simply never
	# moves, and the handle still answers the player.
	#
	# Looked up directly rather than through Vehicle._door_mesh(), which goes via _find_model_root()
	# and returns null outside the tree — the truck here is instantiated but never added, on
	# purpose. Asking the scene for the names is the same question without the dependency.
	for h in _truck.find_children("*", "VehicleDoorHandle", true, false):
		assert_true(_model_has_node_named(h.door_id),
				"the model has no mesh named '%s'" % h.door_id)


## Is there a node of that name anywhere under the truck? Case-insensitive, like _door_mesh().
func _model_has_node_named(wanted: String) -> bool:
	var low := wanted.to_lower()
	for n in _truck.find_children("*", "Node3D", true, false):
		if str(n.name).to_lower() == low:
			return true
	return false
