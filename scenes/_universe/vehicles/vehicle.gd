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
# Thickness of the generated bed floor / walls (m). Shared by the collider and the cargo-rest math.
const BED_WALL_THICKNESS := 0.08
# Bench: the real mining rock scene, reused to test loading the bed.
const ROCK_SCENE := preload("res://scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn")
const UUID_UTIL := preload("res://addons/uuid/uuid.gd")
## Group a dev adds to any Light3D in their vehicle scene to make it a head light (drop-in, no code).
const LIGHT_GROUP := "vehicle_light"
## Group put (in Godot) on the instanced real 3D model (GLB) root. Its presence (or real wheels)
## switches off the procedural blockout — the model provides body/wheels/steering wheel/doors.
const MODEL_GROUP := "vehicle_model"
## How far the horn is taken down (dB) during its fade-out, before the player is stopped.
const HORN_FADE_DB := -30.0
## Scan the bed for a settled fallen crate every N physics frames (see _scan_bay_for_settled_cargo).
const BAY_SCAN_FRAMES := 6

# --- Driving ------------------------------------------------------------------
@export_group("Drive")
## Ignition: the engine must be started (key I, driver only) before the vehicle can drive, and it can
## only be switched on/off while standing still — below this speed (km/h). A vehicle spawns engine off.
@export_range(0.0, 20.0, 0.5) var ignition_max_kmh: float = 3.0
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
## Engine braking + rolling resistance: brake force applied per wheel when coasting (no throttle,
## no brake). VehicleWheel3D models neither, so without this the truck rolls forever on the flat.
## Keep it well below brake_force — it should bleed speed off gently, not stop the truck dead.
@export var engine_brake: float = 6.0
## Parking brake hold (m/s per second): how hard the engaged hand brake damps motion ABOVE the
## release speed — a real collision impulse exceeds this so a hit truck still gets pushed (it
## just re-settles). Kept dynamic, never frozen.
@export var handbrake_hold: float = 30.0
## Parking-brake "static friction": horizontal speed (m/s) below which the engaged hand brake
## FULLY cancels motion each frame — a heavy parked truck must NOT move from a player bump or a
## gentle slope. Above it (a genuine vehicle ramming) it's only damped, so a real hit still pushes.
@export var handbrake_release_speed: float = 2.0
## Driven wheels: FRONT (FWD), REAR (RWD) or ALL (4x4).
@export var drive_mode: DriveMode = DriveMode.ALL:
	set(v):
		drive_mode = v
		_rebuild_deferred()
# Vehicle mass is the standard RigidBody3D "Mass" property (set on the node — ~1 t empty;
# cargo physically loads the bed on top). No duplicate here, to avoid two mass fields.
# The vehicle only drives while a pilot is aboard (enter with E) — no force-drive flag, so
# walking around on foot can never move the wheels.
## Center of mass, as an offset (m) from the wheelbase center (average of the wheel positions). We pin
## the COM ourselves instead of letting the RigidBody derive it from the collision shapes — otherwise
## the col_ pieces (a big cab box, thin bed pieces) drag it forward and the truck nose-dives. Default
## (0,0,0) = balanced on the wheels; lower Y (negative) for roll stability, shift Z for a weight bias.
@export var center_of_mass_offset: Vector3 = Vector3.ZERO

@export_group("Steering")
## Maximum steering angle of the front wheels, in degrees.
@export var max_steer_deg: float = 30.0
## How fast the wheels turn toward the held direction, in rad/s. Lower = more progressive
## (the wheels + steering wheel build up their angle instead of snapping to full lock).
@export var steer_speed: float = 1.6
## How fast the wheels return to centre when the pilot releases the key, in rad/s. A bit
## snappier than steer_speed so the truck straightens up promptly, like a real self-centring wheel.
@export var steer_return_speed: float = 3.0
## Above this forward speed (km/h) the steering lock shrinks (down to steer_min_ratio of max) so
## the truck can't snap-turn at speed — agile when slow, stable when fast. Set 0 to disable.
@export var steer_speed_falloff_kmh: float = 80.0
## Fraction of the max steer angle still available at/above steer_speed_falloff_kmh.
@export var steer_min_ratio: float = 0.35
@export_subgroup("Steering wheel (visual)")
## Steering wheel cosmetic ratio: how many radians the volant turns per radian of front-wheel
## steer (real cars ~8-16 lock-to-lock). Cosmetic only — does not affect driving.
@export var steering_wheel_ratio: float = 8.0
## The steering wheel's OWN local axis it spins about (its disc/column axis). Intrinsic to the mesh,
## so it's tilt-independent: try a cardinal axis (0,0,1)/(0,1,0)/(1,0,0) — one matches the disc.
@export var steering_wheel_axis: Vector3 = Vector3(0.0, 0.0, 1.0)

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

# --- Real 3D model (Blender GLB) — all OPTIONAL drop-ins -----------------------
# When a real model is present (a child in group "vehicle_model", or wheel meshes named below),
# the procedural blockout VISUAL is skipped; collisions/cameras/cargo + invisible VehicleWheel3D
# physics are still built. The designer ships the GLB; gameplay nodes (seats, cargo, cameras,
# door handles) are placed in Godot. Names are matched case-insensitively, ignoring _LODx.
@export_group("Real 3D model")
## Spin axis of a real wheel mesh, in the mesh's local space (its axle). Blender +Y-up export
## usually leaves the axle on local X. Flip/change if real wheels spin around the wrong axis.
@export var real_wheel_spin_axis: Vector3 = Vector3.RIGHT
## Door fallback ONLY (when a door has no Blender animation clip): instant hinge angle in degrees…
@export var door_open_angle_deg: float = 75.0
## …about this local axis (the door's hinge). The real swing is authored in Blender.
@export var door_hinge_axis: Vector3 = Vector3.UP

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
## Designer-placed box (a CollisionShape3D with a BoxShape3D) marking WHERE a dropped item is allowed
## to load/stick. Drop a crate inside it (from in the bed or reaching over) and it loads. Leave unset
## to fall back to the cargo_bay box. Its physics collision is turned off at runtime — it is only a
## zone marker. (The truck wires its "Cargo_loading_zone" node here.)
@export var cargo_loading_zone: CollisionShape3D
## A body is locked into the bed once it slows below this speed (m/s).
@export var cargo_settle_speed: float = 0.6
## Tilt (degrees from upright) past which the bed unlocks and spills its load — a rollover drops
## the cargo (GDD: the lock releases on a certain inclination). 0 disables.
@export var cargo_unlock_tilt_deg: float = 65.0
## Show a translucent box marking the cargo bay zone.
@export var debug_show_cargo_bay: bool = true:
	set(v):
		debug_show_cargo_bay = v
		_rebuild_deferred()

# --- Audio SFX — all OPTIONAL: an unassigned sound simply plays nothing -------
# Drop an audio file straight into a Sound slot; each sound then has its own volume, fade-out curve
# and audible radius. Sounds are positional (AudioStreamPlayer3D) and fire on the CLIENTS: the door
# state and the pilot are already replicated by the server, so everyone around hears them at the right
# place. More sounds (engine loop, brakes…) will be added here, one subgroup each.
#
# The four knobs of every sound (see Sfx3D):
#   Sound     — the audio file.
#   Volume    — its loudness in dB, at the Falloff distance.
#   Falloff   — reference distance (m): past it the sound starts really fading, per Attenuation.
#   Distance  — hard cut-off (m): further away the sound is not computed at all (CPU saver).
#   Attenuation — HOW it fades with distance (see the enum below).

@export_group("Audio SFX")
@export_subgroup("Door open")
## Played at the door, when it opens.
@export var sfx_door_open: AudioStream
## Loudness in decibels (0 = the sample's own level, negative = quieter).
@export_range(-40.0, 12.0, 0.5) var sfx_door_open_db: float = 0.0
## Reference distance (m) at which the sound has its nominal volume; past it, it starts fading.
@export_range(0.5, 200.0, 0.5) var sfx_door_open_falloff: float = 5.0
## Distance (m) past which this sound is no longer audible at all (hard cut-off).
@export_range(1.0, 500.0, 1.0) var sfx_door_open_distance: float = 40.0
## How the sound fades with distance.
@export var sfx_door_open_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Door close")
## Played at the door, when it closes.
@export var sfx_door_close: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_door_close_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_door_close_falloff: float = 5.0
@export_range(1.0, 500.0, 1.0) var sfx_door_close_distance: float = 40.0
@export var sfx_door_close_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Engine start")
## Played when a driver takes the wheel (engine cranking / start-up).
@export var sfx_engine_start: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_engine_start_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_engine_start_falloff: float = 10.0
@export_range(1.0, 500.0, 1.0) var sfx_engine_start_distance: float = 60.0
@export var sfx_engine_start_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.REALISTIC

@export_subgroup("Engine stop")
## Played when the driver cuts the engine (key I again).
@export var sfx_engine_stop: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_engine_stop_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_engine_stop_falloff: float = 10.0
@export_range(1.0, 500.0, 1.0) var sfx_engine_stop_distance: float = 60.0
@export var sfx_engine_stop_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.REALISTIC

@export_subgroup("Lights on")
## Played when the head lights are switched on (key L).
@export var sfx_lights_on: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_lights_on_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_lights_on_falloff: float = 4.0
@export_range(1.0, 500.0, 1.0) var sfx_lights_on_distance: float = 25.0
@export var sfx_lights_on_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Lights off")
## Played when the head lights are switched off.
@export var sfx_lights_off: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_lights_off_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_lights_off_falloff: float = 4.0
@export_range(1.0, 500.0, 1.0) var sfx_lights_off_distance: float = 25.0
@export var sfx_lights_off_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Handbrake on")
## Played when the hand brake is pulled (hold Space at low speed).
@export var sfx_handbrake_on: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_handbrake_on_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_handbrake_on_falloff: float = 5.0
@export_range(1.0, 500.0, 1.0) var sfx_handbrake_on_distance: float = 30.0
@export var sfx_handbrake_on_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Handbrake off")
## Played when the hand brake is released — by the key, or automatically when the driver accelerates.
@export var sfx_handbrake_off: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_handbrake_off_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_handbrake_off_falloff: float = 5.0
@export_range(1.0, 500.0, 1.0) var sfx_handbrake_off_distance: float = 30.0
@export var sfx_handbrake_off_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Engine running")
## Engine note: ONE looped sample, played for as long as the engine runs. Record it at IDLE — the
## revving is made from it by raising its pitch (and its volume) with the engine RPM, so a single
## sample covers idle → full throttle. See _update_engine_sound.
@export var sfx_engine_idle: AudioStream
## Loudness at idle.
@export_range(-40.0, 12.0, 0.5) var sfx_engine_idle_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_engine_idle_falloff: float = 8.0
@export_range(1.0, 500.0, 1.0) var sfx_engine_idle_distance: float = 50.0
@export var sfx_engine_idle_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.REALISTIC
## Playback speed of the sample at the red line: 2 = an octave up. This IS the revving effect — the
## higher, the more the engine "screams" at speed. 1 = no pitch change at all.
@export_range(1.0, 3.0, 0.05) var sfx_engine_rev_pitch: float = 2.0
## Extra loudness (dB) added on top of the idle volume at the red line — an engine under load is
## louder, not just higher-pitched. 0 = same volume everywhere.
@export_range(0.0, 24.0, 0.5) var sfx_engine_rev_db: float = 6.0
## How fast the note follows the RPM (per second). Low = lazy, heavy engine; high = instant, nervous.
@export_range(0.5, 20.0, 0.5) var sfx_engine_rev_response: float = 5.0

