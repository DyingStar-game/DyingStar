class_name Player

extends CharacterBody3D

signal hs_client_action_move
signal hs_server_move
signal hs_client_action_pressed
signal display_debug(show: bool)
signal hs_server_player_update

@warning_ignore("unused_signal")
signal client_action_requested(datas: Dictionary)

const MOVE_FORWARD: String = "move_forward"
const MOVE_BACK: String = "move_back"
const MOVE_LEFT: String = "move_left"
const MOVE_RIGHT: String = "move_right"
const JUMP: String = "jump"
## Seconds with no gravity area before we treat it as real 0g (ignores brief reparent gaps).
const ZERO_G_GRACE: float = 0.2
const CROUCH: String = "crouch"
const SPRINT: String = "sprint"
const PAUSE: String = "pause"

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

# Hand brake: a long press on the brake (Space) at low speed toggles the vehicle's hand brake.
const HANDBRAKE_HOLD_SECS: float = 0.4
const HANDBRAKE_MAX_KMH: float = 3.0
## How far below the crack-aware terrain surface counts as a fall-through
## (see _catch_if_below_surface).
const _SURFACE_CATCH_MARGIN := 3.0

# The dev spawn wheel's contents live in SpawnCatalog (scenes/props/spawn_catalog.gd): one table read
# by the client (to build the wheel) AND by the server (to validate the key and place the prop).

# Teleporter pads (Area3D in group "teleporter"): area name -> destination
# planet + landing offset from the planet origin, expressed in the PLANET'S OWN
# axes, so the spot stays put on the ground as the planet spins (see
# PlayerServer._teleport_to_system). The destination is matched by
# PlanetData.planet_name, NEVER by node name: server-side nodes are renamed
# to Horizon's names (e.g. tarsis_4_2 -> "P4_M2"), so scene-root names like
# "Tarsis4_2" only exist on the client.
const TELEPORT_TARGETS := {
	"tarsis_4_2": {
		"planet": "tarsis_4_2",
		"pos": Vector3(5887586.7, 2175943.7, -1037588.4),
	},
	"tarsis_4_orbital": {
		"planet": "tarsis_4",
		"pos": Vector3(4520717.7, 2714719.7, -3734460.4),
	},
}

@export_group("Controls map names")

@export_group("Customizable player stats")
## Body mass (kg) added to a vehicle's total weight when seated. Mass is gravity-independent
## (75 kg everywhere); only the WEIGHT changes with gravity. CharacterBody3D has no built-in mass.
@export var mass: float = 75.0

@export_subgroup("Movement")
@export var walk_speed: float = 1.5
@export var walk_back_speed: float = 0.8
## Walk speed is adjustable by the mouse wheel between these bounds, in walk_speed_step increments
## (GDD: 0.5-3 m/s, 6 tiers). walk_speed above is the initial/default tier and MUST sit inside these
## bounds — outside, the first wheel notch clamps into range and speed jumps instead of stepping.
@export var walk_speed_min: float = 0.5
@export var walk_speed_max: float = 3.0
@export var walk_speed_step: float = 0.5
@export var sprint_speed: float = 5.0
## GDD: crouching is "limited to 2 m/s" — a CEILING, so it caps the wheel-chosen walk speed rather
## than forcing a pace (see PlayerServer: speed = minf(speed, crouch_speed)). At 2.0 a crouched
## player therefore moves at whatever tier they picked, up to 2 m/s.
@export var crouch_speed: float = 2.0
@export var prone_speed: float = 0.5
## Physics capsule height (m) per stance — the standing height is read from the scene. The collider
## shrinks so a crouched/prone player fits under low obstacles; feet stay on the ground.
@export var crouch_collider_height: float = 1.2
@export var prone_collider_height: float = 0.6
@export var jump_height: float = 0.5
@export var regular_climb_speed: float = 6.0
@export var fast_climb_speed: float = 8.0
# Speed multiplier while carrying an ore (issue #124): slower with hands full.
@export var carry_speed_factor: float = 0.5
## How fast (m/s²) the horizontal velocity is steered toward the target speed, so the body ramps up
## and coasts to a stop instead of snapping. Applied ON THE FLOOR only — the GDD gives the jump no air
## control, so an airborne body keeps the velocity it took off with.
@export var acceleration: float = 10.0

