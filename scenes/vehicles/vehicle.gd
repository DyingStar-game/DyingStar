@tool
class_name Vehicle
extends VehicleBody3D

## Parametric blockout vehicle (truck MVP placeholder, GDD 6.1).
##
## While we wait for the real 3D model, this builds its body, chassis collision and four
## wheels from exported dimensions — so the shape can be tuned live in the editor (CSG
## blockout) and the driving can already be developed/tested. At runtime it drives with
## Godot's VehicleBody3D physics (4x4 traction, front-wheel steering).
##
## SOLID/DRY: this is the generic vehicle base. A concrete vehicle (truck.tscn) is just
## this node with its exported dimensions; later vehicles reuse the same base. The seat /
## enter-exit / networking are added in later bricks (kept out of here for now).
##
## All generated nodes are transient (no owner) so the .tscn stays minimal: it only holds
## this node + script, and the blockout is rebuilt on load.

## Server-authoritative networking (in-game): the game server simulates the physics and
## replicates position/rotation to the clients, which show a frozen copy. In bench mode
## (no uuid assigned) the vehicle drives locally instead. (GenericProp contract.)
signal hs_server_prop_update
signal hs_server_prop_delete

## Which wheels receive engine force: FRONT = FWD, REAR = RWD, ALL = 4x4.
enum DriveMode {FRONT, REAR, ALL}
## Powertrain: ELECTRIC = single-speed instant torque; THERMAL = gearbox with auto-shift.
enum PropulsionType {ELECTRIC, THERMAL}
## Driving view: CHASE = 3rd-person orbit, CAB = 1st-person from the cab.
enum ViewMode {CHASE, CAB}

# Meta marker put on every node we generate, so a rebuild can clear the old ones.
const GENERATED := "vehicle_generated"
# Bench: the real mining rock scene, reused to test loading the bed.
const ROCK_SCENE := preload("res://scenes/props/rock/rock_mining_01.tscn")
const UUID_UTIL := preload("res://addons/uuid/uuid.gd")

# --- Driving ------------------------------------------------------------------
@export_group("Drive")
## Powertrain. ELECTRIC = single-speed, instant torque (cars/EV trucks). THERMAL = gearbox
## with automatic shifting. Switching it changes which settings below are editable.
@export var propulsion_type: PropulsionType = PropulsionType.ELECTRIC:
	set(v):
		propulsion_type = v
		notify_property_list_changed()  # show the matching settings group
## Base motor/engine torque applied per driven wheel. Total pull = this x driven wheels (x the
## gear ratio in THERMAL). Must beat m*g*sin(slope) to climb.
@export var engine_power: float = 1200.0
## Top speed (km/h).
@export var max_speed_kmh: float = 45.0
## Reverse top speed (km/h).
@export var reverse_max_kmh: float = 15.0
## How fast the applied torque ramps to the throttle (1/s). Lower = gentler launch (keeps a
## heavy vehicle from leaping off the line).
@export var torque_response: float = 2.5
## Brake force per wheel (hand brake = jump action for now).
@export var brake_force: float = 30.0
## Parking brake hold (m/s per second): how hard the engaged hand brake damps motion ABOVE the
## release speed — a real collision impulse exceeds this so a hit truck still gets pushed (it
## just re-settles). Kept dynamic, never frozen.
@export var handbrake_hold: float = 30.0
## Parking-brake "static friction": horizontal speed (m/s) below which the engaged hand brake
## FULLY cancels motion each frame — a heavy parked truck must NOT move from a player bump or a
## gentle slope. Above it (a genuine vehicle ramming) it's only damped, so a real hit still pushes.
@export var handbrake_release_speed: float = 2.0
## Maximum steering angle of the front wheels, in degrees.
@export var max_steer_deg: float = 30.0
## How fast the steering reaches its target angle (higher = snappier).
@export var steer_speed: float = 4.0
## Driven wheels: FRONT (FWD), REAR (RWD) or ALL (4x4).
@export var drive_mode: DriveMode = DriveMode.ALL:
	set(v):
		drive_mode = v
		_rebuild_deferred()
# Vehicle mass is the standard RigidBody3D "Mass" property (set on the node — ~1 t empty;
# cargo physically loads the bed on top). No duplicate here, to avoid two mass fields.
# The vehicle only drives while a pilot is aboard (enter with E) — no force-drive flag, so
# walking around on foot can never move the wheels.

# --- Dimensions (meters) — changing one rebuilds the blockout -----------------
@export_group("Body")
@export var body_length: float = 4.6:
	set(v):
		body_length = v
		_rebuild_deferred()
@export var body_width: float = 2.0:
	set(v):
		body_width = v
		_rebuild_deferred()
@export var body_height: float = 0.5:
	set(v):
		body_height = v
		_rebuild_deferred()

@export_group("Cab")
@export var cab_length: float = 1.5:
	set(v):
		cab_length = v
		_rebuild_deferred()
@export var cab_height: float = 1.9:
	set(v):
		cab_height = v
		_rebuild_deferred()

## Cabin cutout (windshield / door opening) carved from the body. It is a CSG subtraction
## added INSIDE the generated body combiner (a sibling CSGBox under the vehicle root would
## not cut — CSG only combines within one CSGCombiner). Tunable live.
@export var cab_cutout_size: Vector3 = Vector3(2.255, 0.969, 0.744):
	set(v):
		cab_cutout_size = v
		_rebuild_deferred()
@export var cab_cutout_offset: Vector3 = Vector3(-0.017, 1.454, -2.062):
	set(v):
		cab_cutout_offset = v
		_rebuild_deferred()

@export_group("Bed")
@export var bed_wall_height: float = 0.7:
	set(v):
		bed_wall_height = v
		_rebuild_deferred()

@export_group("Wheels")
@export var wheel_radius: float = 0.55:
	set(v):
		wheel_radius = v
		_rebuild_deferred()