@export_subgroup("Horn")
## Normal horn (key H): HELD — it blows for as long as the key is down (looped automatically).
@export var sfx_horn: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_horn_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_horn_falloff: float = 40.0
@export_range(1.0, 500.0, 1.0) var sfx_horn_distance: float = 150.0
@export var sfx_horn_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.FAR_REACHING
## Shortest honk (s): a quick tap still blows for this long, instead of being cut mid-sample. Holding
## the key simply keeps it going — one sample covers both.
@export_range(0.0, 2.0, 0.05) var sfx_horn_min_secs: float = 0.25
## Fade-out (s) when the horn is released: cutting a tone dead makes an audible click.
@export_range(0.0, 1.0, 0.01) var sfx_horn_fade_secs: float = 0.06

@export_subgroup("Horn (special)")
## Special horn — air horn, siren… (key Alt+H): ONE SHOT, the sample plays once in full, no loop.
@export var sfx_horn_special: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_horn_special_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_horn_special_falloff: float = 60.0
@export_range(1.0, 500.0, 1.0) var sfx_horn_special_distance: float = 250.0
@export var sfx_horn_special_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.FAR_REACHING

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
var _view: ViewMode = ViewMode.CAB  # bench (F6) enters in first-person cab view, like in-game (F5); F4 toggles to chase
var _empty_mass: float = 0.0
var _occupant_mass: float = 0.0  # kg of seated players (driver + passengers), added to the mass
var _locked_cargo: Dictionary = {}  # RigidBody3D cargo -> its mass (kg), summed into the load
var _locked_cargo_local: Dictionary = {}  # RigidBody3D cargo -> its rest LOCAL transform in the bed
var _bed_players: Dictionary = {}  # set of on-foot players standing in the bed (player -> true)
var _cargo_area: Area3D = null
var _bay_scan_tick: int = 0  # throttles _scan_bay_for_settled_cargo (see BAY_SCAN_FRAMES)
var _cargo_debug: bool = false  # Settings > General: draw a green envelope on really-locked cargo
var _cargo_debug_accum: float = 0.0  # throttle the debug refresh (dev aid, off by default)
var _cargo_debug_markers: Dictionary = {}  # RigidBody3D cargo -> its MeshInstance3D envelope
var _net_last_position: Vector3 = Vector3.ZERO
var _net_last_rotation: Vector3 = Vector3.ZERO
## SERVER: last replicated parent uuid, change detection. Replicated positions are PARENT-LOCAL, so
## the receiver must know which frame they are in — see _replicate_transform.
var _net_last_parent_id: String = ""
## Consecutive server ticks the pilotless vehicle has been quasi-still — after
## 30 (0.5 s) the body is put to sleep to stop suspension micro-jitter.
var _idle_still_ticks: int = 0
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
## The real "up" for this vehicle: opposite the gravity acting on it (radial on a planet, world-up on
## the bench). Read from state.total_gravity in _integrate_forces; the rollover check + reset_upright
## measure tilt against THIS, not world Y. Defaults to world up until the first physics step.
var _gravity_up: Vector3 = Vector3.UP
var _handbrake: bool = true  # server: hand brake engaged — vehicles SPAWN parked (released on throttle)
var _net_handbrake: bool = false  # client: replicated hand brake state (for the HUD)
var _net_last_handbrake: bool = false  # server: last replicated hand brake, change detection
var _headlights_on: bool = false  # server: head lights on/off
var _net_last_headlights: bool = false  # server: last replicated head lights, change detection
var _net_last_steering: float = 0.0  # server: last replicated front-wheel steer angle (rad)
var _interp := NetInterpolator.new()  # client-side smoothing of the replica
var _hud: VehicleDebugHud = null  # driver HUD (pilot client only)
var _powertrain := VehiclePowertrain.new()
# Real-model parts (all optional). Empty / null when the vehicle uses the procedural blockout.
var _real_wheel_meshes: Array[Node3D] = []  # GLB wheel meshes reparented under VehicleWheel3D (runtime)
var _real_wheel_rest: Dictionary = {}       # mesh -> [parent, local transform], to restore before rebuild
var _steering_wheel: Node3D = null          # GLB "steering_wheel" mesh that turns with the steer angle
var _steering_wheel_rest: Basis = Basis.IDENTITY  # its closed/centered orientation
var _anim: AnimationPlayer = null           # the GLB's AnimationPlayer (door open/close clips)
var _engine_on: bool = false                # engine running (server state; mirrored on each replica)
var _net_last_engine: bool = false          # server: last replicated engine state, change detection
## Client: false until _ready is done. Replicated state that lands BEFORE that is the spawn snapshot
## (the truck's current state, which we are only now hearing about) and must be applied SILENTLY;
## anything after it is a real change and gets its sound. Late-join guard for engine + hand brake.
var _spawned: bool = false
var _horn_on: bool = false                  # server: normal horn key held by the driver
var _net_last_horn: bool = false            # server: last replicated horn state, change detection
var _horn_special_count: int = 0            # server: number of special-horn (Alt) shots fired so far
var _net_last_horn_special: int = 0         # server: last replicated shot count, change detection
var _net_horn_special_count: int = -1       # client: last shot count seen (-1 = none received yet)
var _horn_player: AudioStreamPlayer3D = null  # client: the looping horn sound while it blows
var _idle_player: AudioStreamPlayer3D = null  # client: the looping engine-idle sound
var _idle_sfx_on: bool = false              # client: is the engine sound currently running?
var _rev: float = 0.0                       # client: smoothed rev ratio, 0 = idle, 1 = red line
var _engine_sound_wait: float = 0.0         # client: seconds left of the start-up sample (loop waits)
var _horn_held_secs: float = 0.0            # client: how long the current honk has been sounding
var _horn_fade_left: float = 0.0            # client: seconds left of the horn's fade-out (0 = not fading)
var _door_state: Dictionary = {}            # SERVER: door_id (String) -> open (bool)
var _net_last_doors: Dictionary = {}        # SERVER: last replicated door state, change detection
var _net_doors: Dictionary = {}             # CLIENT: replicated door state
var _net_last_seats: Dictionary = {}        # SERVER: last replicated seat occupancy, change detection
var _net_seats: Dictionary = {}             # CLIENT: seat name -> occupant uuid ("" = free), for prompts

func _ready() -> void:
	_empty_mass = mass
	_rebuild()
	if Engine.is_editor_hint():
		return
	add_to_group("vehicle")  # so a pilot can find and enter us
	_setup_loading_zone()  # designer "can load here" box: turn off its physics, keep it as a marker
	if not OS.has_feature("dedicated_server"):
		_cargo_debug = SettingsManager.is_cargo_debug()  # dev aid: green envelope on locked cargo
		SettingsManager.cargo_debug_changed.connect(_on_cargo_debug_changed)
	_sync_powertrain()
	set_headlights(_headlights_on)  # start in a known state (off) on the server and every client
	# Real-model drop-ins (no-op when the vehicle uses the blockout): reparent the GLB wheel meshes
	# under the physics wheels, find the steering wheel + the GLB AnimationPlayer, and start closed.
	_attach_real_wheel_meshes()
	_discover_steering_wheel()
	_anim = _find_anim_player()
	_attach_door_handles()  # make each handle ride its door so look-at works open OR closed
	_apply_center_of_mass()  # pin COM to the wheelbase, so collision shapes can't make the truck nose-dive
	# Late-join replay: a client replica receives the current door state into _net_doors via
	# client_channel_data_update BEFORE this node is in the tree — where _apply_door can't find the
	# model yet and no-ops. Now that the model + AnimationPlayer are ready, replay it so a player who
	# joins after a door was opened sees it open. (The code-swing fallback snaps instantly; a Blender
	# clip plays its open animation once.)
	if _is_networked() and not GameOrchestrator.is_server():
		for door_id in _net_doors:
			_apply_door(str(door_id), bool(_net_doors[door_id]), false)  # no sfx: nobody just opened it
	if _is_networked():
		# Replicated prop: place it where the server spawned it (client_channel_data_update
		# also applies position/rotation, this is the initial fallback).
		if spawn_position != Vector3.ZERO:
			position = spawn_position
		if spawn_rotation != Vector3.ZERO:
			rotation = spawn_rotation
	_spawned = true  # from now on, replicated engine / hand brake changes are real events → they sound

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
		# Ignition + horns, same keys as in game (in game they travel player -> server; here we are
		# the authority ourselves). Without this the bench truck could not even be started.
		if event.is_action_pressed("vehicle_ignition"):
			toggle_engine()
		if event.is_action_pressed("vehicle_horn_special", false, true):
			set_horn(true, true)
		elif event.is_action_pressed("vehicle_horn", false, true):
			set_horn(true)
		elif event.is_action_released("vehicle_horn") or event.is_action_released("vehicle_horn_special"):
			set_horn(false)

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
	_detach_real_wheel_meshes()  # runtime: restore GLB wheel meshes to the model BEFORE freeing their wheels
	for child in get_children():
		if child.has_meta(GENERATED):
			remove_child(child)
			child.free()
	_wheels.clear()
	_cargo_area = null
	_cab_cam = null
	_build_collision()
	if not _has_real_model():
		_build_body_visual()  # procedural blockout only when there is no real GLB model
	_build_wheels()
	_build_cargo_area()
	_build_cameras()

