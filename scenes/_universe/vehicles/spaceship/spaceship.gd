class_name Spaceship
extends Vehicle

## The test spaceship, as a networked VEHICLE: handed out by the garages' vehicle terminal, boarded through
## its pilot seat (a VehicleSeat, like the truck's), flown on six axes with the physics computed BY THE
## GAME SERVER, which replicates it like any vehicle (Horizon type "vehicle", same def as the truck).
##
## Everything a Vehicle does for the network, the seats, the camera and the hand-overs is reused as is;
## what makes a truck a truck is switched off here: no wheels, no blockout body (the CSG hull, in the group
## Vehicle.MODEL_GROUP, is the model), no generated collision (the scene carries its own box), no cargo bed,
## no battery model yet (the engine starts on the key alone). The cockpit screen is the truck's
## VehicleDashboard in its SHIP layout; the two head lights are the truck's kind (group vehicle_light).
##
## Flight model (_integrate_forces, server or a standalone ship only):
##   - engine on: a hover assist cancels the gravity, so the ship holds its altitude with no input;
##   - the keys push along the ship's own axes (forward is -Z, up +Y, right +X), up to max_speed_ms;
##   - the truck's speed limiter (T) caps that top speed at its set value, easing off just under it and
##     bringing a ship already over it back down; off, the wheel still sets the value it will cap at;
##   - the truck's cruise control (Ctrl+T) holds the FORWARD speed it was set at with the key released
##     (strafe, lift and turns stay manual); back, the brake or the engine off switch it off;
##   - an axis with no input is brought back to rest (flight assist), all of them with the brake --
##     except the forward axis while the cruise control holds it;
##   - the mouse and the roll keys ask for a TURN RATE, reached at angular_accel_deg;
##   - engine off: no thrust, no hover, no assist -- it falls and lands on its hull.
## The air holds it back as it holds the truck (VehicleResistance, from the base class), without rolling.
##
## Walking inside, in flight too (docs/SPACESHIP.md): the hull's collision is hollow (a compound of boxes on
## the root: floor, walls, roof, dashboard, console, the rear ramp that opens and shuts), the cabin's InteriorZone (ShipInteriorRider)
## makes whoever walks in a child of the ship on the server, the ShipPhysicsGrid holds them to its floor
## (priority over the planet: Player.pick_gravity_area), and the pilot leaving the seat stands up in the
## cabin, at ExitPoint, still aboard (_exit_frame, _exit_position_for_seat).

## Axes of a flight input, each -1..1 (see flight_input).
const AXES: Array[String] = ["throttle", "strafe", "lift", "roll", "pitch", "yaw"]

@export_group("Flight")
## Thrust of the forward / backward keys (N), along the ship's -Z. With the 1 t hull, 20000 N is 20 m/s2.
## Higher = harder acceleration.
@export_range(0.0, 200000.0, 100.0) var thrust_forward_n: float = 20000.0
## Thrust of the strafe keys, left / right (N), along the ship's X. Higher = quicker side steps.
@export_range(0.0, 200000.0, 100.0) var thrust_strafe_n: float = 12000.0
## Thrust of the up / down keys (N), along the ship's Y, ON TOP of the hover that cancels the gravity.
## Higher = quicker climbs and dives.
@export_range(0.0, 200000.0, 100.0) var thrust_lift_n: float = 15000.0
## Top speed along each axis (m/s): past it the keys stop pushing that way (the air and the assist still
## act). Higher = faster ship, but the ground has to stream in fast enough under it.
@export_range(1.0, 2000.0, 1.0) var max_speed_ms: float = 512.0
## Flight assist: the strongest deceleration (m/s2) it uses to bring an axis with no input back to rest.
## Higher = the ship stops sooner when the key is released; 0 = it drifts like in space.
@export_range(0.0, 50.0, 0.5) var assist_decel_ms2: float = 8.0
## Flight assist: how fast (1/s) it follows the speed down near rest, under assist_decel_ms2. Higher =
## firmer hold, too high = a stutter at rest.
@export_range(0.1, 10.0, 0.1) var assist_response: float = 1.5
## Turn rate (deg/s) asked by the mouse, full up or down. Higher = twitchier pitch.
@export_range(0.0, 360.0, 1.0) var max_pitch_rate_deg: float = 60.0
## Turn rate (deg/s) asked by the mouse, full left or right. Higher = twitchier yaw.
@export_range(0.0, 360.0, 1.0) var max_yaw_rate_deg: float = 45.0
## Roll rate (deg/s) of the roll keys. Higher = faster roll.
@export_range(0.0, 360.0, 1.0) var max_roll_rate_deg: float = 90.0
## How fast the turn rate reaches what is asked (deg/s2), and comes back to zero when it is released.
## Higher = snappier turns, lower = a heavier ship.
@export_range(1.0, 1440.0, 1.0) var angular_accel_deg: float = 180.0
@export_group("")