@export_subgroup("Vault / climb")
## Auto-vault: walking forward into a low obstacle or a ledge, the body climbs ONTO it automatically
## (server-decided). The clip is chosen by the obstacle's height — see the animation set's Climb group.
## A ledge lower than this (m) is just a step you walk over (no vault) — normal movement handles it.
@export var vault_min_height: float = 0.5
## Tallest ledge the body will climb onto (m). Higher = a wall, blocked.
@export var vault_max_height: float = 2.3
## Height bands (m): up to vault_low_max the short vault-over ("SafetyVault"), up to vault_climb1_max the
## "ClimbUp_1m" clip, above that "ClimbUp_2m". Read an obstacle's exact height on the debug HUD and set
## the thresholds just below it (e.g. a ~1 m pallet should read as a 1 m climb, so keep vault_low_max < 1).
@export var vault_low_max: float = 0.9
@export var vault_climb1_max: float = 1.7
## How far below the detected ledge top (m) the face is checked. Probing near the LIP (not at a fixed
## knee height) lets an ELEVATED ledge — a platform with a gap under it — be vaulted too, not only
## ground obstacles, while a slope is still rejected (its face reads as walkable, not a steep wall).
@export var vault_face_margin: float = 0.15
## How far ahead (m) an obstacle is detected, and how far ONTO the ledge the body finishes.
@export var vault_reach: float = 0.6
@export var vault_land_forward: float = 0.4
## SafetyVault (low band) is a vault-OVER: instead of ending ON TOP, the body clears the obstacle and
## lands this far forward (m) at ~ground height — so the pose stays horizontal, no rise onto the top.
@export var vault_over_distance: float = 1.3
## Vault-OVER arc: the body rises this far (m) ABOVE the obstacle top at mid-vault, then drops to the
## far-side ground — the "up and over" trajectory a root-motion clip would bake, done server-side.
@export var vault_arc_margin: float = 0.2
## Scripted climb durations (s) per clip — tune to match the actual clip lengths.
@export var vault_duration: float = 0.6
@export var climb1_duration: float = 0.9
@export var climb2_duration: float = 1.3
## Delay (s) after a vault before another can start, so you don't chain-climb the same ledge.
@export var vault_cooldown: float = 0.4
## Step-up: a LOW obstacle (below vault_min_height) is climbed by plain walking (Godot's CharacterBody3D
## won't step up on its own). This is how far ahead (m) a step is felt — keep it short (~capsule radius)
## so the body only lifts when it's actually against the step, not floating toward it.
@export var step_up_reach: float = 0.4
## How long (s) the smooth glide ONTO a step takes. Short so walking barely pauses; 0 would snap.
@export var step_up_duration: float = 0.12

@export_subgroup("EVA / 0g")
## EVA (dev free-flight) cruise speed in m/s. Toggled with the `toggle_eva` action ('$' by default,
## remappable in Settings > Controls). A test aid to fly around a body and inspect its day/night faces:
## the server detaches the player from gravity and flies it where the camera looks, ignoring collision.
@export var eva_speed: float = 2000.0
@export var player_thruster_force = 10

@export_subgroup("Carry & interaction")
## Where a carried item floats, relative to the CAMERA pivot (issue #124): -Z is the carry distance
## along the gaze, so the item stays centered on the crosshair at any head pitch. Keep X/Y at 0 for
## exact crosshair alignment. (The actual value is overridden per scene, e.g. player.tscn.)
@export var carry_offset: Vector3 = Vector3(0.0, 0.0, -1.5)
## Reach (m) of the interaction ray — how far you can grab / interact with an object. Applied to the
## InteractRay in _ready; the carry grab distance follows it (it reads interact_ray's length).
@export var interact_ray_length: float = 1.5
@export var arm_length: float = 0.5

@export_subgroup("Camera")
@export_range(0.0, 1.0) var view_bobbing_amount: float = 1.0
@export_range(1.0, 10.0) var camera_sensitivity: float = 2.0
@export_range(0.0, 0.5) var camera_start_deadzone: float = .2
@export_range(0.0, 0.5) var camera_end_deadzone: float = .1