# ------------------------------------------------------------------------------
# Build helpers
# ------------------------------------------------------------------------------
func _build_collision() -> void:
	# Best: collision authored in the model (meshes named "col_*") — it matches the real shape exactly.
	# If the model ships any, use them and skip the parametric boxes entirely.
	if _build_model_collision():
		return
	# Otherwise (blockout, or a model with no col_ meshes yet) build the parametric boxes. A real GLB is
	# placed wherever it visually fits — usually offset from the vehicle origin (and so are the wheels,
	# which come from the model). The generated collision must sit UNDER the model, not at the origin, or
	# it overhangs the body and you bump an invisible wall. So follow the model's own local placement;
	# the blockout stays at origin (base = 0). Box DIMENSIONS come from the Body / Cab / Bed exports.
	var base: Vector3 = _collision_base_offset()
	var top: float = body_height * 0.5
	# Chassis box.
	_add_collision_box(Vector3(body_width, body_height, body_length), base)
	# Bed floor + 4 walls, so cargo rests inside the bed instead of falling through the
	# (collision-less) visual. These add to the VehicleBody3D compound collider.
	var bed_len: float = body_length - cab_length
	var bed_z: float = (body_length - bed_len) * 0.5
	var wall: float = BED_WALL_THICKNESS
	_add_collision_box(Vector3(body_width, wall, bed_len), base + Vector3(0.0, top + wall * 0.5, bed_z))
	_add_collision_box(Vector3(wall, bed_wall_height, bed_len),
		base + Vector3(body_width * 0.5 - wall * 0.5, top + bed_wall_height * 0.5, bed_z))
	_add_collision_box(Vector3(wall, bed_wall_height, bed_len),
		base + Vector3(-(body_width * 0.5 - wall * 0.5), top + bed_wall_height * 0.5, bed_z))
	_add_collision_box(Vector3(body_width, bed_wall_height, wall),
		base + Vector3(0.0, top + bed_wall_height * 0.5, bed_z - bed_len * 0.5 + wall * 0.5))
	_add_collision_box(Vector3(body_width, bed_wall_height, wall),
		base + Vector3(0.0, top + bed_wall_height * 0.5, bed_z + bed_len * 0.5 - wall * 0.5))

## Local offset the generated collision is built around: the real model's own placement (so the
## collision sits under the visible body + wheels), or zero for the procedural blockout.
func _collision_base_offset() -> Vector3:
	var mr := _find_model_root()
	if mr is Node3D:
		return (mr as Node3D).position
	return Vector3.ZERO

## Pin the center of mass instead of letting the RigidBody auto-derive it from the collision shapes.
## Auto-COM follows the col_ volumes (a big cab box pulls it forward → the truck nose-dives); we want
## it balanced on the wheels regardless of how the collision was modeled. Default = the wheelbase
## centre (average wheel position) + center_of_mass_offset. Only the COLLISION shapes ever affect
## inertia/COM in Godot — the visual meshes never do — so this fully decouples handling from the body
## art. Run after the wheels exist (they come from _rebuild).
func _apply_center_of_mass() -> void:
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	var com := center_of_mass_offset
	if not _wheels.is_empty():
		var sum := Vector3.ZERO
		for w in _wheels:
			sum += (w as Node3D).position
		com = sum / float(_wheels.size()) + center_of_mass_offset
	center_of_mass = com

## Build collision from "col_*" meshes authored in the GLB (the artist shapes the volumes in Blender).
## Each becomes ONE convex shape — a moving VehicleBody3D needs convex, so a hollow bed is made of
## several convex pieces (col_bed_floor, col_bed_left, col_cab…), not one concave mesh (a single mesh's
## convex hull would fill the bed). Each piece is placed at its spot in the model and hidden in game
## (collision-only). Returns true if at least one was found → the parametric boxes are skipped.
func _build_model_collision() -> bool:
	var root := _find_model_root()
	if root == null:
		return false
	var found := false
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not _strip_lod(mi.name).begins_with("col_"):
			continue
		var col := CollisionShape3D.new()
		col.set_meta(GENERATED, true)
		col.shape = mi.mesh.create_convex_shape()
		col.transform = global_transform.affine_inverse() * mi.global_transform
		add_child(col)
		mi.visible = false  # collision-only mesh: never rendered (hidden in the editor AND in game)
		found = true
	return found

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
	area.add_to_group("vehicle_cargo")
	# PASSIVE zone (same rule as the seats): the bed never MONITORS. It is MONITORABLE-only, on the
	# dedicated vehicle-zone layer, so the player's AreaDetector reports when a walker steps in (for
	# the load weight) and crates are locked at DROP time instead of polled every frame. The zone
	# layer is off the interact ray's mask (layer 1) so it never eats the carry aim.
	area.collision_layer = Globals.VEHICLE_ZONE_LAYER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
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

## First-person cab camera (the driver's eye). It sits on the driver seat's SitPoint — the same
## "eye point" convention F5 uses — so it follows the real model (not the blockout). Falls back to
## a blockout-derived spot if there is no driver seat. Inactive until you drive in cab view.
func _build_cameras() -> void:
	_cab_cam = Camera3D.new()
	_cab_cam.set_meta(GENERATED, true)
	add_child(_cab_cam)
	var seat := _driver_seat()
	if seat != null:
		# Eye = the driver SitPoint (Marker3D), in the vehicle's local space (seat is a direct child).
		var marker: Node3D = seat.sit_point
		if marker == null:
			marker = seat.get_node_or_null("SitPoint") as Node3D
		if marker != null:
			_cab_cam.transform = seat.transform * marker.transform
		else:
			_cab_cam.transform = seat.transform
	else:
		_cab_cam.position = Vector3(
			-body_width * 0.25,
			body_height * 0.5 + cab_height * 0.6,
			-(body_length * 0.5 - cab_length * 0.45))

## The driver seat (a VehicleSeat child with role DRIVER), or null.
func _driver_seat() -> VehicleSeat:
	for c in get_children():
		if c is VehicleSeat and (c as VehicleSeat).is_driver_seat():
			return c
	return null

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
	var up := _gravity_up  # the vehicle's real vertical (radial on a planet, world-up on the bench)
	# Only flip a genuinely tipped-over vehicle (more than ~60° from upright). If it is already
	# roughly upright, do nothing — otherwise spamming R keeps lifting it (+1 m each call) and
	# the truck flies away.
	if global_transform.basis.y.dot(up) > 0.5:
		return
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

## Load a crate the player just dropped while standing in this bed. Replaces the old per-frame
## bay polling: the bed no longer monitors, so the carrier (the single monitor that knows it is in
## the bed) hands the crate straight to the truck. Server-authoritative; ignores non-cargo bodies.
func lock_dropped_cargo(body: Node) -> void:
	if body == null or body is Vehicle or _locked_cargo.has(body):
		return
	if body is RigidBody3D and body.mass > 0.0:
		_lock_cargo(body)

## Catch a carriable that FELL, bounced or was thrown into the bed (the carry-drop path only locks an
## item released BY HAND inside the zone). Every few frames, ask the PHYSICS ENGINE which prop bodies
## overlap the loading zone — by collision MASK (the prop layer), so it returns exactly the crates/rocks
## inside it, no world-wide group scan — and lock those that have come to REST. Same zone box as the
## hand-drop (the designer Cargo_loading_zone, else the cargo bay); throttled, it only rescues free-fall.
func _scan_bay_for_settled_cargo() -> void:
	_bay_scan_tick += 1
	if _bay_scan_tick < BAY_SCAN_FRAMES:
		return
	_bay_scan_tick = 0
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var q := PhysicsShapeQueryParameters3D.new()
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.collision_mask = 1 << (Globals.LAYER_PROP - 1)  # props only (crates/rocks live on LAYER_PROP)
	if cargo_loading_zone != null and cargo_loading_zone.shape is BoxShape3D:
		q.shape = cargo_loading_zone.shape
		q.transform = cargo_loading_zone.global_transform
	else:
		var box := BoxShape3D.new()
		box.size = cargo_bay_size
		q.shape = box
		q.transform = global_transform.translated_local(cargo_bay_offset)
	for hit in space.intersect_shape(q, 16):
		var body = hit.get("collider")
		if not (body is RigidBody3D) or _locked_cargo.has(body):
			continue
		var rb := body as RigidBody3D
		if rb.mass <= 0.0 or rb.get_parent() is Player:
			continue  # carried items ride under a Player — not free cargo, don't absorb them
		if rb.linear_velocity.length() <= cargo_settle_speed:
			lock_dropped_cargo(rb)  # settled inside the bay → weigh it in

## Resolve the designer loading zone (explicit @export, else a child named "Cargo_loading_zone") and
## turn OFF its physics collision: a CollisionShape3D under this VehicleBody3D would otherwise be a
## real (huge) collider. We only read its box to test where loading is allowed.
func _setup_loading_zone() -> void:
	if cargo_loading_zone == null:
		cargo_loading_zone = get_node_or_null("Cargo_loading_zone") as CollisionShape3D
	if cargo_loading_zone != null:
		cargo_loading_zone.disabled = true

## True when a world point is inside the loading zone (where a dropped item is allowed to stick).
## Uses the designer's Cargo_loading_zone box if set, else falls back to the cargo_bay box (blockout).
func is_point_in_loading_zone(world_point: Vector3) -> bool:
	if cargo_loading_zone != null and cargo_loading_zone.shape is BoxShape3D:
		var local := cargo_loading_zone.global_transform.affine_inverse() * world_point
		var half: Vector3 = (cargo_loading_zone.shape as BoxShape3D).size * 0.5
		return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z
	var bay := to_local(world_point) - cargo_bay_offset
	return absf(bay.x) <= cargo_bay_size.x * 0.5 \
		and absf(bay.y) <= cargo_bay_size.y * 0.5 \
		and absf(bay.z) <= cargo_bay_size.z * 0.5

## A player walked into the bed on foot: count them in the load (and let them ride). Seated players
## are handled by _occupant_mass, so they are skipped in get_bed_mass — no double-count.
func add_bed_player(player: Node) -> void:
	if player == null or _bed_players.has(player):
		return
	_bed_players[player] = true
	_refresh_mass()

## A player left the bed (walked out, or sat down / was removed): drop them from the bed load.
func remove_bed_player(player: Node) -> void:
	if not _bed_players.has(player):
		return
	_bed_players.erase(player)
	_refresh_mass()