@export var wheel_width: float = 0.35:
	set(v):
		wheel_width = v
		_rebuild_deferred()
## CLIENT-replica visual only: how far to drop the wheel meshes below their hub. On a replica the
## physics is off, so VehicleWheel3D never lowers the wheels to the suspension contact — they'd
## float at the hub. This drops the visual to ~ground level. Tune so the replica's wheels touch.
@export_range(0.0, 1.5, 0.01) var wheel_visual_drop: float = 0.5
## Distance between the front and rear axles.
@export var wheelbase: float = 3.0:
	set(v):
		wheelbase = v
		_rebuild_deferred()
## Distance between the left and right wheels.
@export var track_width: float = 1.55:
	set(v):
		track_width = v
		_rebuild_deferred()
## Suspension rest length (how far the wheel hangs below its mount). Drives ride height.
@export var suspension_rest: float = 0.4:
	set(v):
		suspension_rest = v
		_rebuild_deferred()
## Suspension spring stiffness (small 1 t truck ~20-25). Too high + any ground penetration
## launches the body.
@export var suspension_stiffness: float = 22.0
## Max force EACH suspension can push (N). Must exceed the LOADED static load per wheel
## (~5600 N at 2.3 t) with margin for bumps/landings, or the bed bottoms out when full.
@export var suspension_max_force: float = 15000.0

@export_group("Electric")
## ELECTRIC only. Full torque from a standstill up to this speed (constant-torque region),
## then torque tapers to zero at max_speed_kmh (constant-power region) — the real EV curve.
@export var base_speed_kmh: float = 25.0
## ELECTRIC only. Motor RPM shown on the gauge at top speed (single-speed reduction, no gears).
## RPM = motor_max_rpm * (speed / max_speed_kmh). Slider so the gauge feel is easy to tune.
@export_range(0.0, 12000.0, 100.0) var motor_max_rpm: float = 4500.0

@export_group("Thermal gearbox")
## THERMAL only. Per-gear torque multiplier, 1st to last (1st = strongest/slowest). Shifts
## automatically on engine RPM.
@export var gear_ratios: Array[float] = [2.5, 1.7, 1.25, 1.0, 0.8]
## THERMAL only. Engine RPM at which the gearbox shifts up / down.
@export var shift_up_rpm: float = 3400.0
@export var shift_down_rpm: float = 1400.0
## THERMAL only. Reverse gear torque multiplier.
@export var reverse_ratio: float = 2.5
## THERMAL only. Idle / redline engine RPM (the needle sweeps between them within each gear).
@export var idle_rpm: float = 800.0
@export var redline_rpm: float = 4000.0

@export_group("Debug")
## Tint the driven wheels green (idle wheels stay dark) to see FWD / RWD / 4x4 at a glance.
@export var debug_color_driven_wheels: bool = true:
	set(v):
		debug_color_driven_wheels = v
		_rebuild_deferred()

@export_group("Cargo")
## Max payload (kg) before the vehicle is overloaded (GDD load limiter). Empty 1 t + this =
## full weight (~2-2.3 t for the truck). Going over flags "overloaded" on the HUD.
@export var max_payload: float = 1300.0
## Above max_payload x this factor the vehicle is immobilized (won't move) — GDD. 1.2 = 20%.
@export var overload_immobilize: float = 1.2
## Size of the cargo bay box. Any massive body that comes to rest inside is absorbed into
## the truck (its mass is added once). Defaults roughly match the bed; tune to taste.
@export var cargo_bay_size: Vector3 = Vector3(2.0, 1.5, 3.1):
	set(v):
		cargo_bay_size = v
		_rebuild_deferred()
## Centre of the cargo bay box, relative to the vehicle origin.
@export var cargo_bay_offset: Vector3 = Vector3(0.0, 1.0, 0.75):
	set(v):
		cargo_bay_offset = v
		_rebuild_deferred()
## A body is locked into the bed once it slows below this speed (m/s).
@export var cargo_settle_speed: float = 0.6
## Show a translucent box marking the cargo bay zone.
@export var debug_show_cargo_bay: bool = true:
	set(v):
		debug_show_cargo_bay = v
		_rebuild_deferred()

# Networking (GenericProp contract). uuid is set by the prop spawn pipeline; an EMPTY uuid
# means bench / standalone mode (the vehicle drives locally instead of being replicated).
var uuid: String = ""
var type_name: String = "vehicle"
var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.ZERO
var has_parent: bool = false
## Replicated: client_uuid of the player currently driving ("" = free). Set server-side.
var pilot_uuid: String = ""

var _steer_target: float = 0.0
var _wheels: Array[VehicleWheel3D] = []
var _throttle: float = 0.0
var _pilot: Node3D = null
var _chase_cam: Node3D = null
var _cab_cam: Camera3D = null
var _view: ViewMode = ViewMode.CHASE
var _empty_mass: float = 0.0
var _occupant_mass: float = 0.0  # kg of seated players (driver + passengers), added to the mass
var _locked_cargo: Dictionary = {}
var _cargo_area: Area3D = null
var _net_last_position: Vector3 = Vector3.ZERO
var _net_last_rotation: Vector3 = Vector3.ZERO
var _net_throttle: float = 0.0  # pilot input relayed by the server (networked)
var _net_steer: float = 0.0
var _net_brake: bool = false
var _net_steering: float = 0.0  # replicated front-wheel steer angle (rad)
var _wheel_last_pos: Vector3 = Vector3.ZERO  # client: to derive wheel spin from speed
var _net_speed: float = 0.0  # client: real speed (km/h) replicated from the server
var _net_last_speed: float = 0.0  # server: last replicated speed (km/h), change detection
var _net_cargo_mass: float = 0.0  # client: real cargo load (kg) replicated from the server
var _net_last_cargo_mass: float = -1.0  # server: last replicated cargo load (kg), change detection
var _net_last_mass: float = -1.0  # server: last replicated total mass (kg), change detection
var _handbrake: bool = false  # server: hand brake engaged (holds the vehicle until throttle)
var _net_handbrake: bool = false  # client: replicated hand brake state (for the HUD)
var _net_last_handbrake: bool = false  # server: last replicated hand brake, change detection
var _interp := NetInterpolator.new()  # client-side smoothing of the replica
var _hud: VehicleDebugHud = null  # driver HUD (pilot client only)
var _powertrain := VehiclePowertrain.new()