# --- Audio SFX — all OPTIONAL: an unassigned sound simply plays nothing -------
# Drop an audio file straight into a Sound slot; each sound then has its own volume, fade-out curve
# and audible radius (see Sfx3D, shared with the vehicle). The sounds are POSITIONAL and played by
# every client on every player body — your own AND the other players' — from state the server already
# replicates (torch, jump) or from the body's own movement (footsteps). PlayerClient drives them.
#
# The four knobs of every sound:
#   Sound       — the audio file.
#   Db          — its loudness in dB, at the Falloff distance.
#   Falloff     — reference distance (m): past it the sound starts really fading.
#   Distance    — hard cut-off (m): further away it is not computed at all (CPU saver).
#   Attenuation — HOW it fades with distance (see Sfx3D.Attenuation).
@export_group("Audio SFX")
@export_subgroup("Torch on")
## Played when the player switches the torch on.
@export var sfx_torch_on: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_torch_on_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_torch_on_falloff: float = 3.0
@export_range(1.0, 500.0, 1.0) var sfx_torch_on_distance: float = 20.0
@export var sfx_torch_on_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Torch off")
## Played when the player switches the torch off.
@export var sfx_torch_off: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_torch_off_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_torch_off_falloff: float = 3.0
@export_range(1.0, 500.0, 1.0) var sfx_torch_off_distance: float = 20.0
@export var sfx_torch_off_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Footsteps")
## Footstep samples: one is picked at random on each step (never the same one twice in a row, so the
## walk does not sound like a machine). Put 3+ variations here; leave empty for no footsteps.
@export var sfx_footsteps: Array[AudioStream] = []
@export_range(-40.0, 12.0, 0.5) var sfx_footstep_db: float = -6.0
@export_range(0.5, 200.0, 0.5) var sfx_footstep_falloff: float = 3.0
@export_range(1.0, 500.0, 1.0) var sfx_footstep_distance: float = 25.0
@export var sfx_footstep_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT
## One step every N metres WALKED — not every N seconds. The cadence then follows the speed on its own:
## running covers the distance faster, so the steps come faster. This is the stride length.
@export_range(0.2, 4.0, 0.05) var sfx_footstep_stride: float = 1.9
## Random pitch spread (±) on each step: the same sample never sounds exactly twice the same.
@export_range(0.0, 0.5, 0.01) var sfx_footstep_pitch_jitter: float = 0.08

@export_subgroup("Jump")
## Played when the player jumps (the effort, not the landing).
@export var sfx_jump: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_jump_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_jump_falloff: float = 3.0
@export_range(1.0, 500.0, 1.0) var sfx_jump_distance: float = 25.0
@export var sfx_jump_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Vault (over a low obstacle)")
## Played when the player auto-vaults OVER a low obstacle (SafetyVault). See Vault / climb stats.
@export var sfx_vault: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_vault_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_vault_falloff: float = 3.0
@export_range(1.0, 500.0, 1.0) var sfx_vault_distance: float = 25.0
@export var sfx_vault_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Climb 1m")
## Played when the player climbs ONTO a ~1 m ledge (ClimbUp_1m).
@export var sfx_climb_1m: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_climb_1m_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_climb_1m_falloff: float = 3.0
@export_range(1.0, 500.0, 1.0) var sfx_climb_1m_distance: float = 25.0
@export var sfx_climb_1m_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Climb 2m")
## Played when the player climbs ONTO a ~2 m ledge (ClimbUp_2m).
@export var sfx_climb_2m: AudioStream
@export_range(-40.0, 12.0, 0.5) var sfx_climb_2m_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_climb_2m_falloff: float = 3.0
@export_range(1.0, 500.0, 1.0) var sfx_climb_2m_distance: float = 25.0
@export var sfx_climb_2m_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_group("")

var client_uuid: String = ""

var player_display_name: String = ""

var input_direction: Vector2
var movement_strength: float
var mouse_motion: Vector2
var is_jumping: bool = false

## Per-frame derived locomotion of THIS body (planar/vertical speed, body-frame move direction, airborne,
## seated), computed once by PlayerClient._sample_locomotion and read by the footsteps AND the puppet's
## CharacterAnimator — so the same numbers drive both, on the owner and on every remote avatar (DRY).
var locomotion_sample: Dictionary = {}
## Owner's current mouse-wheel-chosen walk speed (m/s) — mirrored here by PlayerClient for the debug
## HUD, seeded from walk_speed in its setup() (so the HUD never reads 0 while the body walks).
var walk_speed_target: float = 0.0
## Currently requested emote KEY (see EmoteCatalog), replicated so everyone plays it on this body. ""
## = none. The animator starts it while standing and clears it (back to "") on move or when it ends.
var emote_key: String = ""
## Last auto-vault event ("vault:<key>:<n>", key = vault / climb_1m / climb_2m), replicated like the
## emote so every body plays the matching climb clip. The counter makes each vault a fresh value; the
## animator (CharacterAnimator) plays the clip as a one-shot. "" = none yet.
var vault_key: String = ""
## Replicated seat state that drives the sit/drive POSE, for the owner AND every remote avatar (a remote
## is NOT reparented when it sits, so this is its only seat signal): "" = on foot, "driver", "passenger".
## Owner sets it locally on enter/leave (immediate); remotes read the server's "seat:/unseat:" action.
var seated_role: String = ""
## Movement stance, replicated so remotes show it: 0 = standing, 1 = crouched, 2 = prone. Server-owned —
## it caps the speed, resizes the collider, and drives the crouch/crawl animation.
var stance: int = 0
## Shared belt attachment point (a BoneAttachment3D on the puppet's hip bone, created by CharacterAnimator):
## any tool holsters onto it with its own offset, so a stowed tool follows the animated body. Null on the
## dedicated server (no puppet).
var belt_mount: Node3D = null