## Live weight (kg) of the on-foot players standing in the bed. Computed each call so a player who
## sat down (now in _occupant_mass) or vanished is skipped without needing an exit event.
func get_bed_mass() -> float:
	var total := 0.0
	for player in _bed_players:
		if is_instance_valid(player) and player._seat_vehicle_uuid == "":
			total += _player_mass(player) + _carried_mass(player)  # the walker AND what they hold
	return total

## Mass (kg) of the prop a bed walker carries in their hands (a carriable with a real mass, e.g. a
## mining rock), so a porter standing in the bed adds their load too. 0 when hands are empty.
func _carried_mass(player: Node) -> float:
	if not ("hands_item" in player):
		return 0.0
	var item = player.hands_item
	if is_instance_valid(item) and item is RigidBody3D:
		return maxf(0.0, (item as RigidBody3D).mass)
	return 0.0

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
	# sets server_reparenting). A raw reparent() made the prop vanish in-game (its _exit_tree
	# deleted it from Horizon).
	if body.has_method("server_parent_change"):
		body.server_parent_change(self)
	else:
		body.reparent(self)
	# Rest it on the bed floor: it was frozen at hand height, so without this it would hang in the
	# air. Keep its X/Z, lower it until its underside sits on the floor, THEN replicate that pose.
	_settle_on_bed_floor(body)
	_locked_cargo_local[body] = body.transform  # rest pose, re-asserted each frame so it rides rigidly
	if body.has_method("send_properties_to_client"):
		body.send_properties_to_client(str(uuid))
	_refresh_mass()

## Place a just-locked body INTO the cargo bay: shift its X/Z so its WHOLE footprint fits inside the
## cargo_bay (an item dropped from far / over the rim ends up entirely in the bay, not poking out),
## then rest its lowest collision point on the bed floor. Uses the real collision AABB, so it works
## for any pivot (a cut ore piece keeps the original rock's off-centre pivot) and any size.
func _settle_on_bed_floor(body: Node3D) -> void:
	var col := body as CollisionObject3D
	if col == null:
		return
	var bounds := _collision_aabb(body, global_transform.affine_inverse() * col.global_transform)
	if bounds.size == Vector3.ZERO:
		return  # no collision shape found: leave it where it is
	var mn := bounds.position
	var mx := bounds.end
	var local := to_local(body.global_position)
	# Fit the whole item inside the cargo bay footprint (centred if it is wider than the bay).
	local.x += _fit_shift(mn.x, mx.x, cargo_bay_offset.x - cargo_bay_size.x * 0.5, cargo_bay_offset.x + cargo_bay_size.x * 0.5)
	local.z += _fit_shift(mn.z, mx.z, cargo_bay_offset.z - cargo_bay_size.z * 0.5, cargo_bay_offset.z + cargo_bay_size.z * 0.5)
	local.y += _bed_floor_local_y() - mn.y  # rest the underside on the floor
	body.global_position = to_global(local)

## Translation along one axis so the span [item_min, item_max] fits inside [bay_min, bay_max]
## (centred when the item is wider than the bay).
static func _fit_shift(item_min: float, item_max: float, bay_min: float, bay_max: float) -> float:
	if item_max - item_min >= bay_max - bay_min:
		return (bay_min + bay_max) * 0.5 - (item_min + item_max) * 0.5
	if item_min < bay_min:
		return bay_min - item_min
	if item_max > bay_max:
		return bay_max - item_max
	return 0.0

## Local Y of the bed floor's top surface (where cargo rests), matching the generated floor box.
func _bed_floor_local_y() -> float:
	return body_height * 0.5 + BED_WALL_THICKNESS

## AABB of a body's OWN collision shapes, expressed in `frame_from_body`: pass IDENTITY for
## body-local, or this vehicle's (global⁻¹ × body.global) for vehicle-local. The maths lives in
## Globals (the carry placement needs the same footprint); this stays as the vehicle-side name.
func _collision_aabb(body: Node3D, frame_from_body: Transform3D) -> AABB:
	return Globals.collision_aabb(body, frame_from_body)

# ------------------------------------------------------------------------------
# Cargo debug envelope (Settings > General > Cargo debug). Dev aid only, off by default.
# ------------------------------------------------------------------------------
## React live to the Settings toggle: draw or clear the green envelopes without a restart.
func _on_cargo_debug_changed(on: bool) -> void:
	_cargo_debug = on
	if on:
		_refresh_cargo_debug()
	else:
		for body in _cargo_debug_markers.keys():
			if is_instance_valid(_cargo_debug_markers[body]):
				_cargo_debug_markers[body].queue_free()
		_cargo_debug_markers.clear()

## Keep one green envelope per REALLY-locked cargo. A locked crate is reparented under the vehicle
## (server and client), so the body's direct RigidBody3D children ARE the stuck cargo — an item just
## resting loose in the bed stays a child of the world, so it gets no envelope (that is the point).
func _refresh_cargo_debug() -> void:
	var stuck := {}
	for child in get_children():
		if child is RigidBody3D:
			stuck[child] = true
			if not _cargo_debug_markers.has(child):
				_cargo_debug_markers[child] = _make_cargo_marker(child)
	for body in _cargo_debug_markers.keys():
		if not stuck.has(body) or not is_instance_valid(body):
			if is_instance_valid(_cargo_debug_markers[body]):
				_cargo_debug_markers[body].queue_free()
			_cargo_debug_markers.erase(body)

## Build a translucent green box matching the body's collision bounds, parented to it so it rides.
func _make_cargo_marker(body: Node3D) -> MeshInstance3D:
	var bounds := _body_local_aabb(body)
	var marker := MeshInstance3D.new()
	marker.set_meta(GENERATED, true)
	var box := BoxMesh.new()
	box.size = bounds.size + Vector3.ONE * 0.05  # a hair bigger so it reads as a wrap, not z-fight
	marker.mesh = box
	marker.position = bounds.get_center()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 1.0, 0.0, 0.25)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	marker.material_override = mat
	body.add_child(marker)
	return marker

## A body's collision AABB in its OWN local frame (for the debug envelope mesh).
func _body_local_aabb(body: Node3D) -> AABB:
	return _collision_aabb(body, Transform3D.IDENTITY)

## Release a crate from the bed back into the world / a player's hands (carry retrieval): stop
## ignoring it and drop it from the load. The caller (the carry pickup) then takes ownership.
func release_cargo(body: Node) -> void:
	if not _locked_cargo.has(body):
		return
	remove_collision_exception_with(body)
	_locked_cargo.erase(body)
	_locked_cargo_local.erase(body)
	_refresh_mass()

## Server: hold every locked crate at its rest LOCAL pose each physics frame, so it rides the truck
## rigidly (a KINEMATIC child can drift relative to a moving parent body). Keeps the replicated local
## position constant -> clients stay perfectly stuck. Skips a crate that vanished (freed elsewhere).
func _pin_locked_cargo() -> void:
	for body in _locked_cargo_local.keys():
		if is_instance_valid(body):
			(body as Node3D).transform = _locked_cargo_local[body]
		else:
			_locked_cargo_local.erase(body)

## Spill the whole load when the vehicle tips past cargo_unlock_tilt_deg (GDD: the bed lock
## releases on a rollover). Each piece becomes a free dynamic prop again, back in the world.
func _check_rollover_unlock() -> void:
	if _locked_cargo.is_empty() or cargo_unlock_tilt_deg <= 0.0:
		return
	# Tilt is measured against the vehicle's OWN gravity-up, not world Y (see _gravity_up): a truck
	# resting flat on a planet must read as fully upright (dot ~ 1), whatever its world orientation.
	if global_transform.basis.y.dot(_gravity_up) > cos(deg_to_rad(cargo_unlock_tilt_deg)):
		return  # still upright enough
	for body in _locked_cargo.keys():
		_spill_cargo(body)

## Drop one locked piece back into the world (un-freeze, reparent, replicate) — no new carrier.
func _spill_cargo(body: Node) -> void:
	release_cargo(body)  # remove from the load + stop ignoring it
	if body is RigidBody3D:
		(body as RigidBody3D).freeze = false
	if body.has_method("set_carried"):
		body.set_carried(false)
	var world: Node = get_parent()
	if body.has_method("server_parent_change"):
		body.server_parent_change(world)
		if body.has_method("send_properties_to_client"):
			body.send_properties_to_client(str(world.uuid) if "uuid" in world else "")
	elif body is Node3D:
		(body as Node3D).reparent(world)

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
	var total := _occupant_mass + get_bed_mass()
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
	set_handbrake(not _handbrake)

## Server: set the hand brake. Single write point, so its sound fires whichever way it moves — the
## key, or the automatic release when the driver accelerates (see _apply_drive). The state is already
## replicated, so each client plays the click on its side (see client_channel_data_update).
func set_handbrake(on: bool) -> void:
	if _handbrake == on:
		return
	_handbrake = on
	_play_handbrake_sfx(on)  # bench: honk here (a game server is muted; its clients play it)

## The hand brake click, pulled or released.
func _play_handbrake_sfx(on: bool) -> void:
	if on:
		_play_sfx(sfx_handbrake_on, sfx_handbrake_on_db, sfx_handbrake_on_falloff,
				sfx_handbrake_on_distance, sfx_handbrake_on_attenuation)
	else:
		_play_sfx(sfx_handbrake_off, sfx_handbrake_off_db, sfx_handbrake_off_falloff,
				sfx_handbrake_off_distance, sfx_handbrake_off_attenuation)

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
	var wall: float = BED_WALL_THICKNESS
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
	# The wheel NODE is the TOP suspension mount: VehicleWheel3D makes the wheel hang below it by
	# ~suspension_rest and places the visual automatically. Mount it near the chassis center, else
	# it spawns penetrating the ground -> the body is launched into the air.
	var real := _real_wheel_data()
	if real.is_empty():
		# Procedural blockout: 4 wheels from dimensions, with CSG tire visuals. Front = steering.
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
			_make_wheel(wheel_name, layout[wheel_name][0], bool(layout[wheel_name][1]), true)
		return
	# Real model: one physics wheel per GLB wheel mesh, placed at the mesh's local position, with NO
	# CSG tire (the GLB mesh is reparented under it at runtime by _attach_real_wheel_meshes).
	for w in real:
		_make_wheel(str(w["name"]), w["pos"], bool(w["is_front"]), false)