func _ready() -> void:
	_empty_mass = mass
	_rebuild()
	if Engine.is_editor_hint():
		return
	add_to_group("vehicle")  # so a pilot can find and enter us
	_sync_powertrain()
	if _is_networked():
		# Replicated prop: place it where the server spawned it (client_channel_data_update
		# also applies position/rotation, this is the initial fallback).
		if spawn_position != Vector3.ZERO:
			position = spawn_position
		if spawn_rotation != Vector3.ZERO:
			rotation = spawn_rotation

## In-game (replicated prop) when a uuid was assigned by the spawn pipeline; bench otherwise.
func _is_networked() -> bool:
	return uuid != ""

## True when the local client drives this vehicle. The driver is NOT interpolated (lerp would
## add input lag — "floaty at the wheel"); only observed copies are smoothed.
func _is_local_driver() -> bool:
	if pilot_uuid == "":
		return false
	var agent = NetworkOrchestrator.network_agent
	if agent == null or agent.player_entity == null:
		return false
	return str(agent.player_entity.client_uuid) == pilot_uuid

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if _is_networked():
		return  # in-game: the bench debug/pilot keys are off; control goes via the player + server
	# While driving: leave with the exit action, toggle cab/chase view with F4.
	if _pilot != null:
		if event.is_action_pressed("exit"):
			exit_vehicle()
			return
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F4:
			_view = ViewMode.CAB if _view == ViewMode.CHASE else ViewMode.CHASE
			_apply_view()
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
			reset_upright()

## Show only the settings relevant to the chosen powertrain in the inspector.
func _validate_property(property: Dictionary) -> void:
	var electric_only := ["base_speed_kmh", "motor_max_rpm"]
	var thermal_only := ["gear_ratios", "shift_up_rpm", "shift_down_rpm", "reverse_ratio", "idle_rpm", "redline_rpm"]
	if propulsion_type == PropulsionType.ELECTRIC and property.name in thermal_only:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	elif propulsion_type == PropulsionType.THERMAL and property.name in electric_only:
		property.usage &= ~PROPERTY_USAGE_EDITOR

func _rebuild_deferred() -> void:
	if is_inside_tree():
		call_deferred("_rebuild")

## Clear previously generated children, then rebuild collision + visual body + wheels.
func _rebuild() -> void:
	for child in get_children():
		if child.has_meta(GENERATED):
			remove_child(child)
			child.free()
	_wheels.clear()
	_cargo_area = null
	_cab_cam = null
	_build_collision()
	_build_body_visual()
	_build_wheels()
	_build_cargo_area()
	_build_cameras()

# ------------------------------------------------------------------------------
# Build helpers
# ------------------------------------------------------------------------------
func _build_collision() -> void:
	var top: float = body_height * 0.5
	# Chassis box.
	_add_collision_box(Vector3(body_width, body_height, body_length), Vector3.ZERO)
	# Bed floor + 4 walls, so cargo rests inside the bed instead of falling through the
	# (collision-less) visual. These add to the VehicleBody3D compound collider.
	var bed_len: float = body_length - cab_length
	var bed_z: float = (body_length - bed_len) * 0.5
	var wall: float = 0.08
	_add_collision_box(Vector3(body_width, wall, bed_len), Vector3(0.0, top + wall * 0.5, bed_z))
	_add_collision_box(Vector3(wall, bed_wall_height, bed_len),
		Vector3(body_width * 0.5 - wall * 0.5, top + bed_wall_height * 0.5, bed_z))
	_add_collision_box(Vector3(wall, bed_wall_height, bed_len),
		Vector3(-(body_width * 0.5 - wall * 0.5), top + bed_wall_height * 0.5, bed_z))
	_add_collision_box(Vector3(body_width, bed_wall_height, wall),
		Vector3(0.0, top + bed_wall_height * 0.5, bed_z - bed_len * 0.5 + wall * 0.5))
	_add_collision_box(Vector3(body_width, bed_wall_height, wall),
		Vector3(0.0, top + bed_wall_height * 0.5, bed_z + bed_len * 0.5 - wall * 0.5))

func _add_collision_box(box_size: Vector3, pos: Vector3) -> void:
	var shape := CollisionShape3D.new()
	shape.set_meta(GENERATED, true)
	shape.position = pos
	var box := BoxShape3D.new()
	box.size = box_size
	shape.shape = box
	add_child(shape)

## Build the cargo bay: an Area3D that detects bodies to absorb, plus a translucent box so
## the zone is visible and tunable (Cargo group).
func _build_cargo_area() -> void:
	var area := Area3D.new()
	area.name = "CargoBay"
	area.set_meta(GENERATED, true)
	# Detect cargo via the MASK only; keep this zone off every collision layer so it doesn't eat
	# the player's interact ray (collide_with_areas) — otherwise you can't aim at a crate inside it.
	area.collision_layer = 0
	area.monitorable = false
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = cargo_bay_size
	col.shape = box
	col.position = cargo_bay_offset
	area.add_child(col)
	add_child(area)
	_cargo_area = area
	if debug_show_cargo_bay:
		var ghost := MeshInstance3D.new()
		ghost.set_meta(GENERATED, true)
		var ghost_mesh := BoxMesh.new()
		ghost_mesh.size = cargo_bay_size
		ghost.mesh = ghost_mesh
		ghost.position = cargo_bay_offset
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.8, 1.0, 0.12)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ghost.material_override = mat
		add_child(ghost)