var spawn_position: Vector3 = Vector3.ZERO
var spawn_up: Vector3 = Vector3.UP

var can_interact: bool = false

var health: int = 100
var stamina: int = 100
var hunger: int = 100
var thirst: int = 100
var integrity: int = 3

## Current local gravity (m/s²), recomputed each physics tick by the server from the gravity area the
## player is in (see _compute_gravity) — runtime state, not a tunable stat. 0 = zero-g fallback.
var gravity: float = 0.0
var gravity_parents: Array[Area3D]

var last_basis: Basis
var remote_player: bool = false
var input_from_server: Dictionary = {
	"input_direction": Vector2.ZERO,
	"rotation": Vector3.ZERO
}
var new_input_from_server: bool = false

var client_last_input_direction = Vector2.ZERO
var client_last_global_rotation = Vector3.ZERO

var is_parented: bool = false

# NPC (server-authoritative). Set on spawn by server.gd; PlayerServer reads these to drive movement.
## True when this Player is a server-controlled NPC instead of a networked client.
var is_npc: bool = false
## Destination the NPC walks toward, or null when it has no goal. Set by external AI / spawn logic
## (consume-only here: PlayerServer only reads it). A Vector3 in the NPC PARENT's frame — the same frame
## as `position` — NOT world space: read it through PlayerServer._npc_target_global(), because the
## navigation agent it feeds wants a global point.
var npc_go_to_position = null
## Point the standing NPC turns to face, or null when it has no facing goal. Same frame convention as
## npc_go_to_position (NPC PARENT's frame). PlayerServer pivots the body toward it around its own up
## axis at a calm human speed, then clears it once aligned. Walking overrides it (the body faces the
## walk direction), so a new npc_go_to_position drops it.
var npc_face_position = null

# to disable player input when piloting vehicule/ship
var active = false
# Server-authoritative: true while seated in a vehicle. Blocks walking on the SERVER (which
# never sets `active` true). Set by Vehicle.server_enter / server_exit.
var piloting: bool = false

# Server-authoritative: true while in EVA free-flight (dev test aid, toggled by the `toggle_eva`
# action). The server flies the body where the camera looks, no gravity, no collision. See eva_speed.
var eva_mode: bool = false

var hands_item: Node3D = null

# Admin cleanup tool (key 2). Built at runtime for the local player only (see _ready).
var admin_cleanup_tool: AdminCleanupTool = null

# The 3D screen (e.g. a mining depot) the player is currently in front of, or null. Set
# by the screen's interaction Area; while set, the mouse is freed to click the screen.
# The NODE is the single source of truth: its global_position is always current, so the camera reads
# where to look straight from it. A separate world position used to be snapshotted alongside, which
# went stale the moment the planet spun on (it carries both the player and the screen).
var screen_interacting = null

var _display_debug: bool = false

## Consecutive server ticks this player has been settled (no input, on floor,

# Last camera pitch ("head" player property) sent to the server, throttled.
var _last_head_sent: float = INF
# Last camera yaw ("head_yaw", non-zero only while seated) sent to the server, throttled.
var _last_head_yaw_sent: float = INF
# Seconds the player has had NO gravity area. A reparent (e.g. leaving a spawn apartment) drops all
# gravity areas for a frame or two while the body re-enters PlanetGravity; we only switch to the 0g
# control scheme (which zeroes the camera pitch) after the gravity has really been gone this long,
# so that blip doesn't snap the look back to the horizon.
var _no_gravity_time: float = 0.0
var _interp := NetInterpolator.new()  # smooths a REMOTE player's replicated movement
# Owner-local prediction of "am I carrying?", to stow/unstow the perforator immediately
# (the server broadcasts the stow to OTHER players; the owner doesn't echo to itself).
var _owner_carrying: bool = false

# Created lazily: a body-only ray for the server's carry line-of-sight checks (a node, so
# force_raycast_update works in any context — direct_space_state is only valid during physics).

# Carry prompt, decided by the SERVER (it owns the collisions) and replicated to the owner:
# "" / "carry" / "drop" / "cargo" (cargo = dropping here loads it onto a truck). The client only
# displays it — it never computes reachability itself.
var _carry_prompt: String = ""

# Behaviour strategy for this player (Strategy pattern), created once at spawn: PlayerServer on the
# dedicated server, PlayerClient on a client (owner + remote). Role-specific logic lives there; this
# body stays a thin facade over the shared nodes/state. Typed as Node — GDScript duck-types the calls.
var _role: Node = null