## Create one VehicleWheel3D (the shared per-wheel setup, DRY for both blockout and real wheels).
## with_csg_tire adds the procedural cylinder visual (blockout only). Returns the wheel.
func _make_wheel(wheel_name: String, pos: Vector3, is_front: bool, with_csg_tire: bool) -> VehicleWheel3D:
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
	if with_csg_tire:
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
	return wheel

func _solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat

# ------------------------------------------------------------------------------
# Real 3D model (Blender GLB) drop-ins — wheels, steering wheel, doors. All OPTIONAL:
# every function below no-ops when the vehicle uses the procedural blockout.
# ------------------------------------------------------------------------------
## True when a real model is plugged in (a child in group "vehicle_model", or wheel meshes named
## like a wheel). Switches the procedural blockout visual off in _rebuild().
func _has_real_model() -> bool:
	if _find_model_root() != null:
		return true
	return not _real_wheel_data().is_empty()

## The instanced GLB root (designer puts it in group "vehicle_model"), or null. Filtered to our own
## descendants so two vehicles never see each other's model.
func _find_model_root() -> Node:
	if not is_inside_tree():
		return null
	for n in get_tree().get_nodes_in_group(MODEL_GROUP):
		if n is Node3D and is_ancestor_of(n):
			return n
	return null

## Strip a trailing "_LODn" so part discovery is LOD-agnostic; returns the name lowercased.
func _strip_lod(node_name: String) -> String:
	var low := node_name.to_lower()
	var i := low.rfind("_lod")
	if i != -1 and low.length() >= i + 5 and low[i + 4].is_valid_int():
		return low.substr(0, i)
	return low

## Find wheel meshes in the model and classify each front (steering) or not. Returns an array of
## {name, node, pos (local to the vehicle), is_front}. Empty when there is no real model. Convention:
## a wheel node's name contains "wheel"; "front"/"_f" in the name = front axle, else the axle with
## the smallest local Z steers.
func _real_wheel_data() -> Array:
	var root := _find_model_root()
	if root == null:
		return []
	var found: Array = []
	var seen := {}  # stripped name -> true, so LOD siblings count once
	# 1) Preferred: nodes explicitly marked VehicleWheel3D in the model (common vehicle import
	# setup). They sit under the model so the physics ignores them — we re-create a direct-child
	# wheel at their place and reparent their visual mesh. The volant ("steering") is NOT a wheel.
	for n in root.find_children("*", "VehicleWheel3D", true, false):
		var b := _strip_lod(n.name)
		if "steering" in b or seen.has(b):
			continue
		seen[b] = true
		found.append(_wheel_entry(n, _first_mesh_child(n), b))
	# 2) Else: plain meshes named "*wheel*" (the "dumb model" convention).
	if found.is_empty():
		for n in root.find_children("*", "MeshInstance3D", true, false):
			var b := _strip_lod(n.name)
			if not ("wheel" in b) or ("steering" in b) or seen.has(b):
				continue
			seen[b] = true
			found.append(_wheel_entry(n, n, b))
	_classify_front(found)
	return found

## Build one wheel entry: anchor = the node giving the wheel POSITION, visual = the mesh to reparent
## under the physics wheel, base = the LOD-stripped lowercased name.
func _wheel_entry(anchor: Node, visual: Node, base: String) -> Dictionary:
	var pos: Vector3 = (global_transform.affine_inverse() * (anchor as Node3D).global_transform).origin
	var is_front := ("front" in base) or ("_f_" in base) or base.ends_with("_f") or base.begins_with("front")
	return {"name": String(anchor.name), "visual": visual, "pos": pos, "is_front": is_front}

## First MeshInstance3D child of a node (the visual of a VehicleWheel3D marker), or the node itself.
func _first_mesh_child(n: Node) -> Node3D:
	for c in n.get_children():
		if c is MeshInstance3D:
			return c
	return n as Node3D

## When no wheel is named front/rear, the axle nearest the cab (smallest local Z) is the steering one.
func _classify_front(found: Array) -> void:
	var any_front := false
	for w in found:
		if w["is_front"]:
			any_front = true
	if any_front or found.is_empty():
		return
	var min_z: float = INF
	for w in found:
		min_z = minf(min_z, (w["pos"] as Vector3).z)
	for w in found:
		w["is_front"] = absf((w["pos"] as Vector3).z - min_z) < 0.5

## The physics wheel whose local position is closest to pos (match a GLB mesh to its wheel).
func _wheel_at(pos: Vector3) -> VehicleWheel3D:
	var best: VehicleWheel3D = null
	var best_d: float = INF
	for wheel in _wheels:
		var d: float = wheel.position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = wheel
	return best

## Runtime: reparent each GLB wheel mesh under its physics wheel so it rides suspension/steer/spin.
## Records each mesh's original parent + transform so _detach can restore it before a rebuild.
func _attach_real_wheel_meshes() -> void:
	if Engine.is_editor_hint():
		return
	for w in _real_wheel_data():
		var mesh := w["visual"] as Node3D
		var wheel := _wheel_at(w["pos"])
		if mesh == null or wheel == null:
			continue
		_real_wheel_rest[mesh] = [mesh.get_parent(), mesh.transform]
		mesh.reparent(wheel)
		mesh.position = Vector3.ZERO  # the wheel node is the hub; the mesh sits on it
		_real_wheel_meshes.append(mesh)

## Runtime: put the GLB wheel meshes back under the model (saved transform) BEFORE a rebuild frees
## the physics wheels — otherwise the designer's meshes would be orphaned/freed by the sweep.
func _detach_real_wheel_meshes() -> void:
	if Engine.is_editor_hint():
		return
	for mesh in _real_wheel_meshes:
		if not is_instance_valid(mesh):
			continue
		var rest = _real_wheel_rest.get(mesh)
		if rest == null:
			continue
		var parent := rest[0] as Node
		if is_instance_valid(parent):
			mesh.reparent(parent)
			mesh.transform = rest[1]
	_real_wheel_meshes.clear()
	_real_wheel_rest.clear()

## Spin a wheel's visual child about its axle. The blockout CSG tire spins about local UP (it was
## rotated 90° about Z); a real GLB wheel spins about real_wheel_spin_axis. One helper for both.
func _spin_wheel_visual(wheel: VehicleWheel3D, angle: float) -> void:
	if wheel.get_child_count() == 0:
		return
	var visual: Node3D = wheel.get_child(0)
	var axis: Vector3 = Vector3.UP if visual is CSGCylinder3D else real_wheel_spin_axis.normalized()
	visual.rotate_object_local(axis, angle)

## Find the steering-wheel mesh in the model (name "steering_wheel") and capture its rest basis.
func _discover_steering_wheel() -> void:
	var root := _find_model_root()
	if root == null:
		return
	for n in root.find_children("*", "Node3D", true, false):
		if "steering" in _strip_lod(n.name):
			# Spin the visual mesh: a child mesh if "steering" is a VehicleWheel3D wrapper, else itself.
			_steering_wheel = _first_mesh_child(n) if (n is VehicleWheel3D) else (n as Node3D)
			_steering_wheel_rest = _steering_wheel.transform.basis
			return

## Turn the steering wheel mesh to match the steer angle (cosmetic). No-op if there is none.
## Rotates in the wheel's OWN LOCAL frame (post-multiply), so the axis is intrinsic to the mesh (its
## disc/column axis) and a tilted column still spins in-plane, whatever its placement in the cab.
## (transform.basis = … on a Node3D does nothing — transform returns a copy; copy-modify-assign.)
func _update_steering_wheel(angle: float) -> void:
	if _steering_wheel == null:
		return
	var t := _steering_wheel.transform
	t.basis = _steering_wheel_rest * Basis(steering_wheel_axis.normalized(), -angle * steering_wheel_ratio)
	_steering_wheel.transform = t

## The GLB's AnimationPlayer (door open/close clips), or null (then doors use the code tween).
func _find_anim_player() -> AnimationPlayer:
	var root := _find_model_root()
	if root == null:
		return null
	for n in root.find_children("*", "AnimationPlayer", true, false):
		return n as AnimationPlayer
	return null

## SERVER: flip a door's open state; _replicate_transform then pushes it to clients. A door handle
## is operated on foot by anyone nearby (not gated on the driver).
func server_toggle_door(door_id: String) -> void:
	if door_id == "":
		return
	_door_state[door_id] = not is_door_open(door_id)
	_apply_door(door_id, _door_state[door_id])

## The VehicleDoorHandle node driving `door_id` on THIS vehicle (or null). Used server-side to
## line-of-sight-check a door toggle against the handle's real position (it rides its door at runtime).
func get_door_handle(door_id: String) -> Node3D:
	for h in get_tree().get_nodes_in_group("vehicle_door_handle"):
		if h is Node3D and "door_id" in h and str(h.door_id) == door_id and h.has_method("vehicle") \
				and h.vehicle() == self:
			return h
	return null

## True if `player` currently occupies a seat of THIS vehicle (driver or passenger). Server-authoritative
## (reads seat occupancy, set by server_enter/server_exit) — used to tell whether a player operating a
## door handle is inside (seated) or outside (on foot).
func is_occupied_by(player: Node) -> bool:
	if _pilot == player:
		return true
	for c in get_children():
		if c is VehicleSeat and (c as VehicleSeat).occupant == player:
			return true
	return false

## A seat may be boarded/left only through an open door: true when the seat is gated by a door that is
## currently shut. A seat with no door_id is never blocked. Used by server_enter/server_exit (the
## client gates this too, but the server is the source of truth — never trust the client).
func _seat_door_blocked(seat: Node) -> bool:
	return "door_id" in seat and str(seat.door_id) != "" and not is_door_open(str(seat.door_id))

## True if the door is open — server reads _door_state, a client replica reads replicated _net_doors.
func is_door_open(door_id: String) -> bool:
	if _is_networked() and not GameOrchestrator.is_server():
		return bool(_net_doors.get(door_id, false))
	return bool(_door_state.get(door_id, false))

## The GLB mesh node of a door (the one Blender animates / we swing), found by name == door_id,
## LOD- and case-insensitive. Null without a real model or when no mesh matches.
func _door_mesh(door_id: String) -> Node3D:
	var root := _find_model_root()
	if root == null:
		return null
	var want := door_id.to_lower()
	for n in root.find_children("*", "Node3D", true, false):
		if _strip_lod(n.name).to_lower() == want:
			return n as Node3D
	return null