## First-person cab camera (looks forward out the windshield). Inactive until you drive in
## cab view. The 3rd-person view reuses the shared orbit camera (found in _ready).
func _build_cameras() -> void:
	_cab_cam = Camera3D.new()
	_cab_cam.set_meta(GENERATED, true)
	_cab_cam.position = Vector3(
		-body_width * 0.25,
		body_height * 0.5 + cab_height * 0.6,
		-(body_length * 0.5 - cab_length * 0.45))
	add_child(_cab_cam)

# ------------------------------------------------------------------------------
# Enter / exit (pilot)
# ------------------------------------------------------------------------------
## A pilot takes the wheel: it stops walking, the vehicle becomes drivable, camera switches.
func enter_vehicle(pilot: Node3D) -> void:
	if _pilot != null:
		return
	_pilot = pilot
	if _chase_cam == null:
		_chase_cam = get_tree().get_first_node_in_group("chase_cam")
	if pilot.has_method("set_driving"):
		pilot.set_driving(self)
	# Seat the pilot in the cab: it rides rigidly with the truck (physics off on its side).
	pilot.reparent(self)
	pilot.position = _seat_position()
	pilot.rotation = Vector3.ZERO  # face the truck's forward (-Z)
	if _chase_cam != null and _chase_cam.has_method("set_target"):
		_chase_cam.set_target(self)
	_apply_view()

## The pilot steps out beside the cab; control and camera go back to it.
func exit_vehicle() -> void:
	if _pilot == null:
		return
	var pilot := _pilot
	_pilot = null
	engine_force = 0.0
	_throttle = 0.0
	# Put the pilot back in the world, just left of the cab (raised so it drops onto the ground).
	var drop: Vector3 = to_global(Vector3(
		-(body_width * 0.5 + 1.0), 1.0, -(body_length * 0.5 - cab_length * 0.5)))
	if get_parent() != null:
		pilot.reparent(get_parent())
	pilot.global_position = drop
	if pilot.has_method("set_walking"):
		pilot.set_walking()
	if _chase_cam != null and _chase_cam.has_method("set_target"):
		_chase_cam.set_target(pilot)
		_chase_cam.make_current()

## Local seat position in the cab (driver side), where the pilot rides while driving.
func _seat_position() -> Vector3:
	return Vector3(
		-body_width * 0.28,
		body_height * 0.5 + 0.5,
		-(body_length * 0.5 - cab_length * 0.55))

## Flip the vehicle back onto its wheels (GDD anti-rollover): keep the heading, cancel pitch
## and roll, lift it a touch and zero the velocities so it settles upright.
func reset_upright() -> void:
	var up := Vector3.UP  # bench: world up (later: gravity-up from the planet)
	var forward := -global_transform.basis.z
	forward = (forward - up * forward.dot(up))  # flatten onto the horizontal plane
	if forward.length() < 0.01:
		forward = Vector3.FORWARD
	global_transform.basis = Basis.looking_at(forward.normalized(), up)
	global_position += up * 1.0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

## Activate the camera for the current driving view (cab = 1st person, chase = 3rd person).
func _apply_view() -> void:
	if _pilot == null:
		return
	if _view == ViewMode.CAB and _cab_cam != null:
		_cab_cam.make_current()
	elif _chase_cam != null and _chase_cam.has_method("make_current"):
		_chase_cam.make_current()

## Absorb any massive body that has come to rest in the cargo bay: lock it to the truck and
## add its mass once (no double-count on the suspension, no spill). Runtime only.
func _update_cargo() -> void:
	if _cargo_area == null:
		return
	for body in _cargo_area.get_overlapping_bodies():
		# Never swallow another vehicle as cargo (drivers WILL ram a truck into a bed).
		if body == self or body is Vehicle or _locked_cargo.has(body):
			continue
		if body is RigidBody3D and body.mass > 0.0 and not body.freeze:
			if body.linear_velocity.length() < cargo_settle_speed:
				_lock_cargo(body)

## Lock a settled body into the bed: freeze it, drop its collision, ride rigidly with the
## truck, and fold its mass into the vehicle. Same idea as carried props (#124).
func _lock_cargo(body: RigidBody3D) -> void:
	_locked_cargo[body] = body.mass
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	# Keep the crate's collision LAYER (so the carry ray can still target it for retrieval); just
	# stop the truck body and the crate from fighting each other where they overlap in the bed.
	add_collision_exception_with(body)
	# Reparent into the bed WITHOUT the prop's _exit_tree firing a delete (server_parent_change
	# sets server_reparenting), then replicate the reparent so clients ride it in the bed. A raw
	# reparent() made the prop vanish in-game (its _exit_tree deleted it from Horizon).
	if body.has_method("server_parent_change"):
		body.server_parent_change(self)
		if body.has_method("send_properties_to_client"):
			body.send_properties_to_client(str(uuid))
	else:
		body.reparent(self)
	_refresh_mass()

## Release a crate from the bed back into the world / a player's hands (carry retrieval): stop
## ignoring it and drop it from the load. The caller (the carry pickup) then takes ownership.
func release_cargo(body: Node) -> void:
	if not _locked_cargo.has(body):
		return
	remove_collision_exception_with(body)
	_locked_cargo.erase(body)
	_refresh_mass()

func _refresh_mass() -> void:
	mass = _empty_mass + get_cargo_mass()

## Body mass (kg) of a seated player, added to the truck's weight while they ride.
func _player_mass(player: Node) -> float:
	return float(player.mass) if "mass" in player else 75.0

## Total PAYLOAD (kg) the truck is carrying = bed cargo + seated players. This is what the load
## limiter (max_payload / OVERLOADED) checks and what the dashboard "Load" shows. On the client
## replica the bed isn't simulated, so use the value replicated from the server.
func get_cargo_mass() -> float:
	if _is_networked() and not GameOrchestrator.is_server():
		return _net_cargo_mass
	var total := _occupant_mass
	for body in _locked_cargo:
		total += _locked_cargo[body]
	return total