# Dev spawn wheel (radial menu), owner only — hold the spawn key to pick what to spawn.
var _spawn_wheel: RadialMenu = null
# Emote wheel (radial menu), owner only — hold the emote key (T) to pick an emote.
var _emote_wheel: RadialMenu = null

# Owner: uuid of the vehicle we are seated in ("" = on foot). Set when we take a seat.
var _seat_vehicle_uuid: String = ""
# Owner: the local vehicle replica (for the driver HUD / messages).
var _seat_vehicle_node: Node3D = null
# The VehicleSeat we occupy (driver or passenger); we ride its sit point each frame. Set
# on the client when we enter, on the server by Vehicle.server_enter. Null = on foot.
var _seat_node: Node3D = null
# True when our seat is the driver seat (drive input + HUD + R). Passenger = just rides.
var _seat_is_driver: bool = false
# The VehicleSeat box the player stands in (set by our own AreaDetector); E takes that seat.
var _nearby_seat: Node = null
# The Vehicle whose cargo bay we are standing in on foot (our AreaDetector reports it). Used both
# for the bed-walker weight (server) and to load a crate we drop while standing in it.
var _in_vehicle_bed: Node = null
var _last_throttle: float = INF  # last drive input sent (to send only on change)
var _last_steer: float = INF
var _last_brake: bool = false
var _space_held_time: float = 0.0  # driver: how long the brake (Space) has been held
var _handbrake_sent: bool = false  # driver: hand brake toggle already fired for this hold
var _seated_saved: bool = false
# Fallback walking-state collision (the scene sets layer=player / mask=MASK_SOLID; set_seated saves
# the real values before zeroing). Kept in sync with Globals so a restore-before-save can't fall back
# to the wrong layer.
var _saved_collision_layer: int = 1 << (Globals.LAYER_PLAYER - 1)
var _saved_collision_mask: int = Globals.MASK_SOLID


@onready var camera = $CameraPivot/Camera3D

@onready var labelx: Label = $UserInterface/Debug/LabelXValue
@onready var labely: Label = $UserInterface/Debug/LabelYValue
@onready var labelz: Label = $UserInterface/Debug/LabelZValue
@onready var astronaut: Node3D = $Placeholder_Collider/Astronaut
@onready var puppet: Node3D = $Puppet
@onready var interact_ray: RayCast3D = $CameraPivot/Camera3D/InteractRay
@onready var interact_label: Label = $UserInterface/HUD/InteractLabel
@onready var camera_pivot: Node3D = $CameraPivot

@onready var direct_chat: DirectChat = $UserInterface/DirectChat

@onready var box4m: PackedScene = preload("res://scenes/_universe/props/containers/box_4m.tscn")
@onready var box50m: PackedScene = preload("res://scenes/_universe/props/containers/box_50cm.tscn")
@onready var is_inside_box4m: bool = false

@onready var flashlight: SpotLight3D = $CameraPivot/Camera3D/Torch

# Mining gameplay (perforator equip, aim, perforation) is encapsulated in the
# MiningTool component (scene child). Networking stays here (see _ready wiring).
@onready var mining_tool: MiningTool = $MiningTool
## Server-only pathfinding agent, driven by PlayerServer when this body is an NPC. Present on every
## Player instance (it lives in player.tscn) but only used on the dedicated server.
@onready var navigation_agent_3d: NavigationAgent3D = $NavigationAgent3D

func _enter_tree() -> void:
	if remote_player:
		position = spawn_position
		$UserInterface.visible = false
		# Don't hide CameraPivot: its Torch (SpotLight3D) lives under it, and a hidden ancestor would
		# keep a remote player's flashlight dark even when its replicated state is ON. The camera is
		# made non-current in _ready, so it never renders for us anyway.

	elif not OS.has_feature("dedicated_server"):
		# _enter_tree fires again on every reparent (reparent = tree exit + re-enter), but signal
		# connections survive a tree exit, so guard against re-connecting the same callable twice.
		if not NetworkOrchestrator.set_player_global_position.is_connected(_set_player_global_position):
			NetworkOrchestrator.set_player_global_position.connect(_set_player_global_position)
	else:
		# server side
		$UserInterface.visible = false
		$CameraPivot.visible = false