## Runtime: re-parent each door handle UNDER its door mesh, keeping its world placement, so the handle
## swings WITH the door (the GLB door rotates on open/close; a handle left on the body would stay at
## the shut position and the player's look-at ray would miss it once the door is open). No-op without a
## real model or when the matching door mesh is absent — the handle then just stays where it was placed.
func _attach_door_handles() -> void:
	for n in find_children("*", "VehicleDoorHandle", true, false):
		var handle := n as VehicleDoorHandle
		var door := _door_mesh(handle.door_id)
		if door != null and handle.get_parent() != door:
			handle.reparent(door, true)

## The VehicleDoorHandle that drives a given door_id (for its per-door open angle / reverse), or null.
func _door_handle(door_id: String) -> VehicleDoorHandle:
	# Search our own descendants (no get_tree(): this can run before the vehicle is in the tree,
	# and we only ever want THIS vehicle's handles anyway).
	for n in find_children("*", "VehicleDoorHandle", true, false):
		if (n as VehicleDoorHandle).door_id == door_id:
			return n
	return null

## Play a door open/close: a named Blender clip "<door_id>_open"/"_close" if the GLB has one, else a
## code hinge-swing fallback. Runs on the server (logical) and every client (visible swing). The
## per-door open angle / reverse come from the door's VehicleDoorHandle (falls back to the exports).
## `sfx` is false for the late-join replay (the door is set to its CURRENT state — nobody just opened it).
func _apply_door(door_id: String, open: bool, sfx: bool = true) -> void:
	if sfx:
		if open:
			_play_sfx(sfx_door_open, sfx_door_open_db, sfx_door_open_falloff, sfx_door_open_distance,
					sfx_door_open_attenuation, _door_mesh(door_id))
		else:
			_play_sfx(sfx_door_close, sfx_door_close_db, sfx_door_close_falloff, sfx_door_close_distance,
					sfx_door_close_attenuation, _door_mesh(door_id))
	var handle := _door_handle(door_id)
	var reverse: bool = handle.reverse if handle != null else false
	var clip := door_id + ("_open" if open else "_close")
	if _anim != null and _anim.has_animation(clip):
		if reverse:
			_anim.play_backwards(clip)
		else:
			_anim.play(clip)
		return
	var angle: float = handle.open_angle_deg if handle != null else door_open_angle_deg
	_snap_door(door_id, open, angle, reverse)

## Fallback for a door with no Blender clip: set the mesh named door_id to its open/closed hinge
## angle instantly (the proper swing is authored in Blender). transform.basis = … on a Node3D is a
## no-op (transform returns a copy), so copy-modify-assign.
func _snap_door(door_id: String, open: bool, angle_deg: float, reverse: bool) -> void:
	var door := _door_mesh(door_id)
	if door == null:
		return
	if not door.has_meta("rest_basis"):
		door.set_meta("rest_basis", door.transform.basis)
	var rest: Basis = door.get_meta("rest_basis")
	var target: Basis = rest
	if open:
		var a: float = -angle_deg if reverse else angle_deg
		target = rest.rotated(door_hinge_axis.normalized(), deg_to_rad(a))
	var t := door.transform
	t.basis = target
	door.transform = t

# ------------------------------------------------------------------------------
# Audio SFX
# ------------------------------------------------------------------------------
## Fire-and-forget positional sound with its own volume / falloff / cut-off / attenuation, played AT
## `at` (a door mesh, the cab…) or at the vehicle's origin when null. The player node frees itself once
## the sample is over, so nothing accumulates. No-op without a sound, in the editor, and on the
## authority (a game server has no audio: each client fires the sound from the replicated state).
func _play_sfx(stream: AudioStream, db: float, falloff: float, distance: float,
		attenuation: Sfx3D.Attenuation, at: Node3D = null) -> void:
	if _sfx_muted():
		return
	Sfx3D.play(at if at != null else self, stream, db, falloff, distance, attenuation)

## True where SFX must not be heard: editor tooling and the game server (the clients play the sounds).
func _sfx_muted() -> bool:
	if Engine.is_editor_hint() or OS.has_feature("dedicated_server"):
		return true
	return _is_networked() and GameOrchestrator.is_server()

## SERVER: the driver turns the ignition key (I). STARTING needs a near-standstill (below
## ignition_max_kmh); STOPPING is always allowed, at any speed — a kill switch (unwise while rolling
## IRL, but the driver can always cut it). The state is replicated, so every client hears the start-up
## + the idle, and a vehicle with a dead engine does not drive (see _physics_process).
func toggle_engine() -> void:
	if not _engine_on and absf(get_display_speed_kmh()) > ignition_max_kmh:
		return  # can't START above walking pace; stopping (the else) is unrestricted
	set_engine(not _engine_on)

## Engine on/off, on the server as well as on each replica (which gets it replicated). Switching it ON
## plays the start-up sound; the idle loop follows on its own (see _update_engine_idle).
func set_engine(on: bool) -> void:
	if _engine_on == on:
		return
	_engine_on = on
	if on:
		_play_sfx(sfx_engine_start, sfx_engine_start_db, sfx_engine_start_falloff,
				sfx_engine_start_distance, sfx_engine_start_attenuation)
		# Hold the engine loop back until the cranking sample is over, or it would start in the very
		# same frame and drown it — you would only ever hear the idle.
		_engine_sound_wait = sfx_engine_start.get_length() if sfx_engine_start != null else 0.0
	else:
		engine_force = 0.0  # cutting the engine stops powering the wheels at once
		_engine_sound_wait = 0.0  # cut mid-cranking: forget the pending loop
		_play_sfx(sfx_engine_stop, sfx_engine_stop_db, sfx_engine_stop_falloff,
				sfx_engine_stop_distance, sfx_engine_stop_attenuation)

## True while the engine runs (the dashboard / HUD can read it).
func is_engine_on() -> bool:
	return _engine_on

## The engine note. ONE looped sample (recorded at idle) covers the whole rev range: its pitch and its
## volume are pushed up with the engine RPM, which is exactly how a car engine reads to the ear. No
## replication needed — the engine state and the speed are already known here, and get_engine_rpm()
## works on a replica too (it is derived from the replicated speed). Called every frame.
func _update_engine_sound(delta: float) -> void:
	if _engine_sound_wait > 0.0:
		_engine_sound_wait -= delta  # cranking: the loop waits its turn (see set_engine)
	var running: bool = _engine_on and _engine_sound_wait <= 0.0
	if running != _idle_sfx_on:
		_idle_sfx_on = running
		_start_or_stop_engine_sound(running)
	if _idle_player == null or not _idle_player.playing:
		return
	# Chase the target rev ratio instead of jumping to it: the RPM comes from the (networked, snapped)
	# speed, so a raw follow would step and warble. This is the engine's "inertia".
	var target: float = _rev_ratio()
	_rev = move_toward(_rev, target, sfx_engine_rev_response * delta)
	_idle_player.pitch_scale = lerpf(1.0, sfx_engine_rev_pitch, _rev)
	_idle_player.volume_db = sfx_engine_idle_db + sfx_engine_rev_db * _rev

## Where the engine sits between idle (0.0) and the red line (1.0) right now. THERMAL revs between
## idle_rpm and redline_rpm within each gear (so the note falls back on every shift, like a real
## gearbox); ELECTRIC has no gears: the RPM just tracks the speed up to motor_max_rpm.
func _rev_ratio() -> float:
	var low: float = idle_rpm if propulsion_type == PropulsionType.THERMAL else 0.0
	var high: float = redline_rpm if propulsion_type == PropulsionType.THERMAL else motor_max_rpm
	return clampf((get_engine_rpm() - low) / maxf(high - low, 1.0), 0.0, 1.0)

## Create + start (or stop) the looping engine player. The node is kept between runs, not freed.
func _start_or_stop_engine_sound(on: bool) -> void:
	if not on:
		if _idle_player != null:
			_idle_player.stop()
		return
	if sfx_engine_idle == null or _sfx_muted():
		return
	if _idle_player == null:
		_idle_player = AudioStreamPlayer3D.new()
		add_child(_idle_player)
	Sfx3D.configure(_idle_player, Sfx3D.as_looping(sfx_engine_idle), sfx_engine_idle_db,
			sfx_engine_idle_falloff, sfx_engine_idle_distance, sfx_engine_idle_attenuation)
	_rev = 0.0  # a fresh start is always at idle: the note climbs from there
	_idle_player.pitch_scale = 1.0
	_idle_player.play()

## SERVER: the driver presses / releases a horn key. The two horns behave differently on purpose:
##   - normal (H): HELD — a replicated bool, so everyone around hears it for as long as it is held;
##   - special (Alt+H): ONE SHOT — the sample is played once, in full, on the press (the release does
##     nothing). It is replicated as a counter that ticks up on each press, because a "moment" cannot
##     be carried by an on/off state: a quick tap could be squashed into a single delta update and
##     never reach the clients.
## Only the pilot can honk (checked by the caller in player_server); a driver leaving the seat
## releases the held horn (see server_exit).
func set_horn(on: bool, special: bool = false) -> void:
	if special:
		if on:
			_horn_special_count += 1
			_play_special_horn()  # bench (no replication loop): honk here — muted on a game server
		return
	if _horn_on == on:
		return
	_horn_on = on
	_apply_horn(on)

## Start the looping horn. STOPPING is not done here: releasing the key only asks for it, and
## _update_horn takes care of the minimum honk + the fade-out. One player node is reused (kept).
func _apply_horn(on: bool) -> void:
	if not on:
		return  # _update_horn winds it down: hold it to sfx_horn_min_secs, then fade
	if sfx_horn == null or _sfx_muted():
		return
	if _horn_player == null:
		_horn_player = AudioStreamPlayer3D.new()
		add_child(_horn_player)
	Sfx3D.configure(_horn_player, Sfx3D.as_looping(sfx_horn), sfx_horn_db, sfx_horn_falloff,
			sfx_horn_distance, sfx_horn_attenuation)
	_horn_held_secs = 0.0
	_horn_fade_left = 0.0
	_horn_player.play()