## True when the cargo exceeds the max payload (GDD load limiter).
func is_overloaded() -> bool:
	return get_cargo_mass() > max_payload

## True when the cargo is so far over the limit that the vehicle can no longer move (GDD).
func is_immobilized() -> bool:
	return get_cargo_mass() > max_payload * overload_immobilize

## Server: the pilot toggles the hand brake (long press at low speed, relayed as an action).
func toggle_handbrake() -> void:
	_handbrake = not _handbrake

## True when the hand brake is engaged — server state, or the replicated one on a client (HUD).
func is_handbraked() -> bool:
	if _is_networked() and not GameOrchestrator.is_server():
		return _net_handbrake
	return _handbrake

## Drop a real mining rock above the bed so it falls in and loads the truck (bench load
## test, reusing the actual rock_mining scene). Called by the bench debug node; in game the
## real mining flow replaces it.
func spawn_cargo_rock(rock_mass: float) -> void:
	var rock := ROCK_SCENE.instantiate()
	rock.uuid = UUID_UTIL.v4()
	if "mass" in rock:
		rock.mass = rock_mass
	rock.add_to_group("cargo")
	# Drop point: above the bed centre, with a small random offset so rocks pile naturally.
	var top: float = body_height * 0.5
	var bed_len: float = body_length - cab_length
	var bed_z: float = (body_length - bed_len) * 0.5
	var local := Vector3(
		randf_range(-0.4, 0.4),
		top + bed_wall_height + 0.9,
		bed_z + randf_range(-bed_len * 0.3, bed_len * 0.3))
	var host := get_parent()
	if host == null:
		return
	host.add_child(rock)
	rock.global_position = to_global(local)

func _build_body_visual() -> void:
	var body := CSGCombiner3D.new()
	body.name = "BlockoutVisual"
	body.set_meta(GENERATED, true)
	body.use_collision = false
	add_child(body)

	var paint := _solid_material(Color(0.90, 0.45, 0.10))  # truck orange
	var top: float = body_height * 0.5  # chassis top surface (local Y)

	# Chassis slab (origin at its center).
	_add_box(body, Vector3(body_width, body_height, body_length), Vector3.ZERO, paint)

	# Cab-over: a tall, flat-faced cab at the very front (-Z), full width, over the front axle.
	_add_box(body, Vector3(body_width, cab_height, cab_length),
		Vector3(0.0, top + cab_height * 0.5, -(body_length - cab_length) * 0.5), paint)

	# Open bed behind the cab: a floor + four low side walls (loadable by hand, GDD 6.1).
	var bed_len: float = body_length - cab_length
	var bed_z: float = (body_length - bed_len) * 0.5
	var wall: float = 0.08
	_add_box(body, Vector3(body_width, wall, bed_len), Vector3(0.0, top + wall * 0.5, bed_z), paint)  # floor
	_add_box(body, Vector3(wall, bed_wall_height, bed_len),
		Vector3(body_width * 0.5 - wall * 0.5, top + bed_wall_height * 0.5, bed_z), paint)  # right wall
	_add_box(body, Vector3(wall, bed_wall_height, bed_len),
		Vector3(-(body_width * 0.5 - wall * 0.5), top + bed_wall_height * 0.5, bed_z), paint)  # left wall
	_add_box(body, Vector3(body_width, bed_wall_height, wall),
		Vector3(0.0, top + bed_wall_height * 0.5, bed_z - bed_len * 0.5 + wall * 0.5), paint)  # front wall
	_add_box(body, Vector3(body_width, bed_wall_height, wall),
		Vector3(0.0, top + bed_wall_height * 0.5, bed_z + bed_len * 0.5 - wall * 0.5), paint)  # tailgate

	# Cabin cutout: a subtraction box INSIDE this combiner so it actually carves the body.
	var cut := CSGBox3D.new()
	cut.operation = CSGShape3D.OPERATION_SUBTRACTION
	cut.size = cab_cutout_size
	cut.position = cab_cutout_offset
	body.add_child(cut)

func _add_box(parent: Node, box_size: Vector3, pos: Vector3, mat: Material) -> void:
	var b := CSGBox3D.new()
	b.size = box_size
	b.position = pos
	b.material = mat
	parent.add_child(b)

func _build_wheels() -> void:
	# Front wheels at -Z (steering), all wheels drive (4x4). The wheel NODE is the TOP
	# suspension mount: VehicleWheel3D makes the wheel hang below it by ~suspension_rest and
	# places the visual automatically. Mount it near the chassis center (not the bottom),
	# otherwise the wheel sits too low and spawns penetrating the ground -> the body is
	# launched into the air.
	var hub_y: float = 0.0
	var half_track: float = track_width * 0.5
	var half_base: float = wheelbase * 0.5
	var layout := {
		"WheelFL": [Vector3(half_track, hub_y, -half_base), true],
		"WheelFR": [Vector3(-half_track, hub_y, -half_base), true],
		"WheelRL": [Vector3(half_track, hub_y, half_base), false],
		"WheelRR": [Vector3(-half_track, hub_y, half_base), false],
	}
	for wheel_name in layout:
		var pos: Vector3 = layout[wheel_name][0]
		var is_front: bool = layout[wheel_name][1]
		var wheel := VehicleWheel3D.new()
		wheel.name = wheel_name
		wheel.set_meta(GENERATED, true)
		wheel.position = pos
		wheel.use_as_steering = is_front
		var traction := true
		match drive_mode:
			DriveMode.FRONT:
				traction = is_front
			DriveMode.REAR:
				traction = not is_front
			DriveMode.ALL:
				traction = true
		wheel.use_as_traction = traction
		wheel.wheel_radius = wheel_radius
		wheel.wheel_rest_length = suspension_rest
		wheel.suspension_stiffness = suspension_stiffness
		wheel.suspension_max_force = suspension_max_force
		wheel.damping_compression = 0.5
		wheel.damping_relaxation = 0.7
		wheel.wheel_friction_slip = 3.0
		add_child(wheel)
		_wheels.append(wheel)

		# Tire visual: a cylinder whose axis is along X (the axle).
		var tire := CSGCylinder3D.new()
		tire.radius = wheel_radius
		tire.height = wheel_width
		tire.sides = 20
		tire.rotation = Vector3(0.0, 0.0, PI * 0.5)
		var tire_color := Color(0.12, 0.12, 0.13)
		if debug_color_driven_wheels and traction:
			tire_color = Color(0.1, 0.8, 0.2)  # green = powered wheel
		tire.material = _solid_material(tire_color)
		wheel.add_child(tire)