func _ready() -> void:
	prints("Player", name, "spawned at", spawn_position, "on server" if GameOrchestrator.is_server() else "on client")

	# Apply the configurable interaction reach to the ray (forward = -Z). Everything that reads
	# interact_ray (grab, line of sight, carry distance) picks this up.
	interact_ray.target_position = Vector3(0.0, 0.0, -interact_ray_length)

	# Mining tool: build its equipment mount + perforator from our camera rig, and
	# relay its replicated-state requests to the server + its aim signal to the UI.
	mining_tool.setup(camera_pivot, camera)
	mining_tool.sync_requested.connect(client_send_action_to_server)
	mining_tool.aiming_changed.connect($UserInterface.set_aiming)

	# Strategy: pick this player's behaviour ONCE — authority on the dedicated server, presentation
	# (owner + remote) on a client. The role is a child node driving this body; each role's setup()
	# runs its own spawn-time init (server placement vs owner tools/camera vs remote name tag).
	_role = PlayerServer.new() if OS.has_feature("dedicated_server") else PlayerClient.new()
	_role.name = "Role"
	_role.player = self
	add_child(_role)
	_role.setup()

func set_uuid(uuid: String) -> void:
	client_uuid = uuid
	self.set_meta("client_uuid", uuid)

func connect_area_detect():
	if OS.has_feature("dedicated_server"):
		print("Connecting area detector on server side")
	$AreaDetector.monitoring = true
	# The single active monitor: scan ONLY the `zone` layer, where every passive detection zone lives
	# (seats, cargo bay, gravity, spawn). They are monitorable-only; the player does all the looking.
	# Behaviour is routed by group (gravity / spawn / vehicle_seat / vehicle_cargo).
	$AreaDetector.collision_mask = Globals.MASK_PROBE
	if not $AreaDetector.area_entered.is_connected(_on_area_detector_area_entered):
		$AreaDetector.area_entered.connect(_on_area_detector_area_entered)
	if not $AreaDetector.area_exited.is_connected(_on_area_detector_area_exited):
		$AreaDetector.area_exited.connect(_on_area_detector_area_exited)

func get_current_gravity_parent() -> Node3D:
	if gravity_parents.is_empty(): return null
	return gravity_parents.back()

func update_last_basis() -> void:
	var gravity_parent = get_current_gravity_parent()
	if !gravity_parent: return

	last_basis = gravity_parent.global_transform.basis


## Disable our collision while seated so we don't shove the vehicle's physics body.
func set_seated(seated: bool) -> void:
	if seated:
		if not _seated_saved:
			_saved_collision_layer = collision_layer
			_saved_collision_mask = collision_mask
			_seated_saved = true
		collision_layer = 0
		collision_mask = 0
	else:
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
		_seated_saved = false


## Feed a REMOTE player its latest server transform (entity interpolation). The position is
## local (relative to the parent); the rotation arrives global, so convert it to the parent's
## frame before handing it to the interpolator (which works in local space).
## Owner on foot: feed our server-driven position so it is smoothed (position only — the
## mouse look stays immediate). No client prediction yet, so this trades a touch of lag for
## no saccades.
func net_set_local_target(local_pos: Vector3) -> void:
	_interp.set_position_target(self, local_pos)


func net_set_target(local_pos: Vector3, local_rot: Vector3) -> void:
	# rotation is replicated in the planet-LOCAL frame (see player_client send / player_server broadcast),
	# so apply it directly as the local basis — do NOT convert through the parent's global basis. The parent
	# (planet) spins on the client but is static on the server; converting through it would re-introduce the
	# spin offset and tilt remote bodies. Local rotation is frame-invariant, exactly like the local position.
	var target_basis := Basis.from_euler(local_rot)
	_interp.set_target(self, local_pos, target_basis)

## Re-snap the interpolation after a reparent (the local frame changed).
func net_reset_interp() -> void:
	_interp.snap_next()

func _ride_seat(seat: Node3D) -> void:
	var eye: Transform3D = seat.sit_transform()
	var veh: Node = seat.vehicle() if seat.has_method("vehicle") else null
	if veh != null and get_parent() == veh:
		# Parented to the vehicle: ride in LOCAL space so we move WITH it by transform
		# inheritance (no per-frame world fight against the parent's smoothing) — kills the jitter.
		var local_eye: Transform3D = (veh as Node3D).global_transform.affine_inverse() * eye
		transform.basis = local_eye.basis
		transform.origin = local_eye.origin - local_eye.basis * camera_pivot.position
	else:
		global_transform.basis = eye.basis
		global_position = eye.origin - eye.basis * camera_pivot.position
	# Free look from the seat: the mouse turns the camera pivot (yaw + pitch) relative to the vehicle
	# forward, so the view is no longer locked straight ahead. BOTH are clamped: a seated body can't spin
	# its view around forever (unbounded yaw also flipped the replicated head to the wrong side past 180°).
	camera_pivot.rotation.y = clampf(
		camera_pivot.rotation.y + mouse_motion.x * camera_sensitivity,
		deg_to_rad(-120.0), deg_to_rad(120.0))
	camera_pivot.rotation.x = clampf(
		camera_pivot.rotation.x + mouse_motion.y * camera_sensitivity,
		deg_to_rad(-80.0), deg_to_rad(80.0))
	mouse_motion = Vector2.ZERO
	velocity = Vector3.ZERO