## The tail of the held horn, every frame. A real horn is a continuous tone: a quick tap must not be
## chopped mid-sample (hence the minimum honk), and letting go must not cut it dead (hence the fade —
## an abrupt stop on a tone is heard as a click). Pressing again during the fade cancels it.
func _update_horn(delta: float) -> void:
	if _horn_player == null or not _horn_player.playing:
		return
	_horn_held_secs += delta
	if _horn_on:  # still (or again) pressed: full volume, forget any fade in progress
		if _horn_fade_left > 0.0:
			_horn_fade_left = 0.0
			_horn_player.volume_db = sfx_horn_db
		return
	if _horn_held_secs < sfx_horn_min_secs:
		return  # released, but the honk has not reached its minimum length yet — keep blowing
	var fade: float = maxf(sfx_horn_fade_secs, 0.001)
	if _horn_fade_left <= 0.0:
		_horn_fade_left = fade  # start winding down
	_horn_fade_left -= delta
	if _horn_fade_left <= 0.0:
		_horn_player.stop()
		_horn_player.volume_db = sfx_horn_db  # back to the nominal level for the next honk
		return
	_horn_player.volume_db = sfx_horn_db + HORN_FADE_DB * (1.0 - _horn_fade_left / fade)

## One shot of the special horn (air horn / siren): plays the sample once, to its end. Not looped —
## holding Alt+H does not extend it, and it is not cut when the key is released.
func _play_special_horn() -> void:
	_play_sfx(sfx_horn_special, sfx_horn_special_db, sfx_horn_special_falloff,
			sfx_horn_special_distance, sfx_horn_special_attenuation)

# ------------------------------------------------------------------------------
# Driving (runtime only)
# ------------------------------------------------------------------------------
## Client replica: physics is off (server-authoritative), so smoothly interpolate toward the
## latest replicated transform here every render frame — otherwise the truck, and any rider's
## camera glued to a seat, would step at the network rate. Then animate the wheels.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Sound upkeep — also on the bench (no network), hence before the replica guard below.
	_update_engine_sound(delta)
	_update_horn(delta)
	if not _is_networked() or GameOrchestrator.is_server():
		return
	# Smooth for everyone, driver included: the driver is parented to the vehicle, so the camera
	# rides the smoothly-interpolated body (no per-frame world jitter). Server stays authoritative.
	_interp.update(self, delta)
	_update_wheels_visual(delta)
	if _cargo_debug:
		_cargo_debug_accum += delta
		if _cargo_debug_accum >= 0.5:  # cheap periodic refresh; this only runs when the toggle is ON
			_cargo_debug_accum = 0.0
			_refresh_cargo_debug()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _is_networked():
		# Server-authoritative: only the game server simulates + replicates. The client replica
		# has physics off; its smoothing + wheels are done in _process.
		if not GameOrchestrator.is_server():
			return
		_release_vanished_occupants()  # free seats + bed slots whose player disconnected (node freed)
		_check_rollover_unlock()  # spill the load if the truck is tipped over
		_pin_locked_cargo()  # hold the load rigidly in the bed (constant local pose) as the truck moves
		_scan_bay_for_settled_cargo()  # lock a crate that FELL/bounced into the bay (carry-drop already locks)
		# Settle & sleep an idle vehicle. Wheel-suspension micro-forces on the
		# terrain trimesh otherwise keep the body awake forever, wandering by
		# millimetres every tick — replicated to every client as endless
		# "dancing". Once quasi-still with no pilot, put the body to sleep
		# explicitly and skip the drive/brake force application (any force
		# re-wakes it). A pilot entering, or a real collision, wakes it again.
		if not is_instance_valid(_pilot) \
				and linear_velocity.length_squared() < 0.01 \
				and angular_velocity.length_squared() < 0.01:
			_idle_still_ticks += 1
			# A full second quasi-still before freezing: the suspension needs
			# time to finish settling, or the pose is frozen with one side
			# still compressed (a wheel visually sunk into the ground).
			if _idle_still_ticks >= 60:
				if not sleeping:
					linear_velocity = Vector3.ZERO
					angular_velocity = Vector3.ZERO
					engine_force = 0.0
					sleeping = true
				_replicate_transform()  # still replicate doors/headlights/etc.
				return
		else:
			_idle_still_ticks = 0
			if sleeping and is_instance_valid(_pilot):
				sleeping = false  # pilot back on board: resume simulation
		# A driver is aboard: they steer and brake even with a DEAD ENGINE — only the propulsion is
		# gated on the engine (handled inside _apply_drive). Start the engine with the ignition key (I).
		if is_instance_valid(_pilot):
			_apply_drive(delta)
		elif _handbrake:
			_hold_handbrake(delta)  # parked: the hand brake stays on after the driver leaves
		else:
			_coast_no_driver()  # no driver: cut the drive (or it powers on forever) + bleed speed
		_replicate_transform()
		return
	# Bench / standalone: drive locally.
	_check_rollover_unlock()
	_pin_locked_cargo()
	_scan_bay_for_settled_cargo()
	if _pilot != null:
		_apply_drive(delta)
	elif _handbrake:
		_hold_handbrake(delta)
	else:
		_coast_no_driver()  # no driver: cut the drive (or it powers on forever) + bleed speed

## Server: replicate position/rotation to clients when they change (same shape as a rock).
## Client: the replica is frozen (no physics), so roll + steer the wheels visually from
## the replicated speed (position delta) and steer angle.
func _update_wheels_visual(delta: float) -> void:
	# Position delta measured in the PARENT's frame, never in world space: a parked truck on a
	# spinning planet sweeps through world space at surface speed, which would roll the wheels of a
	# stationary vehicle (and in bursts, since the planet transform only refreshes a few times a
	# second while this runs every frame).
	var vel: Vector3 = position - _wheel_last_pos
	_wheel_last_pos = position
	var fwd_speed: float = vel.dot(-transform.basis.z) / maxf(delta, 0.0001)
	var spin: float = fwd_speed / maxf(wheel_radius, 0.01) * delta
	for wheel in _wheels:
		if wheel.use_as_steering:
			wheel.rotation.y = _net_steering
		if wheel.get_child_count() > 0:
			wheel.get_child(0).position.y = -wheel_visual_drop  # replica has no suspension → drop to ~ground
			_spin_wheel_visual(wheel, -spin)
	_update_steering_wheel(_net_steering)  # turn the volant on the replica too (no-op if absent)

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

## SERVER: uuid of the node this vehicle's replicated (PARENT-LOCAL) position is expressed in.
##
## Unlike every other prop, a Vehicle replicates its transform here instead of through PropNet, and
## this payload never carried a parent_id — which is safe only as long as the receiver's idea of the
## parent matches ours. The origin rebase can break that tie: server.gd create_generic_object routes
## a spawn that arrives WITHOUT a parent into the owning planet's physics world, so `position`
## becomes planet-local while Horizon still has parent "" and would read those metres as universe
## coordinates (that exact mismatch teleported the player 3.3e10 m into deep space; see
## player_server._net_parent_uuid). Sending the parent alongside the position — on change, exactly
## like PropNet.server_tick does for every other prop — makes the frame explicit and self-heals a
## stale record, whichever parent the spawn actually arrived with.
func _net_parent_id() -> String:
	var parent: Node = get_parent()
	if parent != null and "uuid" in parent:
		return str(parent.uuid)
	return ""

func _replicate_transform() -> void:
	var my_pos: Vector3 = snapped(position, Vector3(0.005, 0.005, 0.005))
	var my_rot: Vector3 = snapped(rotation, Vector3(0.01, 0.01, 0.01))
	var my_parent_id: String = _net_parent_id()
	var my_speed: float = snappedf(linear_velocity.length() * 3.6, 0.1)
	var my_cargo: float = snappedf(get_cargo_mass(), 0.1)
	var my_mass: float = snappedf(mass, 0.1)  # total weight (empty + cargo + seated players)
	var my_steering: float = snappedf(steering, 0.01)
	var my_seats: Dictionary = _seat_occupancy_now()
	if my_pos == _net_last_position and my_rot == _net_last_rotation \
			and my_parent_id == _net_last_parent_id \
			and my_speed == _net_last_speed and my_cargo == _net_last_cargo_mass \
			and _handbrake == _net_last_handbrake and my_mass == _net_last_mass \
			and _headlights_on == _net_last_headlights and my_steering == _net_last_steering \
			and _horn_on == _net_last_horn and _horn_special_count == _net_last_horn_special \
			and _engine_on == _net_last_engine and _door_state == _net_last_doors \
			and my_seats == _net_last_seats:
		return
	var data: Dictionary = {}
	# The parent goes out WITH the position it qualifies, in the same payload — never in a message of
	# its own, so the receiver can never apply a local position in the previous frame.
	if my_parent_id != _net_last_parent_id:
		data["parent_id"] = my_parent_id
		data["position"] = my_pos
		_net_last_parent_id = my_parent_id
		_net_last_position = my_pos
	if my_pos != _net_last_position:
		data["position"] = my_pos
		_net_last_position = my_pos
	if my_rot != _net_last_rotation:
		data["rotation"] = my_rot
		_net_last_rotation = my_rot
	if my_speed != _net_last_speed:
		data["speed"] = my_speed
		_net_last_speed = my_speed
	if my_cargo != _net_last_cargo_mass:
		data["cargo_mass"] = my_cargo
		_net_last_cargo_mass = my_cargo
	if _handbrake != _net_last_handbrake:
		data["handbrake"] = _handbrake
		_net_last_handbrake = _handbrake
	if my_mass != _net_last_mass:
		data["mass"] = my_mass
		_net_last_mass = my_mass
	if _headlights_on != _net_last_headlights:
		data["headlights"] = _headlights_on
		_net_last_headlights = _headlights_on
	if my_steering != _net_last_steering:
		data["steering"] = my_steering
		_net_last_steering = my_steering
	if _horn_on != _net_last_horn:
		data["horn"] = _horn_on
		_net_last_horn = _horn_on
	if _horn_special_count != _net_last_horn_special:
		data["horn_special"] = _horn_special_count
		_net_last_horn_special = _horn_special_count
	if _engine_on != _net_last_engine:
		data["engine"] = _engine_on
		_net_last_engine = _engine_on
	if _door_state != _net_last_doors:
		data["doors"] = _door_state.duplicate()
		_net_last_doors = _door_state.duplicate()
	if my_seats != _net_last_seats:
		data["seats"] = my_seats.duplicate()
		_net_last_seats = my_seats.duplicate()

	emit_signal("hs_server_prop_update", uuid, data, type_name, has_parent)