func _solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat

# ------------------------------------------------------------------------------
# Driving (runtime only)
# ------------------------------------------------------------------------------
## Client replica: physics is off (server-authoritative), so smoothly interpolate toward the
## latest replicated transform here every render frame — otherwise the truck, and any rider's
## camera glued to a seat, would step at the network rate. Then animate the wheels.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _is_networked() or GameOrchestrator.is_server():
		return
	# Smooth for everyone, driver included: the driver is parented to the vehicle, so the camera
	# rides the smoothly-interpolated body (no per-frame world jitter). Server stays authoritative.
	_interp.update(self, delta)
	_update_wheels_visual(delta)

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _is_networked():
		# Server-authoritative: only the game server simulates + replicates. The client replica
		# has physics off; its smoothing + wheels are done in _process.
		if not GameOrchestrator.is_server():
			return
		_release_vanished_occupants()  # free seats whose player disconnected (node freed)
		_update_cargo()
		# Keep the body awake while handbraked so _integrate_forces keeps cancelling drift — a
		# parked truck that fell asleep would roll on a slope (the brake alone can't hold a skid).
		can_sleep = not _handbrake
		if is_instance_valid(_pilot):
			_apply_drive(delta)
		elif _handbrake:
			_hold_handbrake(delta)  # parked: the hand brake stays on after the driver leaves
		_replicate_transform()
		return
	# Bench / standalone: drive locally.
	_update_cargo()  # absorb settled cargo into the truck (always, even when not driving)
	if _pilot != null:
		_apply_drive(delta)
	elif _handbrake:
		_hold_handbrake(delta)

## Server: replicate position/rotation to clients when they change (same shape as a rock).
## Client: the replica is frozen (no physics), so roll + steer the wheels visually from
## the replicated speed (position delta) and steer angle.
func _update_wheels_visual(delta: float) -> void:
	var vel: Vector3 = global_position - _wheel_last_pos
	_wheel_last_pos = global_position
	var fwd_speed: float = vel.dot(-global_transform.basis.z) / maxf(delta, 0.0001)
	var spin: float = fwd_speed / maxf(wheel_radius, 0.01) * delta
	for wheel in _wheels:
		if wheel.use_as_steering:
			wheel.rotation.y = _net_steering
		if wheel.get_child_count() > 0:
			var tire: Node3D = wheel.get_child(0)
			tire.position.y = -wheel_visual_drop  # replica has no suspension → drop to ~ground
			tire.rotate_object_local(Vector3.UP, -spin)

## Speed shown on the HUD: real physics speed on the server/bench; on a client replica (frozen,
## linear_velocity is 0) use the speed replicated by the server — deriving it from the
## interpolated position gave wrong/jumpy readings.
func get_display_speed_kmh() -> float:
	if _is_networked() and not GameOrchestrator.is_server():
		return _net_speed
	return linear_velocity.length() * 3.6

## Show/hide the driver HUD. Called by the local pilot client on enter/exit (reliable,
## no dependency on pilot_uuid replication).
func set_driver_hud(show: bool) -> void:
	if show and _hud == null:
		_hud = VehicleDebugHud.new()
		add_child(_hud)
	elif not show and _hud != null:
		_hud.queue_free()
		_hud = null

func _replicate_transform() -> void:
	var my_pos: Vector3 = snapped(position, Vector3(0.001, 0.001, 0.001))
	var my_rot: Vector3 = snapped(rotation, Vector3(0.0001, 0.0001, 0.0001))
	var my_speed: float = snappedf(linear_velocity.length() * 3.6, 0.1)
	var my_cargo: float = snappedf(get_cargo_mass(), 0.1)
	var my_mass: float = snappedf(mass, 0.1)  # total weight (empty + cargo + seated players)
	if my_pos == _net_last_position and my_rot == _net_last_rotation \
			and my_speed == _net_last_speed and my_cargo == _net_last_cargo_mass \
			and _handbrake == _net_last_handbrake and my_mass == _net_last_mass:
		return
	_net_last_position = my_pos
	_net_last_rotation = my_rot
	_net_last_speed = my_speed
	_net_last_cargo_mass = my_cargo
	_net_last_handbrake = _handbrake
	_net_last_mass = my_mass
	var data := {
		"position": my_pos, "rotation": my_rot, "steering": snapped(steering, 0.001),
		"speed": my_speed, "cargo_mass": my_cargo, "handbrake": _handbrake, "mass": my_mass,
	}
	emit_signal("hs_server_prop_update", uuid, data, type_name, has_parent)

## Server: tell the clients to despawn this vehicle when it leaves the world.
func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if _is_networked() and GameOrchestrator.is_server():
		emit_signal("hs_server_prop_delete", uuid, type_name)