## Returns surface gravity scaled by inverse-square distance from the area centre.
## At the surface (dist == gravity_point_unit_distance) the result equals area.gravity.
func _compute_gravity(area: Area3D) -> float:
	if not area.gravity_point:
		return area.gravity
	var planet_radius := area.gravity_point_unit_distance
	var dist := global_position.distance_to(area.global_position)
	if dist <= 0.0:
		return area.gravity
	return area.gravity * (planet_radius / dist) * (planet_radius / dist)




func orient_player():
	global_transform = global_transform.interpolate_with(Globals.align_with_y(global_transform, up_direction), 0.3)

func _on_area_detector_area_entered(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if area.name == "PlanetGravity":
			var planet = area.get_parent().get_parent()
			#reparent(planet)
			# call_deferred("reparent", planet)
			is_parented = true
			emit_signal(
				"hs_server_move",
				client_uuid,
				snapped(position, Vector3(0.001, 0.001, 0.001)),
				snapped(rotation, Vector3(0.0001, 0.0001, 0.0001)),
				planet.uuid,
				is_parented
			)
		gravity_parents.push_back(area)
	elif area.is_in_group("vehicle_seat"):
		# Our own monitor walked into a seat box: remember it so E takes that seat (client prompt).
		_nearby_seat = area
	elif area.is_in_group("vehicle_cargo"):
		# We stepped into a bed on foot: add our weight to the load (server-authoritative), remember
		# the bed so a dropped crate loads onto this truck, and RIDE it (become a child of the truck
		# so we don't slide). Reparent is deferred — it's illegal inside an Area3D signal callback.
		var veh := area.get_parent()
		if veh is Vehicle:
			_in_vehicle_bed = veh
			veh.add_bed_player(self)
	elif area.is_in_group("teleporter"):
		# Server-authoritative: the server reparents + repositions, then the
		# move (with parent uuid) reaches the client through Horizon and
		# client.gd player_update applies the reparent locally.
		if OS.has_feature("dedicated_server"):
			var target: Dictionary = TELEPORT_TARGETS.get(area.name, {})
			if target.is_empty():
				push_warning("[Player] teleporter '%s' has no TELEPORT_TARGETS entry"
						% area.name)
				return
			var destination := _find_planet_by_data_name(target["planet"])
			if destination == null:
				push_warning("[Player] teleporter '%s': planet '%s' not found in registry"
						% [area.name, target["planet"]])
				return
			print("[Player] teleporter '%s' -> planet '%s' (node '%s')"
					% [area.name, target["planet"], destination.name])
			# Deferred: reparenting a CharacterBody3D inside an Area3D physics
			# callback is illegal ("Removing a CollisionObject during a physics
			# callback is not allowed") and corrupts the body.
			_role.call_deferred("_teleport_to_system", destination, target["pos"])

## Server-side: resolve a planet node by its PlanetData.planet_name through
## the authoritative registry (props_list["planets"]). Node NAMES are assigned
## from Horizon world data (e.g. "P4_M2", "SandBox") and do not match the
## scene-root names, so find_child() by name is never reliable here.
func _find_planet_by_data_name(pname: String) -> Node:
	var agent = NetworkOrchestrator.network_agent
	if agent == null or not "props_list" in agent \
			or not agent.props_list.has("planets"):
		return null
	for puuid in agent.props_list["planets"]:
		var p = agent.props_list["planets"][puuid]
		if is_instance_valid(p) and p.get("planet_data") != null \
				and p.planet_data.planet_name == pname:
			return p
	return null


func _on_area_detector_area_exited(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if gravity_parents.has(area):
			gravity_parents.erase(area)
	elif area.is_in_group("vehicle_seat"):
		if _nearby_seat == area:
			_nearby_seat = null
	elif area.is_in_group("vehicle_cargo"):
		var veh := area.get_parent()
		if veh is Vehicle:
			if _in_vehicle_bed == veh:
				_in_vehicle_bed = null
			veh.remove_bed_player(self)
	elif area.is_in_group("spawn"):
		if not OS.has_feature("dedicated_server"):
			return
		var new_parent = area.get_parent().get_parent()
		# Deferred reparent + move sync: reparenting during the Area3D signal
		# callback is illegal ("busy adding/removing children"), and area_exited
		# can fire several times -> overlapping reparents crash the node while out
		# of tree. The move event MUST be emitted AFTER the reparent so the local
		# position is expressed in the new parent's frame; otherwise the server
		# places us with the old local position under the new parent uuid and
		# teleports us.
		call_deferred("_safe_reparent_and_sync", new_parent)
		# if gravity_parents.has(area):
		# 	gravity_parents.erase(area)

## npc_go_to_position is stored in the PARENT's frame (see PlayerServer). reparent() preserves the
## BODY's world position but silently changes what those stored goal coordinates mean — walking out of
## the spawn building reparents building→planet, and the unconverted goal sent the NPC to a wrong world
## point. Call this immediately BEFORE any reparent of an NPC: it re-expresses the goal in the incoming
## parent's frame so the WORLD destination the AI asked for stays the same.
func npc_goal_keep_world(new_parent: Node) -> void:
	if not is_npc or npc_go_to_position == null:
		return
	var old_parent = get_parent()
	if old_parent is Node3D and new_parent is Node3D:
		var goal_world: Vector3 = (old_parent as Node3D).global_transform * npc_go_to_position
		npc_go_to_position = (new_parent as Node3D).global_transform.affine_inverse() * goal_world

## Reparent guarded against invalid states (node/parent out of tree, already
## parented, repeated area_exited events) to avoid a server segfault, then emit
## the move so the server receives the position relative to the new parent.
func _safe_reparent_and_sync(new_parent: Node) -> void:
	print("YOLO REPARENT")
	if new_parent == null or not is_instance_valid(new_parent):
		return
	if not is_inside_tree() or not new_parent.is_inside_tree():
		return
	if get_parent() != new_parent:
		npc_goal_keep_world(new_parent)
		reparent(new_parent)
		emit_signal(
			"hs_server_move",
			client_uuid,
			snapped(position, Vector3(0.001, 0.001, 0.001)),
			snapped(rotation, Vector3(0.0001, 0.0001, 0.0001)),
			# Robust to the scene layout: a parent without a uuid (e.g. a grouping/test-zone node) = "".
			str(new_parent.uuid) if "uuid" in new_parent else "",
			true
	)

func _set_player_global_position(pos, rot):
	global_position = pos
	global_rotation = rot

# Send the properties of the player from godot server to horizon / client
# for example, the health, stamina, etc...
func server_send_properties_to_client(data: Dictionary):
	emit_signal(
		"hs_server_player_update",
		client_uuid,
		data,
	)

## Put the mining tool away. Used for tool exclusivity: selecting the admin cleanup tool
## (key 2) stows the perforator before showing itself.
func stow_mining_tool() -> void:
	if mining_tool != null:
		mining_tool.set_equipped(false)

# Send action of the client to the server part (Horizon / godot server)
# data example:
# {
#     "action": "jump"
# }
func client_send_action_to_server(data: Dictionary):
	emit_signal(
		"client_action_requested",
		data,
	)

# receive the properties sent by the server part (Horizon / godot server)
# this function is used to update the properties of the player on the client side. Only a client ever
# receives channel data for a player (server/client.gd), so we delegate to the PlayerClient role.
func client_channel_data_update(data: Dictionary) -> void:
	_role.client_channel_data_update(data)














## The carriable prop under the crosshair, or null. Shared by the SERVER (carry-prompt decision in
## PlayerServer._compute_carry_prompt) and the CLIENT (picking the target uuid to send). Checks the
## hit body itself AND its parent: a prop's collision can be the root (which carries interact(), e.g. a
## crate in a truck bed where get_parent() is the vehicle) or a child shape (parent carries interact()).
func _aimed_carriable() -> Node:
	if not interact_ray.is_colliding():
		return null
	var hit = interact_ray.get_collider()
	if hit == null:
		return null
	var prop: Node = null
	if hit.has_method("interact") and "uuid" in hit:
		prop = hit
	else:
		var p = hit.get_parent()
		if p != null and p.has_method("interact") and "uuid" in p:
			prop = p
	if prop == null:
		return null
	# NOTE: no line-of-sight check here — the client has no wall collision (collisions are
	# server-side), so it can't tell a wall is in the way. The SERVER re-checks line of sight
	# before granting the grab (see server_action_received / _is_blocked_by_geometry).
	# Don't offer a prop already carried by ANOTHER player (it IS reparented under them on our
	# client, so its parent is that Player — this is knowable without collision).
	var prop_parent = prop.get_parent()
	if prop_parent is Player and prop_parent != self:
		return null
	return prop

# receive properties from the client, often the actions
func server_action_received(data: Dictionary) -> void:
	# Server authority: delegate to the PlayerServer role (only the dedicated server receives this).
	_role.server_action_received(data)