## Key of a flight input set by apply_cruise: the forward axis is held by the cruise control, so the
## flight assist leaves it alone (flight_force).
const HOLD_FORWARD := "hold_forward"

## SERVER: the pilot's last flight input (see flight_input), cleared when nobody is at the controls.
var _flight: Dictionary = {}
## SERVER: the input the thrusters last applied -- the pilot's, with the cruise control's throttle on
## the forward axis -- for the power gauge.
var _applied: Dictionary = {}


func _ready() -> void:
	super._ready()
	_handbrake = false  # no parking brake: the hull rests on the ground, the hover holds it in the air


## SERVER: store the pilot's relayed flight input (PlayerServer "vehicle_input").
func set_flight_input(data: Dictionary) -> void:
	_flight = flight_input(data)


## SERVER: the ignition key. No motor or battery model on the ship yet: the key alone starts it.
func toggle_engine() -> void:
	set_engine(not _engine_on)
	print("[Spaceship] ignition: %s" % ("on" if _engine_on else "off"))


## SERVER: the head light, which needs no battery here either (see toggle_engine).
func toggle_headlights() -> void:
	set_headlights(not _headlights_on)


# --- The rear ramp ------------------------------------------------------------------------------------

## The rear ramp's door id: its pivot under the hull (Hull/Ramp, hinged at the cabin floor's rear edge)
## and its VehicleDoorHandle (RampHandle). Shut, it stands up and closes the cabin; open, it lies down to
## the ground. A door like the truck's (Vehicle._door_state, replicated and saved), swung by code.
const RAMP_DOOR := "ramp"
## The ramp's drawn leaf, under its pivot; the collision box HullRamp follows it (_set_door_angle).
const RAMP_LEAF := "RampLeaf"


## SERVER: the pilot's ramp key (PlayerServer "ship_ramp"): open or shut it from the seat.
func server_toggle_ramp() -> void:
	server_toggle_door(RAMP_DOOR)


## Vehicle swings the ramp's pivot; the hull's collision is the root's own boxes (a CollisionShape3D cannot
## ride a pivot), so its ramp box is put where the drawn leaf now is, at every step of the swing.
func _set_door_angle(deg: float, door: Node3D, axis: Vector3) -> void:
	super._set_door_angle(deg, door, axis)
	if is_instance_valid(door) and String(door.name) == "Ramp":
		_fit_ramp_collision(door)


## Put HullRamp on the ramp's leaf, through the transforms down from the root (no global: it runs out of
## the tree in the tests and before the ship is placed).
func _fit_ramp_collision(pivot: Node3D) -> void:
	var leaf := pivot.get_node_or_null(RAMP_LEAF) as Node3D
	var box := get_node_or_null("HullRamp") as CollisionShape3D
	if leaf == null or box == null:
		return
	var t: Transform3D = leaf.transform
	var n: Node = pivot
	while n != null and n != self:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	box.transform = t


# --- What a truck has and a ship has not -------------------------------------------------------------

## The scene carries its own collision, a hollow hull of boxes one walks in: nothing generated (the
## truck's would be a chassis and a bed).
func _build_collision() -> void:
	pass


## SERVER: the pilot getting up stays aboard -- a child of the ship, riding it (ShipInteriorRider adopts
## them) -- instead of being dropped beside the hull, possibly in flight.
func _exit_frame() -> Node:
	return self


## SERVER: where the pilot getting up stands: ExitPoint, in the cabin behind the seat.
func _exit_position_for_seat(seat: Node) -> Vector3:
	var exit_point := get_node_or_null("ExitPoint") as Node3D
	return exit_point.global_position if exit_point != null else super._exit_position_for_seat(seat)


## No wheels: Vehicle's code reads an empty _wheels as "nothing touches the ground".
func _build_wheels() -> void:
	pass


## No cargo bed.
func _build_cargo_area() -> void:
	pass


## The CSG hull is the model, inside the tree or not: never the truck's blockout.
func _has_real_model() -> bool:
	return true


## How far (m) the hull's bottom is below the origin, for the surface safety net (Vehicle has wheels there).
func _ground_clearance() -> float:
	return maxf(0.0, -_nav_footprint_get().position.y)


## The engine note's rev (0..1) is the thrust asked, not a wheel's speed: the idle loop (Vehicle's
## sfx_engine_idle) rises with it. The thrust loop and the puffs are SpaceshipSound's.
func _rev_ratio() -> float:
	return get_power_share()