## Client: apply the replicated state (position/rotation/pilot) from the server.
func client_channel_data_update(data: Dictionary) -> void:
	if data.has("position"):
		var pos := Vector3(data["position"]["x"], data["position"]["y"], data["position"]["z"])
		var rot := rotation
		if data.has("rotation"):
			rot = Vector3(data["rotation"]["x"], data["rotation"]["y"], data["rotation"]["z"])
		_interp.set_target(self, pos, Basis.from_euler(rot))
	if data.has("steering"):
		_net_steering = float(data["steering"])
	if data.has("speed"):
		_net_speed = float(data["speed"])
	if data.has("cargo_mass"):
		_net_cargo_mass = float(data["cargo_mass"])
	if data.has("mass"):
		mass = float(data["mass"])  # replica: show the server's real total weight on the HUD
	if data.has("handbrake"):
		_net_handbrake = bool(data["handbrake"])
	if data.has("pilot_uuid"):
		pilot_uuid = str(data["pilot_uuid"])

## Client: reparent under the prop's parent (e.g. the planet/city) when spawned.
func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

# ------------------------------------------------------------------------------
# Networked enter / exit (server-authoritative). The pilot is replicated as pilot_uuid;
# seating/camera/driving are added in the following sub-bricks.
# ------------------------------------------------------------------------------
## Server: a player takes a seat (by node name). Refuses if the seat is unknown or taken.
## The driver seat becomes the pilot (control + HUD); passengers just ride along.
func server_enter(player: Node, seat_name: String = "") -> void:
	var seat: Node = _find_seat(seat_name)
	if seat == null or not seat.is_free():
		return
	seat.occupant_uuid = str(player.client_uuid) if "client_uuid" in player else ""
	seat.occupant = player  # kept so we can free the seat if the player disconnects (node freed)
	seat.occupant_mass = _player_mass(player)
	if "piloting" in player:
		player.piloting = true  # server-side walk lock
		player._seat_node = seat  # the player rides this seat each frame (server)
	if player.has_method("set_seated"):
		player.set_seated(true)  # drop the player's collision so it can't shove the truck
	_occupant_mass += _player_mass(player)  # the seated player adds their weight to the truck
	_refresh_mass()
	if seat.is_driver_seat():
		_pilot = player
		pilot_uuid = str(player.client_uuid) if "client_uuid" in player else ""
		_replicate_pilot()
		print("🚚 Vehicle %s: DRIVER enter (%s)" % [uuid, pilot_uuid])
	else:
		print("🚚 Vehicle %s: passenger enter (%s)" % [uuid, seat_name])

## Server: the player leaves whatever seat it occupies; frees the seat (and the pilot if it
## was the driver seat).
func server_exit(player: Node) -> void:
	var seat: Node = _find_seat_of(player)
	if seat == null:
		return
	seat.occupant_uuid = ""
	seat.occupant = null
	seat.occupant_mass = 0.0
	if "piloting" in player:
		player.piloting = false
		player._seat_node = null
	if player.has_method("set_seated"):
		player.set_seated(false)  # restore the player's collision
	_occupant_mass = maxf(0.0, _occupant_mass - _player_mass(player))  # they take their weight back
	_refresh_mass()
	if seat.is_driver_seat() and _pilot == player:
		_pilot = null
		pilot_uuid = ""
		_replicate_pilot()
		# NOTE: the hand brake stays engaged on exit (real parking brake) — _hold_handbrake keeps
		# the parked truck still even with no driver. It releases on throttle when someone drives.
	# Put the player back on the ground beside the vehicle, on the side of the seat it used.
	if player is Node3D:
		(player as Node3D).global_position = _exit_position_for_seat(seat)
	print("🚚 Vehicle %s: seat exit" % uuid)

## Drop position beside the vehicle, on the side of the given seat (left vs right, derived from
## the seat's local X so any layout works), raised so the player lands on the ground on exit.
func _exit_position_for_seat(seat: Node) -> Vector3:
	var seat_local: Vector3 = to_local((seat as Node3D).global_position)
	var side: float = -1.0 if seat_local.x <= 0.0 else 1.0
	return to_global(Vector3(side * (body_width * 0.5 + 1.0), 1.0, seat_local.z))

## All seats of this vehicle (designer-placed VehicleSeat children).
func _seats() -> Array:
	var out: Array = []
	for c in get_children():
		if c is VehicleSeat:
			out.append(c)
	return out

## Find a seat by its node name (the client sends which box it used).
func _find_seat(seat_name: String) -> Node:
	for seat in _seats():
		if seat.name == seat_name:
			return seat
	return null

## The seat currently occupied by the given player (by client_uuid).
func _find_seat_of(player: Node) -> Node:
	var who: String = str(player.client_uuid) if "client_uuid" in player else ""
	if who == "":
		return null
	for seat in _seats():
		if seat.occupant_uuid == who:
			return seat
	return null

func _replicate_pilot() -> void:
	emit_signal("hs_server_prop_update", uuid, {"pilot_uuid": pilot_uuid}, type_name, has_parent)

## Free any seat whose occupant vanished (a player who disconnected while seated has their node
## freed by the network layer). Without this the seat stays "taken" forever and a freed _pilot
## would crash the drive code. Cheap: a couple of seats per vehicle, checked each server tick.
func _release_vanished_occupants() -> void:
	var changed := false
	for seat in _seats():
		if seat.occupant_uuid == "" or is_instance_valid(seat.occupant):
			continue
		_occupant_mass = maxf(0.0, _occupant_mass - seat.occupant_mass)
		seat.occupant_uuid = ""
		seat.occupant = null
		seat.occupant_mass = 0.0
		changed = true
		if seat.is_driver_seat():
			_pilot = null
			pilot_uuid = ""
			_replicate_pilot()
		print("🚚 Vehicle %s: freed a seat whose occupant disconnected" % uuid)
	if changed:
		_refresh_mass()

## Read WASD and apply traction / steering / brake. The forward force comes from the chosen
## powertrain (electric or thermal). Reused later by the pilot path.
## Server: store the pilot's relayed driving input (throttle/steer in [-1,1], brake).
func set_drive_input(throttle: float, steer: float, braking: bool) -> void:
	_net_throttle = clampf(throttle, -1.0, 1.0)
	_net_steer = clampf(steer, -1.0, 1.0)
	_net_brake = braking