## SERVER: current per-seat occupancy (seat name -> occupant uuid, "" when free). Replicated so ANY
## client can tell a seat is taken (driver AND passenger, one system — see PlayerClient._seat_is_taken).
func _seat_occupancy_now() -> Dictionary:
	var occ: Dictionary = {}
	for seat in _seats():
		occ[str(seat.name)] = seat.occupant_uuid
	return occ

## Server: tell the clients to despawn this vehicle when it leaves the world.
func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if _is_networked() and GameOrchestrator.is_server():
		emit_signal("hs_server_prop_delete", uuid, type_name)

## Client: apply the replicated state (position/rotation/pilot) from the server.
func client_channel_data_update(data: Dictionary) -> void:
	# The SERVER simulates this vehicle — never apply channel updates there.
	# Horizon routes our own prop broadcasts back to us: the first echo
	# snap-teleports the body (_interp.set_target snaps on first call) and
	# every echoed property write (mass, …) re-wakes the RigidBody, so it can
	# never sleep and micro-wanders forever (the vehicle half of the "dancing"
	# bug). Replica smoothing/HUD state below is for CLIENTS only.
	# NOTE for future multi-zone: a vehicle frozen by another zone's server
	# would also be skipped here — revisit ownership then.
	if _is_networked() and GameOrchestrator.is_server():
		return
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
		var hb := bool(data["handbrake"])
		if _spawned and hb != _net_handbrake:
			_play_handbrake_sfx(hb)  # click only on a real change (see _spawned: not on the snapshot)
		_net_handbrake = hb
	if data.has("headlights"):
		set_headlights(bool(data["headlights"]))  # mirror the head lights on this replica
	if data.has("engine"):
		# Mirror the ignition: start-up sound, then the engine loop. Before _ready this is the spawn
		# snapshot (a truck already running when we arrive must not crank up in our ears) → silent.
		if _spawned:
			set_engine(bool(data["engine"]))
		else:
			_engine_on = bool(data["engine"])
	if data.has("horn"):
		_horn_on = bool(data["horn"])
		_apply_horn(_horn_on)  # held horn: blow / stop it on this replica
	if data.has("horn_special"):
		# Shot counter (Godot sends ints as floats over the wire, hence the float→int cast). It went
		# up = the driver just hit Alt+H → fire one shot here. The FIRST value received is only
		# recorded: a player joining next to a truck that honked earlier must not hear a stale honk.
		var count := int(float(data["horn_special"]))
		if _net_horn_special_count >= 0 and count > _net_horn_special_count:
			_play_special_horn()
		_net_horn_special_count = count
	if data.has("pilot_uuid"):
		var new_pilot := str(data["pilot_uuid"])
		pilot_uuid = str(data["pilot_uuid"])
	if data.has("doors"):
		var new_doors: Dictionary = data["doors"]
		for door_id in new_doors:  # animate only the doors whose state actually changed
			if bool(new_doors[door_id]) != bool(_net_doors.get(door_id, false)):
				_apply_door(str(door_id), bool(new_doors[door_id]))
		_net_doors = new_doors
	if data.has("seats"):
		_net_seats = (data["seats"] as Dictionary).duplicate()  # for _seat_is_taken (prompt + entry gate)

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
	if seat == null or not seat.is_free() or _seat_door_blocked(seat):
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
	if seat == null or _seat_door_blocked(seat):
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
		# Clear the last drive input + stop powering NOW, so the empty truck can't keep driving on a
		# stale throttle (driver bailed "en marche") nor lurch when the next driver boards.
		_net_throttle = 0.0
		_net_steer = 0.0
		_net_brake = false
		_throttle = 0.0
		engine_force = 0.0
		set_horn(false)  # a driver bailing out mid-honk must not leave the horn stuck on
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
	# Drop bed walkers whose node was freed (disconnect) — their AreaDetector can't fire an exit.
	for player in _bed_players.keys():
		if not is_instance_valid(player):
			_bed_players.erase(player)
			changed = true
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
	# Engine off: no propulsion (steering + braking below still work). Zero the throttle so pressing
	# forward does nothing — not even releasing the hand brake, which stays on until the engine runs.
	if not _engine_on:
		throttle_in = 0.0
	# Hand brake holds the vehicle until the pilot presses the throttle again.
	if _handbrake and absf(throttle_in) > 0.05:
		set_handbrake(false)  # goes through the setter, so the release is heard too
	# Ramp the applied torque toward the throttle (tempers the launch on any powertrain).
	_throttle = move_toward(_throttle, throttle_in, torque_response * delta)
	var forward_kmh: float = _forward_speed_kmh()

	_sync_powertrain()  # pick up any live inspector tweak (bench tuning)
	var force: float = _powertrain.force(_throttle, forward_kmh)

	# Overloaded past the hard limit, hand-braked, or engine off: no drive force. Steering + braking
	# further down are unaffected — a dead engine still rolls, steers and brakes.
	var immobilized: bool = is_immobilized()
	if immobilized or _handbrake or not _engine_on:
		force = 0.0

	# VehicleBody3D drives toward +Z for a positive engine_force; our cab faces -Z, so negate.
	engine_force = -force
	# Speed-sensitive lock: shrink the max steer angle the faster we go (stable at speed, agile slow).
	var lock_deg: float = max_steer_deg
	if steer_speed_falloff_kmh > 0.0:
		var speed_t: float = clampf(absf(forward_kmh) / steer_speed_falloff_kmh, 0.0, 1.0)
		lock_deg = lerpf(max_steer_deg, max_steer_deg * steer_min_ratio, speed_t)
	_steer_target = turn * deg_to_rad(lock_deg)
	# Turning toward a held direction is progressive; releasing (or crossing centre) recentres a bit
	# snappier so the wheels don't feel sluggish coming back straight.
	var recentring: bool = absf(turn) < 0.01 or signf(turn) != signf(steering)
	var steer_rate: float = steer_return_speed if recentring else steer_speed
	steering = move_toward(steering, _steer_target, steer_rate * delta)
	# Coasting (no throttle, no brake): apply engine braking + rolling resistance so the truck bleeds
	# speed instead of rolling forever — VehicleWheel3D models neither on its own.
	var coasting: bool = absf(throttle_in) < 0.05 and not braking
	if immobilized or braking or _handbrake:
		brake = brake_force
	elif coasting and absf(forward_kmh) > 0.1:
		brake = engine_brake
	else:
		brake = 0.0

	# IRL a powered wheel keeps spinning once it leaves the ground. VehicleWheel3D stops the
	# visual with no contact, so spin powered airborne wheels ourselves (about their axle).
	if absf(_throttle) > 0.01:
		for wheel in _wheels:
			if wheel.use_as_traction and not wheel.is_in_contact():
				_spin_wheel_visual(wheel, -signf(_throttle) * 25.0 * delta)
	_update_steering_wheel(steering)  # turn the volant (server/bench); a replica does it in _update_wheels_visual

## Cancel the hand-brake drift HERE (after the physics step), NOT in _physics_process — setting
## linear_velocity before the step fought the wheel suspension and made the body sink onto its
## chassis. We damp only the HORIZONTAL drift (in the body's plane) and keep the vertical, so the
## suspension keeps holding the truck up. Stays DYNAMIC: a collision impulse is far bigger than
## handbrake_hold * step, so a hit still pushes it (it then re-settles).
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# Capture the real "up" from the gravity acting on us (radial on a planet, world-up on the bench,
	# zero in space). This is the ONLY place the actual gravity vector is exposed. Used by the rollover
	# check + reset_upright, which must measure tilt against the LOCAL vertical, not world Y — at
	# astronomic planet coords world Y is ~65° off local up, so a flat truck sat right on the rollover
	# threshold and spilled its cargo at random. Kept from the last non-zero reading in free fall / 0g.
	var g: Vector3 = state.total_gravity
	if g.length_squared() > 0.001:
		_gravity_up = -g.normalized()
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

## No driver aboard (the pilot left — possibly bailing "en marche" with the throttle still held): cut
## the drive. engine_force PERSISTS from the last _apply_drive, so without this the empty truck keeps
## powering itself and rolls forever. Then bleed speed like coasting (VehicleWheel3D has no rolling
## resistance of its own). The hand-brake case is handled separately by the caller. From _physics_process.
func _coast_no_driver() -> void:
	engine_force = 0.0
	brake = engine_brake if linear_velocity.length() > 0.1 else 0.0

## Parked hand brake with no driver: kill the drive + brake the wheels. The truck is held still by the
## drift cancel in _integrate_forces — we do NOT freeze the body: freezing a VehicleBody3D collapses
## the wheel suspension so the wheels sink into the ground. The brake + drift cancel hold it just fine.
func _hold_handbrake(_delta: float) -> void:
	engine_force = 0.0
	brake = brake_force

## Head lights — drop-in like seats: add any Light3D(s) to the group "vehicle_light" anywhere under
## the vehicle scene (no code). The driver toggles them (L); the state is replicated so every client
## sees them. Lights are found by group, filtered to this vehicle's own descendants.
func _headlights() -> Array:
	var out: Array = []
	# May be called from client_channel_data_update BEFORE the node is in the tree (spawn): no tree
	# yet -> no lights. set_headlights still records _headlights_on, applied again in _ready().
	if not is_inside_tree():
		return out
	for n in get_tree().get_nodes_in_group(LIGHT_GROUP):
		if n is Node3D and is_ancestor_of(n):
			out.append(n)
	return out

## Apply the head-light state to every vehicle_light node (runs on the server AND each client replica).
## The switch click only fires on a REAL change, once the vehicle exists here (_spawned): the _ready
## init and the spawn snapshot of a truck whose lights are already on must stay silent.
func set_headlights(on: bool) -> void:
	var flipped: bool = on != _headlights_on
	_headlights_on = on
	for light in _headlights():
		(light as Node3D).visible = on
	if not flipped or not _spawned:
		return
	if on:
		_play_sfx(sfx_lights_on, sfx_lights_on_db, sfx_lights_on_falloff,
				sfx_lights_on_distance, sfx_lights_on_attenuation)
	else:
		_play_sfx(sfx_lights_off, sfx_lights_off_db, sfx_lights_off_falloff,
				sfx_lights_off_distance, sfx_lights_off_attenuation)

## Server: flip the head lights; _replicate_transform then pushes the new state to clients.
func toggle_headlights() -> void:
	set_headlights(not _headlights_on)

## True when the head lights are on — server state, or the replicated state on a client replica
## (the dashboard reads this). set_headlights keeps _headlights_on in sync on both sides.
func is_headlights_on() -> bool:
	return _headlights_on

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