## No battery model yet: nothing to run dry.
func _cut_if_no_energy() -> void:
	pass


## The bays only weigh: an empty bay must not stop an engine the ship does not take from them.
func _on_bays_changed() -> void:
	bays.rebuild_drive_spec()
	_refresh_mass()


## SERVER, with a pilot aboard: no wheel to drive. The forces are applied in _integrate_forces; here only
## the dashboard's power gauge is kept (replicated as "power").
func _apply_drive(_delta: float) -> void:
	engine_force = 0.0
	brake = 0.0
	steering = 0.0
	_power_share = flight_power_share(_applied) if _engine_on else 0.0


# --- Flight ------------------------------------------------------------------------------------------

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_handbrake = false  # a hand-over or a tampered request may set it: it would hold the hull in the air
	super._integrate_forces(state)  # gravity up and strength, the air's drag (no rolling: no wheel grounded)
	if _is_networked() and not _server_live:
		return  # a replica: the server flies it
	if not is_instance_valid(_pilot):
		_flight = {}  # nobody at the controls: no stale key keeps pushing, the next pilot starts neutral
	var frame: Basis = state.transform.basis.orthonormalized()
	var local_velocity: Vector3 = frame.inverse() * state.linear_velocity
	# Before the engine-off return: a dead engine switches the cruise control off, as on the truck.
	_applied = apply_cruise(_flight, cruise, -local_velocity.z * 3.6, _engine_on)
	if not _engine_on:
		return
	state.apply_central_force(hover_force(state.total_gravity, mass, true))
	var thrust := Vector3(thrust_strafe_n, thrust_lift_n, thrust_forward_n)
	var top: float = key_top_speed(max_speed_ms, limiter.enabled, limiter.cap_kmh)
	var local_force: Vector3 = flight_force(_applied, local_velocity, thrust, top,
			assist_decel_ms2, assist_response, mass, true, limiter.taper_kmh / 3.6)
	state.apply_central_force(frame * local_force)
	var max_rates := Vector3(deg_to_rad(max_pitch_rate_deg), deg_to_rad(max_yaw_rate_deg),
			deg_to_rad(max_roll_rate_deg))
	var spin: Vector3 = angular_step(frame.inverse() * state.angular_velocity, _flight, max_rates,
			deg_to_rad(angular_accel_deg), state.step, true)
	state.angular_velocity = frame * spin