func _apply_drive(delta: float) -> void:
	var throttle_in: float
	var turn: float
	var braking: bool
	if _is_networked():
		throttle_in = _net_throttle  # forward axis sent by the pilot client
		turn = _net_steer            # steer axis
		braking = _net_brake
	else:
		throttle_in = Input.get_axis("move_back", "move_forward")  # bench: local input
		turn = Input.get_axis("move_right", "move_left")
		braking = Input.is_physical_key_pressed(KEY_SPACE)
	# Hand brake holds the vehicle until the pilot presses the throttle again.
	if _handbrake and absf(throttle_in) > 0.05:
		_handbrake = false
	# Ramp the applied torque toward the throttle (tempers the launch on any powertrain).
	_throttle = move_toward(_throttle, throttle_in, torque_response * delta)
	var forward_kmh: float = _forward_speed_kmh()

	_sync_powertrain()  # pick up any live inspector tweak (bench tuning)
	var force: float = _powertrain.force(_throttle, forward_kmh)

	# Overloaded past the hard limit: the vehicle can't move — kill the drive and hold it.
	var immobilized: bool = is_immobilized()
	if immobilized or _handbrake:
		force = 0.0

	# VehicleBody3D drives toward +Z for a positive engine_force; our cab faces -Z, so negate.
	engine_force = -force
	_steer_target = turn * deg_to_rad(max_steer_deg)
	steering = move_toward(steering, _steer_target, steer_speed * delta)
	brake = brake_force if (immobilized or braking or _handbrake) else 0.0

	# IRL a powered wheel keeps spinning once it leaves the ground. VehicleWheel3D stops the
	# visual with no contact, so spin powered airborne wheels ourselves (about their axle).
	if absf(_throttle) > 0.01:
		for wheel in _wheels:
			if wheel.use_as_traction and not wheel.is_in_contact() and wheel.get_child_count() > 0:
				wheel.get_child(0).rotate_object_local(Vector3.UP, -signf(_throttle) * 25.0 * delta)

## Cancel the hand-brake drift HERE (after the physics step), NOT in _physics_process — setting
## linear_velocity before the step fought the wheel suspension and made the body sink onto its
## chassis. We damp only the HORIZONTAL drift (in the body's plane) and keep the vertical, so the
## suspension keeps holding the truck up. Stays DYNAMIC: a collision impulse is far bigger than
## handbrake_hold * step, so a hit still pushes it (it then re-settles).
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not _handbrake:
		return
	var up: Vector3 = global_transform.basis.y
	var v: Vector3 = state.linear_velocity
	var v_up: Vector3 = up * v.dot(up)
	var v_flat: Vector3 = v - v_up
	# Static-friction style: a small horizontal speed (a player bump, slope creep) is killed
	# outright so the parked 2 t truck doesn't budge; a large one (a real ramming) is only damped,
	# so a genuine hit still pushes it. Vertical is kept so the suspension holds the truck up.
	if v_flat.length() < handbrake_release_speed:
		v_flat = Vector3.ZERO
	else:
		v_flat = v_flat.move_toward(Vector3.ZERO, handbrake_hold * state.step)
	state.linear_velocity = v_up + v_flat
	state.angular_velocity = state.angular_velocity.move_toward(Vector3.ZERO, handbrake_hold * state.step)

## Parked hand brake with no driver: lock the wheels + kill the drive. The drift cancel (and the
## velocity threshold that keeps it pushable by a real hit) is in _integrate_forces, which keeps
## firing because we hold the body awake (see _physics_process). From _physics_process.
func _hold_handbrake(_delta: float) -> void:
	engine_force = 0.0
	brake = brake_force

## Forward speed in km/h (positive when driving toward the cab, -Z).
func _forward_speed_kmh() -> float:
	return -global_transform.basis.z.dot(linear_velocity) * 3.6

## Engine/motor RPM for the gauge (depends on the powertrain).
## Copy the inspector powertrain settings into the helper (cheap; lets values be tuned
## live in the bench). The gearbox state (current gear) is preserved across syncs.
func _sync_powertrain() -> void:
	_powertrain.type = VehiclePowertrain.Type.ELECTRIC if propulsion_type == PropulsionType.ELECTRIC else VehiclePowertrain.Type.THERMAL
	_powertrain.engine_power = engine_power
	_powertrain.max_speed_kmh = max_speed_kmh
	_powertrain.reverse_max_kmh = reverse_max_kmh
	_powertrain.base_speed_kmh = base_speed_kmh
	_powertrain.motor_max_rpm = motor_max_rpm
	_powertrain.gear_ratios = gear_ratios
	_powertrain.shift_up_rpm = shift_up_rpm
	_powertrain.shift_down_rpm = shift_down_rpm
	_powertrain.reverse_ratio = reverse_ratio
	_powertrain.idle_rpm = idle_rpm
	_powertrain.redline_rpm = redline_rpm

func get_engine_rpm() -> float:
	# Base it on the DISPLAY speed (replicated) so the gauge works on the client replica too —
	# there linear_velocity is 0 (physics off). RPM uses |speed|, so the magnitude is fine.
	return _powertrain.engine_rpm(get_display_speed_kmh())

## HUD label: the current gear (THERMAL) or empty (ELECTRIC has no gears).
func get_gear_label() -> String:
	return _powertrain.gear_label()

## HUD label of the powertrain (electric or thermal).
func get_propulsion_name() -> String:
	return "Electric" if propulsion_type == PropulsionType.ELECTRIC else "Thermal"

## Human-readable label of the current drive mode (for the debug HUD).
func get_drive_mode_name() -> String:
	match drive_mode:
		DriveMode.FRONT:
			return "FWD"
		DriveMode.REAR:
			return "RWD"
		_:
			return "4x4"