## [param data] as a flight input: every axis of AXES clamped to -1..1 (0 when absent or not a number),
## and "brake" as a bool. Axes: throttle +1 = forward, strafe +1 = right, lift +1 = up, roll +1 = right
## wing down, pitch +1 = nose up, yaw +1 = nose right. Pure.
static func flight_input(data: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for axis: String in AXES:
		var value: Variant = data.get(axis, 0.0)
		out[axis] = clampf(float(value), -1.0, 1.0) if (value is float or value is int) else 0.0
	out["brake"] = bool(data.get("brake", false))
	return out


## The force (N) the thrusters and the flight assist apply, in the SHIP's frame (+X right, +Y up, -Z
## forward), for [param input] (flight_input) at [param local_velocity] (m/s, ship frame). [param thrust] is
## the full thrust per axis (N): x = strafe, y = lift, z = forward/back. An axis pushed eases off over the
## last [param taper_ms] m/s under [param max_speed] in its direction (0 = full thrust up to it), stops
## pushing at it, and past it is brought back down to it (a limiter switched on at speed); an axis left
## alone -- every axis under the brake -- is brought back to rest, at most [param assist_decel] m/s2,
## [param assist_response_s] per second near rest, except the forward axis when the input holds it
## (HOLD_FORWARD, the cruise control: it coasts). Nothing with the engine off. Pure.
static func flight_force(input: Dictionary, local_velocity: Vector3, thrust: Vector3, max_speed: float,
		assist_decel: float, assist_response_s: float, mass_kg: float, engine_on: bool,
		taper_ms: float = 0.0) -> Vector3:
	if not engine_on:
		return Vector3.ZERO
	var asked := Vector3(float(input.get("strafe", 0.0)), float(input.get("lift", 0.0)),
			-float(input.get("throttle", 0.0)))
	asked = asked.clamp(-Vector3.ONE, Vector3.ONE)
	var braking: bool = bool(input.get("brake", false))
	var held_forward: bool = bool(input.get(HOLD_FORWARD, false)) and not braking
	var out := Vector3.ZERO
	for i in 3:
		var a: float = 0.0 if braking else asked[i]
		var v: float = local_velocity[i]
		if a != 0.0:
			if a * v <= 0.0:
				out[i] = a * thrust[i]  # from rest, or against the motion: always full thrust
			elif absf(v) < max_speed:
				out[i] = a * thrust[i] * taper_share(absf(v), max_speed, taper_ms)
			else:
				out[i] = -signf(v) * minf(assist_decel, (absf(v) - max_speed) * assist_response_s) * mass_kg
		elif not (i == 2 and held_forward):
			out[i] = -clampf(v * assist_response_s, -assist_decel, assist_decel) * mass_kg
	return out


## The share (0..1) of an axis' thrust kept at [param speed] (m/s, toward the push) under [param top]:
## full until [param taper] m/s under it, then down to nothing at it, so the ship settles on the top speed
## instead of banging against it (the truck's limiter does the same). Pure.
static func taper_share(speed: float, top: float, taper: float) -> float:
	if taper <= 0.0:
		return 1.0 if speed < top else 0.0
	return clampf((top - speed) / taper, 0.0, 1.0)


## The turn rate (rad/s, ship frame) one step of [param delta] s later: from [param current_local] toward
## the rate [param input] asks (pitch about +X, yaw about -Y, roll about -Z, each up to its
## [param max_rates] component; zero under the brake), changing by at most [param accel] rad/s2. With the
## engine off nothing steers: the rate is left as it is. Pure.
static func angular_step(current_local: Vector3, input: Dictionary, max_rates: Vector3, accel: float,
		delta: float, engine_on: bool) -> Vector3:
	if not engine_on:
		return current_local
	var target := Vector3.ZERO
	if not bool(input.get("brake", false)):
		target = Vector3(
				clampf(float(input.get("pitch", 0.0)), -1.0, 1.0) * max_rates.x,
				-clampf(float(input.get("yaw", 0.0)), -1.0, 1.0) * max_rates.y,
				-clampf(float(input.get("roll", 0.0)), -1.0, 1.0) * max_rates.z)
	return current_local.move_toward(target, maxf(accel, 0.0) * maxf(delta, 0.0))


## The top speed (m/s) the keys push to: [param max_ms] with the limiter off; with it on
## ([param limiter_on], T), its set speed [param cap_kmh] (capped_speed). Pure.
static func key_top_speed(max_ms: float, limiter_on: bool, cap_kmh: float) -> float:
	return capped_speed(max_ms, cap_kmh) if limiter_on else maxf(max_ms, 1.0)


## The limiter's set speed as a top speed (m/s): [param cap_kmh] (the wheel, vehicle_limiter_step, in the
## scene's limiter_step_kmh: 20 m/s a notch), never past [param max_ms] nor under 1 m/s. Pure.
static func capped_speed(max_ms: float, cap_kmh: float) -> float:
	return clampf(cap_kmh / 3.6, 1.0, maxf(max_ms, 1.0))


## The flight input the thrusters apply, from the pilot's [param input] (flight_input) and the
## [param cruise_control] (the vehicle's cruise), at [param forward_kmh] (the ship's -Z speed, km/h). The brake or the engine off
## ([param engine_on]) switch it off; otherwise its drive_throttle drives the forward axis (a key
## back, or forward once released since Ctrl+T, switches it off and the key drives, as on the truck).
## While it still holds, the input carries HOLD_FORWARD, so the flight assist leaves that axis alone.
## Strafe, lift and the turns are the pilot's, untouched. Changes only [param cruise_control].
static func apply_cruise(input: Dictionary, cruise_control: VehicleCruiseControl, forward_kmh: float,
		engine_on: bool) -> Dictionary:
	if not engine_on or bool(input.get("brake", false)):
		cruise_control.cancel()
	if not cruise_control.enabled:
		return input
	var out: Dictionary = input.duplicate()
	out["throttle"] = cruise_control.drive_throttle(float(input.get("throttle", 0.0)), forward_kmh)
	out[HOLD_FORWARD] = cruise_control.enabled
	return out


## The hover assist (N, world frame): exactly the weight of [param mass_kg] under [param gravity] (m/s2),
## upward, so the ship holds its altitude with no input. Nothing with the engine off. Pure.
static func hover_force(gravity: Vector3, mass_kg: float, engine_on: bool) -> Vector3:
	return -gravity * mass_kg if engine_on else Vector3.ZERO


## The share of full thrust asked by [param input] (0..1): its strongest translation axis. Pure.
static func flight_power_share(input: Dictionary) -> float:
	var share: float = 0.0
	for axis: String in ["throttle", "strafe", "lift"]:
		share = maxf(share, absf(float(input.get(axis, 0.0))))
	return clampf(share, 0.0, 1.0)
