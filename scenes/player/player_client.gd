class_name PlayerClient
extends Node

const JUMP: String = "jump"  # kept in sync with Player.JUMP
## Hide a remote player's name tag beyond this distance from the local camera.
const NAME_TAG_MAX_DISTANCE: float = 25.0
## How closely the camera must already point at a 3D screen for _face_screen to consider it aimed and
## stop nudging it (dot of the view axis with the direction of the screen; 1.0 = dead on, ~0.9997 is
## a bit over 1°). Without a convergence test the camera re-aimed every single frame.
const FACE_SCREEN_EPSILON: float = 0.9997
## Below this ground speed (m/s) the player is standing, not walking: no footsteps (see _update_footsteps).
## Well under the slowest gait (crouch/back ~1.5 m/s), well over the network + physics jitter.
const MIN_WALK_SPEED: float = 0.6
## Above this vertical speed (m/s) the player is jumping / falling / riding, not walking: no footsteps.
## Generous, because a body walking on the terrain trimesh is always bobbing a little.
const MAX_STEP_CLIMB_SPEED: float = 2.5
## A jump is airborne for at least this long (s) before a slow vertical speed may count as a landing —
## otherwise the first frames of the jump, still slow, would already be read as "back on the ground".
const MIN_AIR_TIME: float = 0.2
## Vertical speed (m/s) under which an airborne player counts as landed.
const MAX_LANDED_CLIMB_SPEED: float = 1.0
## Smoothing rate (per second) for the DERIVED locomotion speed/direction. Position streams at ~30 Hz and
## the interpolator settles between updates, so raw per-frame speed is bursty and would flicker the walk
## animation on and off. Exponential smoothing at this rate keeps it steady (also stabilizes Jog direction).
const LOCO_SMOOTH_RATE: float = 8.0

## Client-side logic for a player — runs on every client instance, never on the server. Covers the
## OWNER (local input, camera, HUD prompts, prediction) and a REMOTE avatar (interpolation, name tag).
## Created by Player as a child node (so it gets its own _process / _unhandled_input from the engine);
## it reaches the shared body, nodes and state through `player`. (Filled in incrementally.)

## The body / facade this role drives (a Player). Untyped ON PURPOSE: typing it `Player` would create a
## cyclic class_name dependency (Player references PlayerServer/PlayerClient, which reference Player) and
## break global script compilation. Untyped duck-typing still reaches every Player member.
var player

## Remote player's name tag, drawn in 2D screen space (see _setup_name_tag) instead of a 3D billboard:
## at planetary world coordinates the GPU renders in single precision, so a 3D label shimmers as the
## camera moves. Projecting the head to the screen on the CPU (double precision) and drawing a plain
## 2D Label is rock-steady.
var _name_tag: Label = null

var _conversation_text: Label = null

## Audio SFX state (the exported knobs live on the Player facade — see its "Audio SFX" group).
## False until the first replicated update has been digested: the state a REMOTE player arrives with
## (torch already on…) is a snapshot, not something that just happened, and must stay silent.
var _sfx_live: bool = false
var _step_distance: float = 0.0    # metres walked since the last footstep
var _loco_last_position: Vector3 = Vector3.ZERO  # previous body position, to derive per-frame movement
var _smooth_speed: float = 0.0    # low-passed planar speed (m/s), fed to the animator AND the footsteps
var _smooth_forward: float = 0.0  # low-passed forward component (m/s, body frame): + = forward
var _smooth_right: float = 0.0    # low-passed right component (m/s, body frame): + = strafe right
var _loco_last_forward: Vector3 = Vector3.ZERO  # previous body forward, to derive the yaw rate (in-place turn)
var _smooth_yaw_rate: float = 0.0  # low-passed turn rate (rad/s) around up: + = one way, - = the other
var _sprint_sent: bool = false       # last sprint-held state sent to the server (owner) — send on change
var _walk_speed_target: float = 0.0  # mouse-wheel walk speed; seeded from player.walk_speed in setup()
var _step_last_index: int = -1     # which footstep sample was played last (never twice in a row)
var _last_jump_action: String = ""  # last "jump:<n>" seen, so a re-broadcast state is not re-played
var _last_land_action: String = ""  # last "land:<n>" seen (crisp jump-loop end on server touchdown)
var _last_emote_action: String = ""  # last "emote:<key>:<n>" seen, so a re-broadcast isn't re-triggered
var _last_seat_action: String = ""  # last "seat:/unseat:" seen (sit pose + optimistic-entry revert)
var _last_vault_action: String = ""  # last "vault:<key>:<n>" seen, so a re-broadcast isn't re-triggered
var _remote_carrying: bool = false  # replicated carry state of a REMOTE avatar (owner reads _owner_carrying)
var _airborne: bool = false        # jumping: no footsteps until the landing (see _update_footsteps)
var _air_time: float = 0.0         # seconds spent in the air since that jump

## One-time spawn init, called by Player._ready() once `player` is wired and both are in the tree.
## Remote avatar: just a screen-space name tag. Owner: build the dev tools, place the body, take over
## the camera, then go live after a short delay. (This is the former client/remote branches of _ready.)
func setup() -> void:
	# The animated puppet is the visible body now — for the owner (first person) and remotes alike.
	player.astronaut.visible = false
	var animator = player.puppet.get_node_or_null("CharacterAnimator")
	if animator != null:
		animator.setup(player, not player.remote_player)
	if player.remote_player:
		player.camera.current = false
		_setup_name_tag(str(player.name))
		_setup_conversation_text()
		return

	# Start at the scene's walk speed, mirrored for the debug HUD. It used to start at 0 as a "never
	# set" marker, so the HUD read 0.0 m/s while the body actually walked at walk_speed.
	_walk_speed_target = player.walk_speed
	player.walk_speed_target = _walk_speed_target

	# Dev spawn wheel: hold the spawn key (T) to pick what to spawn.
	player._spawn_wheel = RadialMenu.new()
	player._spawn_wheel.title = "Spawn"
	player.get_node("UserInterface").add_child(player._spawn_wheel)
	player._spawn_wheel.option_selected.connect(_on_spawn_selected)

	# Emote wheel: hold the emote key (T) to pick an emote (the spawn wheel moved to Alt+T).
	player._emote_wheel = RadialMenu.new()
	player._emote_wheel.title = "Emote"
	player.get_node("UserInterface").add_child(player._emote_wheel)
	player._emote_wheel.option_selected.connect(_on_emote_selected)

	# Admin cleanup tool (key 2): raycast + red aim line, left click deletes the
	# targeted player-spawned prop (rock / box / depot) down to the database.
	player.admin_cleanup_tool = AdminCleanupTool.new()
	player.add_child(player.admin_cleanup_tool)
	player.admin_cleanup_tool.setup(player.camera, player)

	player.global_position = player.spawn_position
	player.look_at(player.global_transform.origin + Vector3.FORWARD, player.spawn_up)

	player.position = player.spawn_position
	player.global_transform = Globals.align_with_y(player.global_transform, player.spawn_up)

	player.client_uuid = Globals.player_uuid
	player.set_meta("client_uuid", Globals.player_uuid)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	player.camera.current = true

	player.camera.make_current()
	_force_temp_sky_environment()
	# Client-only sun: a DirectionalLight aimed from the real system star toward this player, for crisp
	# shadows + day/night. The star's OmniLight lights the system but casts no shadows (unusable at scale).
	var sun := PlayerSunLight.new()
	sun.name = "PlayerSunLight"
	sun.player = player
	player.add_child(sun)
	# Client-only orientation gizmos: labelled markers pointing at the star and each planet/moon,
	# toggled from Settings > General (off by default). Parented UNDER the camera so the markers live
	# in camera-local coordinates and don't swim at astronomic distances.
	var gizmos := CelestialGizmos.new()
	gizmos.name = "CelestialGizmos"
	gizmos.player = player
	player.camera.add_child(gizmos)
	# Apply the saved field of view, and follow live changes from the settings menu.
	player.camera.fov = SettingsManager.get_fov()
	SettingsManager.fov_changed.connect(_on_fov_changed)
	# Debug panels: follow live the settings-menu "Show debug panels" toggle.
	if not SettingsManager.show_debug_changed.is_connected(_on_show_debug_changed):
		SettingsManager.show_debug_changed.connect(_on_show_debug_changed)
	# our own name tag is never created (only remote players get one)
	player.astronaut.visible = false
	player.interact_label.hide()
	player.connect_area_detect()
	# Show the "Spawning..." splash, then take control and let the world settle BEHIND it. up_direction is
	# only refreshed by _process (which runs once active), and the gravity up steadies over a few frames
	# after spawn — the body orientation + day/night follow it. The splash (a CanvasLayer at layer 100)
	# covers that settle, so there's no visible day->night + camera-tilt snap once it lifts.
	var loading := get_tree().root.get_node_or_null("Loading")
	if loading != null:
		var label := loading.find_child("Label", true, false) as Label
		if label != null:
			label.text = "Spawning..."

	player.update_last_basis()
	player.active = true  # take control now; _process starts orienting the body + updating the sun

	# Hold the splash a short minimum (so the world DRAWS behind it — there is no client terrain-ready
	# signal) AND until the sun's day/night + the body orientation have settled (gravity resolved, up
	# steady). Capped by a timeout so a stuck spawn never hangs.
	var waited: float = 0.0
	while (waited < 2.5 or player.get_current_gravity_parent() == null or not sun.settled) and waited < 10.0:
		await get_tree().process_frame
		waited += get_process_delta_time()

	# Initial visibility from the saved setting (default true — early alpha).
	player._display_debug = SettingsManager.is_show_debug()
	player.display_debug.emit(player._display_debug)

	if loading != null:
		loading.queue_free()

	GameOrchestrator.stop_menu_music()

## Per-frame client work: REMOTE avatar interpolation + name tag, or the OWNER's seat ride / camera /
## HUD prompts / mouse capture / input sampling. Runs on this role's own child node, so the engine
## calls it only on a client (never the dedicated server). Reaches the shared body through `player`.
func _process(_delta: float) -> void:
	_sample_locomotion(_delta)  # one shared computation for the footsteps AND the puppet animator
	_update_footsteps(_delta)  # own body AND remote avatars: everyone hears everyone walk
	if player.remote_player:
		player._interp.update(player, _delta)  # entity interpolation: glide between server updates
		_update_name_tag()
		return
	# Seated in a vehicle: ride the seat HERE, in sync with the vehicle's own _process
	# interpolation, so the camera stays glued to the (smoothly moving) cabin — no jitter/blur.
	if is_instance_valid(player._seat_node):
		player._ride_seat(player._seat_node)
		_replicate_look()  # seated: the body is locked, so send pitch+yaw for the remote head-look
		# Seated: clear the on-foot prompts, but still let a driver/passenger close (or reopen) a door by
		# LOOKING at its handle — the handle rides the door now, so aiming works open or closed.
		player.interact_label.hide()
		var seated_handle = _aimed_door_handle()
		if seated_handle != null:
			player.interact_label.text = _door_prompt(seated_handle)
			player.interact_label.show()
		return
	# On foot: smooth our server-driven position (no client prediction yet) — position only, so
	# the mouse look stays immediate.
	player._interp.update_position(player, _delta)
	if !player.active:
		player.interact_label.hide()
		return

	# Free the mouse + freeze the camera whenever the player isn't in direct control: focused on a
	# 3D screen, the spawn wheel, OR the pause menu is open. Otherwise capture the mouse and move the
	# camera. (Without the pause case, this would re-capture every frame and hide the menu cursor.)
	var ui_focus: bool = _ui_focus()

	# Mining (aim, perforation, head sync) runs in the MiningTool — but ONLY while in direct control, so
	# you can't aim or drill while a menu/wheel is up (its polled input would otherwise fire while paused,
	# and a held click would keep the tool engaged). Entering a menu cancels any in-progress action.
	if ui_focus:
		player.mining_tool.cancel()
	else:
		player.mining_tool.update_local(_delta)
		if player.mining_tool.is_aiming:
			player.mouse_motion *= player.mining_tool.aim_sensitivity_factor
		if player.mining_tool.is_perforating:
			player.mouse_motion = Vector2.ZERO  # mouse frozen during perforation

	if ui_focus:
		# Guarded like the CAPTURED branch below: entering CAPTURED warps the cursor to the window
		# centre, so the transitions are what must stay rare — and the embedded game window reports a
		# mode of its own, which makes an unguarded write per frame worth avoiding.
		if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		player.mouse_motion = Vector2.ZERO
		# Turn the camera toward a 3D screen so it's centered in view.
		if player.screen_interacting is Node3D:
			_face_screen(player.screen_interacting)
	else:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		# Return the camera to the pivot's control after a screen interaction.
		player.camera.rotation = player.camera.rotation.lerp(Vector3.ZERO, 0.2)
		_handle_camera_motion()


	player.interact_label.hide()
	player.can_interact = false
	if player.interact_ray.is_colliding():
		var collider = player.interact_ray.get_collider()
		if collider:
			if collider.has_method("interact"):
				player.interact_label.text = collider.label
				player.interact_label.show()
				player.can_interact = true
				# Polled, so it fires straight from the Input singleton: without this guard it
				# triggered behind the pause menu and while typing in the chat.
				if not ui_focus and Input.is_action_just_pressed("interact"):
					collider.interact(player)
					player.interact_label.hide()

	# Looking at a door handle, FROM the boarding zone (on foot) or while seated: E opens/closes it.
	# Priority over the seat prompt, so aiming at the handle in the zone shows the door action.
	if not player.interact_label.visible and (is_instance_valid(player._nearby_seat) or player._seat_vehicle_uuid != ""):
		var aimed_handle = _aimed_door_handle()
		if aimed_handle != null:
			player.interact_label.text = _door_prompt(aimed_handle)
			player.interact_label.show()

	# Standing in a seat box (on foot): board, or say it's taken / that the door must be opened first.
	if not player.interact_label.visible and is_instance_valid(player._nearby_seat) and player._seat_vehicle_uuid == "":
		if _seat_is_taken(player._nearby_seat):
			player.interact_label.text = "Driver seat taken"
		elif not _seat_door_open(player._nearby_seat):
			player.interact_label.text = "Open the door first (aim at the handle)"
		else:
			player.interact_label.text = "[E] Drive Seat" if player._nearby_seat.is_driver_seat() else "[E] Passenger Seat"
		player.interact_label.show()

	# Carry/drop prompt (no other prompt showing). The SERVER decides it (it owns the collisions
	# and re-checks reachability + line of sight) and replicates _carry_prompt; we only display.
	if not player.interact_label.visible:
		if player._carry_prompt == "drop":
			player.interact_label.text = "[E] Drop"
			player.interact_label.show()
		elif player._carry_prompt == "cargo":
			player.interact_label.text = "[E] Cargo"  # dropping here loads it onto the truck (sticks)
			player.interact_label.show()
		elif player._carry_prompt == "carry":
			player.interact_label.text = "[E] Carry"
			player.interact_label.show()


	var dir_vect = Vector3.ZERO


	if not _input_locked():  # covers the pause menu, an open wheel AND the chat (see _input_locked)
		dir_vect = Input.get_vector(player.MOVE_LEFT, player.MOVE_RIGHT, player.MOVE_FORWARD, player.MOVE_BACK)

	if dir_vect:
		player.input_direction = dir_vect
	else:
		player.input_direction = Vector2.ZERO

	# send move_direction
	# if input_direction != client_last_input_direction or global_rotation != client_last_global_rotation:
	# 	client_last_input_direction = input_direction
	# 	client_last_global_rotation = global_rotation
	# 	emit_signal("hs_client_action_move", input_direction, global_rotation)
	player.update_last_basis()

	player.labelx.text = str("%0.2f" % player.global_position[0])
	player.labely.text = str("%0.2f" % player.global_position[1])
	player.labelz.text = str("%0.2f" % player.global_position[2])

## Fixed-step OWNER input sampling: relay drive input while seated, else sample walking input and
## emit the move only on change. Runs on this role's own child node → only on a client (never the
## server); the remote guard keeps a replicated avatar from sampling local input.
func _physics_process(delta: float) -> void:
	if player.remote_player: return
	# CLIENT-OWNER: the seated camera ride is done in _process; here we only relay drive input.
	if is_instance_valid(player._seat_node):
		# Seated: relay drive input (driver only) and skip walking.
		if player._seat_is_driver:
			_send_drive_input()
			_update_handbrake_input(delta)
		return
	if !player.active: return

	# Pause menu or a radial wheel is open: the owner is not in direct control -> don't move or act.
	# We still fall through so input_direction becomes ZERO and a single "stop" is emitted to the server.
	var input_locked: bool = _input_locked()
	var dir_vect = Vector3.ZERO


	if not input_locked:  # covers the pause menu, an open wheel AND the chat (see _input_locked)
		dir_vect = Input.get_vector(player.MOVE_LEFT, player.MOVE_RIGHT, player.MOVE_FORWARD, player.MOVE_BACK)

	if dir_vect:
		player.input_direction = dir_vect
	else:
		player.input_direction = Vector2.ZERO
	# send move_direction
	# Send the body's LOCAL rotation (relative to the planet), not global: the planet spins on the client
	# but is static on the server, so a world-frame rotation would be applied in the wrong frame and tilt
	# the body. Local rotation is frame-invariant — same convention as the local position above.
	var short_rotation = snapped(player.rotation, Vector3(0.0001, 0.0001, 0.0001))
	if player.input_direction != player.client_last_input_direction or short_rotation != player.client_last_global_rotation:
		player.client_last_input_direction = player.input_direction
		player.client_last_global_rotation = short_rotation
		player.emit_signal("hs_client_action_move", player.input_direction, short_rotation)
	player.update_last_basis()

	# Sprint (Shift held) is server-authoritative: send only when it changes (replicate what changes).
	var sprint_held: bool = Input.is_action_pressed(player.SPRINT) and not input_locked
	if sprint_held != _sprint_sent:
		_sprint_sent = sprint_held
		player.client_send_action_to_server({"action": "sprint", "held": sprint_held})

	# Crouch / prone are TOGGLES, server-authoritative: each press cycles standing <-> that stance. The
	# server owns `stance`; we only request the change (from the last echoed value) and apply the reply.
	if not input_locked:
		if Input.is_action_just_pressed("crouch"):
			player.client_send_action_to_server({"action": "stance", "value": 0 if player.stance == 1 else 1})
		elif Input.is_action_just_pressed("prone"):
			player.client_send_action_to_server({"action": "stance", "value": 0 if player.stance == 2 else 2})

	player.labelx.text = str("%0.2f" % player.global_position[0])
	player.labely.text = str("%0.2f" % player.global_position[1])
	player.labelz.text = str("%0.2f" % player.global_position[2])

## Owner: send our driving input to the server (only when it changes; the server holds it).
func _send_drive_input() -> void:
	var throttle: float = Input.get_axis("move_back", "move_forward")
	var steer: float = Input.get_axis("move_right", "move_left")
	var braking: bool = Input.is_action_pressed("brake")
	if throttle == player._last_throttle and steer == player._last_steer and braking == player._last_brake:
		return
	player._last_throttle = throttle
	player._last_steer = steer
	player._last_brake = braking
	player.client_send_action_to_server({
		"action": "vehicle_input",
		"target_uuid": player._seat_vehicle_uuid,
		"throttle": throttle,
		"steer": steer,
		"brake": braking,
	})

## Driver: a long press on the brake key at low speed toggles the hand brake (once per hold).
func _update_handbrake_input(delta: float) -> void:
	if not Input.is_action_pressed("brake"):
		player._space_held_time = 0.0
		player._handbrake_sent = false
		return
	player._space_held_time += delta
	if player._handbrake_sent or player._space_held_time < player.HANDBRAKE_HOLD_SECS:
		return
	var speed_kmh: float = 999.0
	if is_instance_valid(player._seat_vehicle_node) and player._seat_vehicle_node.has_method("get_display_speed_kmh"):
		speed_kmh = player._seat_vehicle_node.get_display_speed_kmh()
	if speed_kmh > player.HANDBRAKE_MAX_KMH:
		return
	player._handbrake_sent = true
	player.client_send_action_to_server({"action": "vehicle_handbrake", "target_uuid": player._seat_vehicle_uuid})

## Driver: the horn is HELD, so both edges are sent and the server replicates the state (everyone
## around hears it). Two horns share the key: "vehicle_horn" (H) and "vehicle_horn_special" (Alt+H).
## The presses are matched exactly (exact_match), or Alt+H would fire the plain horn too. The release
## is matched loosely on purpose: letting go while Alt changed state must never leave the horn stuck.
func _send_horn_input(event: InputEvent) -> void:
	var special: bool = event.is_action_pressed("vehicle_horn_special", false, true)
	var pressed: bool = special or event.is_action_pressed("vehicle_horn", false, true)
	var released: bool = event.is_action_released("vehicle_horn") \
			or event.is_action_released("vehicle_horn_special")
	if not pressed and not released:
		return
	player.client_send_action_to_server({
		"action": "vehicle_horn",
		"target_uuid": player._seat_vehicle_uuid,
		"pressed": pressed,
		"special": special,
	})

## Ease the camera round to face a 3D screen (mining depot…) while we are using it.
##
## Everything is done in the camera's LOCAL frame, on purpose. Writing camera.global_transform — what
## this used to do — nails the camera to a point in WORLD space: Godot turns the global transform we
## hand it back into a local one relative to a parent that MOVES (the planet, at ~3e10). Re-writing the
## same global origin every frame therefore keeps the camera at a fixed point of the universe while the
## planet — and the player with it — flies away: within seconds the view is billions of metres behind,
## staring at the sun, while the body still walks around normally for everybody else.
## Rotating the LOCAL transform never touches the camera's position: it stays in the player's eyes.
##
## The target is read LIVE from the screen node, never stored: the planet spins, so a world position
## snapshotted on approach drifts away from the screen it was meant to point at (hundreds of metres
## per spin step), and the camera then chases a ghost that keeps receding — it never settles, which
## also kept the physics picking re-firing and made the pointer wander across the screen's UI.
## Stops once the camera is aimed within FACE_SCREEN_EPSILON: without that it re-aimed every frame.
func _face_screen(screen: Node) -> void:
	var pivot: Node3D = player.camera.get_parent() as Node3D
	if pivot == null:
		return
	# The screen tells us where to look (its surface sits metres away from the object's origin);
	# anything that does not care is simply looked at directly.
	var target: Node3D = screen.screen_look_target() if screen.has_method("screen_look_target") else screen as Node3D
	if target == null:
		return
	var target_local: Vector3 = pivot.to_local(target.global_position)
	var up_local: Vector3 = pivot.global_basis.inverse() * player.up_direction
	if target_local.is_equal_approx(player.camera.position) or up_local.is_zero_approx():
		return
	# Converged? The camera looks down its own -Z; compare that to the direction of the screen.
	var to_screen: Vector3 = (target_local - player.camera.position).normalized()
	if -player.camera.transform.basis.z.normalized().dot(to_screen) >= FACE_SCREEN_EPSILON:
		return
	var look: Transform3D = player.camera.transform.looking_at(target_local, up_local)
	player.camera.transform = player.camera.transform.interpolate_with(look, 0.15)

## Owner camera + body orientation per frame: align to gravity (planet or 0g), apply the mouse look,
## and replicate the camera pitch ("head") to the server. Called from _process. Acts on the BODY, so
## the transform ops (global_basis / rotate_object_local) go through player, not this role node.
func _handle_camera_motion() -> void:
	var parent_gravity_area: Area3D = player.gravity_parents.back() if not player.gravity_parents.is_empty() else null

	# While carrying, holding the free-rotate button (middle mouse) makes the mouse tumble the CARRIED
	# object on all axes instead of moving the view (this is in addition to the wheel's single-axis
	# notch). Server-authoritative: we only stream the motion; the server owns the held body. Zero the
	# look for this frame so the camera stays put.
	var look: Vector2 = player.mouse_motion
	if player._owner_carrying and Input.is_action_pressed("carry_free_rotate"):
		if player.mouse_motion != Vector2.ZERO:
			player.client_send_action_to_server({
				"action": "carry_free_rotate",
				"dx": player.mouse_motion.x,
				"dy": player.mouse_motion.y,
			})
		look = Vector2.ZERO

	if parent_gravity_area:
		player._no_gravity_time = 0.0
		if parent_gravity_area.gravity_point:
			player.up_direction = parent_gravity_area.global_position.direction_to(player.global_position)
		else:
			player.up_direction = parent_gravity_area.global_basis.y

		player.gravity = player._compute_gravity(parent_gravity_area)
		player.orient_player()
		player.global_basis = player.global_basis.rotated(player.global_basis.y, look.x * player.camera_sensitivity)
		player.camera_pivot.rotate_object_local(Vector3.RIGHT, look.y * player.camera_sensitivity)
		player.camera_pivot.rotation_degrees.x = clamp(player.camera_pivot.rotation_degrees.x, -80, 80)
	else:
		# No gravity area. Ignore a brief gap (e.g. a reparent leaving a spawn apartment) — only treat
		# it as real 0g after ZERO_G_GRACE, so the camera pitch survives the transition.
		player._no_gravity_time += player.get_process_delta_time()
		if player._no_gravity_time >= player.ZERO_G_GRACE:
			# 0g movement
			player.gravity = 0.0
			player.camera_pivot.rotation.x = 0
			player.rotate_object_local(Vector3.UP, look.x * player.camera_sensitivity)
			player.rotate_object_local(Vector3.RIGHT, look.y * player.camera_sensitivity)

	_replicate_look()  # send pitch (+ seated yaw) so others aim the tool + tilt the head where we look

	player.mouse_motion = Vector2.ZERO

## Replicate the look to the server, throttled: pitch ("head") always, and yaw ("head_yaw") which is 0
## while standing (the body carries the yaw) but non-zero while seated (the body is locked, so the camera
## pivot turns instead). Called both on foot (_handle_camera_motion) AND seated (_ride_seat path), so a
## seated avatar's head-look reaches remotes — the seated branch returns before the on-foot camera code.
func _replicate_look() -> void:
	var head_q := snappedf(player.camera_pivot.rotation.x, 0.02)
	if head_q != player._last_head_sent:
		player._last_head_sent = head_q
		player.client_send_action_to_server({"action": "update_property", "head": head_q})
	var head_yaw_q := snappedf(player.camera_pivot.rotation.y, 0.02)
	if head_yaw_q != player._last_head_yaw_sent:
		player._last_head_yaw_sent = head_yaw_q
		player.client_send_action_to_server({"action": "update_property", "head_yaw": head_yaw_q})

func _unhandled_input(event: InputEvent) -> void:
	if player.remote_player: return
	# Pause menu (Esc) is a hard modal: ignore EVERY player input — seated controls, radial wheels,
	# jump, torch, interaction… Nothing below runs while it is up. (Movement/camera are gated the
	# same way in _physics_process / _process via _input_locked / _ui_focus.)
	# The chat is gated the same way: the LineEdit swallows most keys, but not all of them, and
	# nothing the player types should ever reach gameplay. (NOT _input_locked() here — that one also
	# covers an open wheel, whose press/release lifecycle _handle_radial_wheels still needs to see.)
	if _menu_open() or _chat_writing(): return
	# Leave the seat we occupy (driver or passenger) with Y — but only if this seat's door is open
	# (open it first by looking at its handle). A seat with no door_id leaves directly.
	if player._seat_vehicle_uuid != "" and event.is_action_pressed("exit"):
		if _seat_door_open(player._seat_node):
			_leave_vehicle()
		return

	if player._seat_is_driver and player._seat_vehicle_uuid != "" and event.is_action_pressed("vehicle_reset"):
		# Reset the vehicle upright (server-authoritative; driver only).
		player.client_send_action_to_server({"action": "reset_vehicle", "target_uuid": player._seat_vehicle_uuid})

	if player._seat_is_driver and player._seat_vehicle_uuid != "":
		_send_horn_input(event)

	if player._seat_is_driver and player._seat_vehicle_uuid != "" and event.is_action_pressed("vehicle_ignition"):
		# Start / cut the engine (server-authoritative; driver only, and only standing still).
		player.client_send_action_to_server({"action": "vehicle_ignition", "target_uuid": player._seat_vehicle_uuid})

	if player._seat_is_driver and player._seat_vehicle_uuid != "" and event.is_action_pressed("vehicle_lights"):
		# Toggle the vehicle head lights (server-authoritative; driver only).
		player.client_send_action_to_server({"action": "vehicle_lights", "target_uuid": player._seat_vehicle_uuid})

	if event.is_action_pressed("toggle_flashlight"):
		# Toggle the player's torch — on foot AND while seated (driver or passenger), so it must
		# sit before the walk guard. By default it shares the L key with vehicle_lights, so one
		# press toggles both the torch and the head lights; rebind it to a separate key in
		# Settings > Controls to control the torch independently.
		player.client_send_action_to_server({"action": "toggle_flashlight"})

	if event.is_action_pressed("toggle_eva"):
		# EVA (dev free-flight): just request the toggle; the server owns the state and flies the body
		# (movement is server-authoritative). Sits before the walk guard so it works in any state.
		player.client_send_action_to_server({"action": "toggle_eva"})

	# Mouse wheel spins a CARRIED object around its vertical axis, so you can orient a crate before
	# dropping it. Server-authoritative (it owns the held body): we only send the step. Gated on
	# actually carrying so the wheel is free for other uses otherwise.
	if player._owner_carrying:
		if event.is_action_pressed("carry_rotate_cw"):
			player.client_send_action_to_server({"action": "carry_rotate", "dir": 1})
		elif event.is_action_pressed("carry_rotate_ccw"):
			player.client_send_action_to_server({"action": "carry_rotate", "dir": -1})
	elif event.is_action_pressed("walk_speed_up") or event.is_action_pressed("walk_speed_down"):
		# GDD: the mouse wheel sets the walk speed (0.5-3 m/s, 0.5 steps). Server-authoritative — we send
		# the new target; the server clamps and applies it. (Carrying uses the wheel to rotate, above.)
		var step: float = player.walk_speed_step if event.is_action_pressed("walk_speed_up") else -player.walk_speed_step
		_walk_speed_target = clampf(_walk_speed_target + step, player.walk_speed_min, player.walk_speed_max)
		player.walk_speed_target = _walk_speed_target  # mirror for the debug HUD
		player.client_send_action_to_server({"action": "walk_speed", "value": _walk_speed_target})

	# Capture mouse look even while seated (free look in a vehicle), before the walk guard. Never while a
	# menu/wheel/screen has focus — so a held click + Esc can't keep steering the camera behind the menu.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not _ui_focus():
		player.mouse_motion = -event.relative * 0.001

	# Seated (driver/passenger): E open/closes a door by LOOKING at its handle. Must run BEFORE the
	# walk guard — seated players have player.active = false, so the on-foot action block below never runs.
	if player._seat_vehicle_uuid != "" and event.is_action_pressed("action"):
		player.interact_ray.force_raycast_update()
		var seated_handle = _aimed_door_handle()
		if seated_handle != null:
			_toggle_door(seated_handle)
		return  # seated: E only operates doors, never carry

	if !player.active: return

	# On foot. Radial wheels (emote on T, spawn on Alt+T) own their open+confirm lifecycle, so we
	# service them first, then swallow every other on-foot action while one is open.
	_handle_radial_wheels(event)
	if _any_wheel_open(): return

	if event.is_action_pressed(JUMP):
		player.client_send_action_to_server({"action": JUMP})

	if event.is_action_pressed("toggle_tool"):
		if player.admin_cleanup_tool != null:
			player.admin_cleanup_tool.set_active(false)  # stow the admin tool when equipping the perforator
		player.mining_tool.toggle_equip()

	if event.is_action_pressed("action"):
		player.interact_ray.force_raycast_update()
		# On foot, looking at a door handle from a boarding zone: open/close that door (server-auth).
		# Priority over boarding, so aiming at the handle in the zone operates the door.
		var handle = _aimed_door_handle()
		if handle != null and is_instance_valid(player._nearby_seat):
			_toggle_door(handle)
			return
		# Standing in a seat box: E boards — but only once the seat's gating door is open (open it
		# first by looking at the handle). A seat with no door_id boards directly.
		if is_instance_valid(player._nearby_seat):
			if _seat_door_open(player._nearby_seat):
				_enter_seat(player._nearby_seat)
			return
		# Otherwise pick up / drop. Send the uuid of the carriable under OUR crosshair so the
		# server grabs exactly that one (its own ray can be slightly off and grab a neighbour).
		var aim = player._aimed_carriable()
		var target_uuid := str(aim.uuid) if aim != null else ""
		player.client_send_action_to_server({"action": "action", "target_uuid": target_uuid})
		_predict_carry_stow(aim)

	if event.is_action_pressed("toggle_debug"):
		player._display_debug = not player._display_debug
		player.display_debug.emit(player._display_debug)
		SettingsManager.set_show_debug(player._display_debug)  # persist + keep the settings menu in sync

## True when the seat is occupied (E won't work). Only the DRIVER seat's occupancy is
## replicated (via the vehicle's pilot_uuid); a passenger seat reads as free for now.
## True if this seat is occupied (by someone other than us) — driver AND passenger, one system: the
## server replicates per-seat occupancy into the vehicle's _net_seats (see Vehicle._seat_occupancy_now).
func _seat_is_taken(seat: Node) -> bool:
	if seat == null:
		return false
	var veh: Node = seat.vehicle() if seat.has_method("vehicle") else null
	if veh == null or not ("_net_seats" in veh):
		return false
	var occupant: String = str(veh._net_seats.get(str(seat.name), ""))
	return occupant != "" and occupant != str(player.client_uuid)

## Take the seat we are standing in: tell the server, lock walking, start riding locally.
func _enter_seat(seat: Node) -> void:
	var veh: Node = seat.vehicle()
	if veh == null or not ("uuid" in veh):
		return
	if _seat_is_taken(seat):
		return  # driver seat already occupied (server-replicated) — don't enter optimistically
	player._seat_node = seat
	player._seat_vehicle_node = veh
	player._seat_vehicle_uuid = str(veh.uuid)
	player._seat_is_driver = seat.is_driver_seat()
	player.seated_role = "driver" if seat.is_driver_seat() else "passenger"  # drives the sit/drive pose
	player.client_send_action_to_server({
		"action": "enter_vehicle",
		"target_uuid": player._seat_vehicle_uuid,
		"seat": seat.name,
	})
	player.active = false  # lock walking while seated
	player.set_seated(true)
	# Ride by transform inheritance: parent to the vehicle so we move WITH it (no jitter). The
	# vehicle stays server-authoritative; this is the local camera ride.
	if veh is Node3D and player.get_parent() != veh:
		player.reparent(veh)
		player.net_reset_interp()
	if player._seat_is_driver and veh.has_method("set_driver_hud"):
		veh.set_driver_hud(true)

## Leave the seat we occupy (driver or passenger): walk again, un-parent back into the world, and drop
## the driver HUD. Triggered by Y (exit) — see _unhandled_input. `notify_server` is false when the server
## itself told us to leave (a refused seat: occupied/blocked), so we must NOT echo an exit back.
func _leave_vehicle(notify_server: bool = true) -> void:
	if notify_server:
		player.client_send_action_to_server({"action": "exit_vehicle", "target_uuid": player._seat_vehicle_uuid})
	player.active = true  # walking again
	player.set_seated(false)
	player.camera_pivot.rotation = Vector3.ZERO  # restore walking look (yaw goes back on the body)
	# Un-parent from the vehicle, back into the world (the server repositions us beside it).
	if is_instance_valid(player._seat_vehicle_node) and player.get_parent() == player._seat_vehicle_node:
		var world: Node = player._seat_vehicle_node.get_parent()
		if world != null:
			player.reparent(world)
			player.net_reset_interp()
	if player._seat_is_driver and is_instance_valid(player._seat_vehicle_node) \
			and player._seat_vehicle_node.has_method("set_driver_hud"):
		player._seat_vehicle_node.set_driver_hud(false)
	player._seat_vehicle_uuid = ""
	player._seat_vehicle_node = null
	player._seat_node = null
	player._seat_is_driver = false
	player.seated_role = ""  # back on foot -> normal locomotion pose

## The vehicle door handle under the crosshair (a VehicleDoorHandle Area3D on the interact layer),
## or null. Look-at detection; the actual open/close is server-authoritative (sent on E).
func _aimed_door_handle() -> VehicleDoorHandle:
	if not player.interact_ray.is_colliding():
		return null
	var hit = player.interact_ray.get_collider()
	var handle := hit as VehicleDoorHandle
	if handle == null:
		return null
	# Only the box on our current side counts: outdoor on foot, indoor when seated in this vehicle.
	# Aiming at the far-side box (the one you can't reach from where you are) is ignored.
	if not _door_side_matches(handle):
		return null
	return handle

## True when the handle box under the crosshair is on the player's side (outdoor on foot, indoor when
## seated in that vehicle). "" side (no boxes assigned) always matches, so an un-configured handle works.
func _door_side_matches(handle: VehicleDoorHandle) -> bool:
	var side := handle.aimed_side(player.interact_ray.get_collision_point())
	if side == "":
		return true
	var veh = handle.vehicle()
	var inside: bool = veh != null and "uuid" in veh and player._seat_vehicle_uuid == str(veh.uuid)
	return side == ("indoor" if inside else "outdoor")

## Tell the server to open/close the door this handle drives (server-authoritative, replicated back).
func _toggle_door(handle: VehicleDoorHandle) -> void:
	var veh = handle.vehicle()
	if veh == null:
		return
	player.client_send_action_to_server({
		"action": "vehicle_door",
		"target_uuid": str(veh.uuid),
		"door_id": handle.door_id,
		"side": handle.aimed_side(player.interact_ray.get_collision_point()),
	})

## Prompt for a door handle under the crosshair: close it if open, else open it.
func _door_prompt(handle: VehicleDoorHandle) -> String:
	var veh = handle.vehicle()
	var is_open: bool = veh != null and veh.has_method("is_door_open") and veh.is_door_open(handle.door_id)
	return "[E] Close door" if is_open else "[E] Open door"

## True if a seat may be boarded right now: it has no gating door, or its door_id is currently open.
## Lets a vehicle require "open the door first" before E enters (the door is opened via its handle).
func _seat_door_open(seat) -> bool:
	if seat == null or not ("door_id" in seat) or str(seat.door_id) == "":
		return true
	var veh = seat.vehicle()
	if veh == null or not veh.has_method("is_door_open"):
		return true
	return veh.is_door_open(str(seat.door_id))

## TEMPORARY (until the planet sun/atmosphere system is fixed): build a physical-sky environment
## directly on the player camera. A Camera3D's own environment overrides any rival WorldEnvironment
## (the scene's WorldEnvironment doesn't apply in-game here -> black sky), so this is what reliably
## shows the sky to every player. The PhysicalSky reacts to the DirectionalLight, so the day/night
## sun tint applies. Keep these values in sync with the WorldEnvironment in sandbox_capital.tscn.
## Remove this whole helper once the real sun/atmosphere system is in place.
func _force_temp_sky_environment() -> void:
	# LOCAL-frame sky shader instead of Godot's PhysicalSkyMaterial: the physical sky measures day/night
	# and the horizon against WORLD axes, which is meaningless on a planet at ~3e10 (local up != world +Y)
	# and left the sky black even in local daytime. local_sky.gdshader computes from local_up + to_star,
	# both pushed each frame by PlayerSunLight._apply_night_sky. Still the TEMPORARY sky (real atmosphere
	# replaces it), and it still feeds ambient + reflections, so night goes genuinely dark.
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load("res://scenes/player/local_sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.glow_enabled = true
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.002
	# Set it on the WORLD, not on player.camera, so EVERY camera in this world renders the local sky —
	# including the vehicle mirror / reverse-cam SubViewports (RearCamera), which share get_world_3d() and
	# have no Environment of their own. PlayerSunLight pushes the sky uniforms to this one shared material
	# each frame, so all views (main + mirrors) stay in step. EYEDIR makes each render from its own angle.
	player.get_world_3d().environment = env

## Live camera FOV update from the settings menu (local player only).
func _on_fov_changed(fov: float) -> void:
	player.camera.fov = fov

## Live update from the settings menu "Show debug panels" toggle (kept in sync with the toggle_debug key).
func _on_show_debug_changed(on: bool) -> void:
	player._display_debug = on
	player.display_debug.emit(on)

# Dev spawn wheel selection -> spawn the chosen prop in front of the player.
## A wheel entry was picked: just NAME it to the server. Everything else — which scene, which object
## type, where it lands, which celestial frame it belongs to — is decided server-side, from the same
## catalogue (see PlayerServer's "spawn_prop"). The client used to compute the position itself, mixing
## its LOCAL position with WORLD axes, so the prop flew off in a skewed direction on a rotated parent;
## and it named the scene, which let any tampered client instance anything anywhere.
func _on_spawn_selected(key) -> void:
	player.client_send_action_to_server({"action": "spawn_prop", "key": str(key)})

func _on_emote_selected(key) -> void:
	player.client_send_action_to_server({"action": "emote", "key": str(key)})

## True while a radial menu (spawn OR emote) is open: the camera freezes and the cursor shows so you can
## move the mouse to reach its items (see _process). One check for both wheels (DRY).
func _any_wheel_open() -> bool:
	return (player._spawn_wheel != null and player._spawn_wheel.visible) \
		or (player._emote_wheel != null and player._emote_wheel.visible)

## Open/confirm the radial wheels: emote on T, spawn on Alt+T. Called before the wheel lock in
## _unhandled_input so a wheel that is up still confirms on release. One place for both wheels (DRY).
## Both actions sit on the same T key and differ ONLY by Alt, but an action match ignores modifiers:
## a bare T matches Alt+T too. So Alt decides which wheel may open — SYMMETRICALLY. Only the emote
## side used to be guarded, which is why a bare T also opened the spawn wheel (hidden underneath) and
## releasing T spawned whatever sat under the cursor.
func _handle_radial_wheels(event: InputEvent) -> void:
	var alt_held: bool = event is InputEventKey and event.alt_pressed
	_service_wheel(event, "emote_wheel", player._emote_wheel, EmoteCatalog.build_wheel, not alt_held)
	_service_wheel(event, "spawn_wheel", player._spawn_wheel, SpawnCatalog.build_wheel, alt_held)

## Hold-to-open / release-to-confirm lifecycle of ONE wheel. `build` supplies the entries (labels +
## keys come from the catalogue) and is only called when the wheel actually opens, so the catalogue
## is not rebuilt on every input event. `may_open` carries the Alt discrimination above.
## The release is matched loosely (no exact_match) on purpose: letting go of Alt before T yields a
## release event with no Alt, which an exact match would drop and leave the spawn wheel stuck open.
## The `visible` check is what keeps a release from confirming a wheel that never opened — its press
## swallowed by a menu, a seat or an inactive player — and re-emitting a stale selection.
func _service_wheel(
	event: InputEvent, action: StringName, wheel: RadialMenu, build: Callable, may_open: bool
) -> void:
	if wheel == null:
		return
	if may_open and event.is_action_pressed(action):
		wheel.open(build.call())
	elif event.is_action_released(action) and wheel.visible:
		wheel.confirm()

## The pause menu (Esc) is open: a HARD modal — the game must ignore ALL player input (seated
## controls, radial wheels, jump, interaction…). Checked once at the top of _unhandled_input.
func _menu_open() -> bool:
	return GameOrchestrator.current_state == GameOrchestrator.GameStates.PAUSE_MENU

## The local player is typing in the chat: the keyboard belongs to the text field, not to gameplay.
## This MUST be part of the input lock, because most gameplay reads POLL the Input singleton
## (Input.is_action_just_pressed), which the focused LineEdit cannot consume — the OS keeps feeding
## it, so typing "crouch" used to actually crouch. Only event handlers (_unhandled_input) are
## shielded by the GUI swallowing the key.
func _chat_writing() -> bool:
	return player.direct_chat != null and player.direct_chat.can_write

## Player input is locked: the pause menu is up, a radial wheel is open, OR the chat has the
## keyboard. No movement and no action fires (see _physics_process / _unhandled_input). A 3D screen
## does NOT lock input — you leave it by walking out of its zone, so movement must stay available
## while facing one.
func _input_locked() -> bool:
	return _menu_open() or _any_wheel_open() or _chat_writing()

## The mouse/camera is taken over: input is locked (menu/wheel) OR the camera is facing a 3D screen.
## Frees the cursor and freezes the look (see _process). One source.
func _ui_focus() -> bool:
	return player.screen_interacting != null or _input_locked()

# LOCAL DEV (do not commit): spawn a mining depot a few meters in front of the player.
func _spawn_depot() -> void:
	var spawn_pos: Vector3 = player.position + (-player.global_basis.z * 10.0)
	var parent = player.get_parent()
	# Robust to the scene layout: any parent without a uuid (SystemSandbox, a grouping node) = "".
	var parentuuid = str(parent.uuid) if "uuid" in parent else ""
	player.emit_signal(
		"client_action_requested",
		{
			"action": "spawn",
			"entity": "mining_depot",
			"position": {"x": spawn_pos.x, "y": spawn_pos.y, "z": spawn_pos.z},
			"scenename": "scenes/structures/mining_depot.tscn",
			"parent_id": parentuuid,
		}
	)

func spawn_box(_boxscene: String, _type: String, _coeffz: float, _coeffy: float):
	# LOCAL DEV (do not commit): re-enabled to spawn mining rocks for testing.
	var item_spawn_position: Vector3 = player.position + (-player.global_basis.z * _coeffz) + player.global_basis.y * _coeffy
	var parent = player.get_parent()
	# Robust to the scene layout: any parent without a uuid (SystemSandbox, a grouping node) = "".
	var parentuuid = str(parent.uuid) if "uuid" in parent else ""
	player.emit_signal(
		"client_action_requested",
		{
			"action": "spawn",
			"entity": _type,
			"position": {
				"x": item_spawn_position[0],
				"y": item_spawn_position[1],
				"z": item_spawn_position[2]
			},
			"scenename": "scenes/props/" + _boxscene + ".tscn",
			"parent_id": parentuuid,
		}
	)

## Build the 2D screen-space name tag for a remote player. A CanvasLayer keeps it in screen space
## (immune to the 3D camera), and _update_name_tag positions it over the head every frame. The tag
## and its layer are children of the BODY (player), so they follow it and free with it.
func _setup_name_tag(player_name: String) -> void:
	var layer := CanvasLayer.new()
	player.add_child(layer)
	_name_tag = Label.new()
	_name_tag.text = player_name
	_name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_tag.add_theme_font_size_override("font_size", 15)
	_name_tag.add_theme_color_override("font_outline_color", Color.BLACK)
	_name_tag.add_theme_constant_override("outline_size", 6)
	_name_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_name_tag)

func _setup_conversation_text() -> void:
	var layer := CanvasLayer.new()
	player.add_child(layer)
	_conversation_text = Label.new()
	_conversation_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_conversation_text.add_theme_font_size_override("font_size", 15)
	_conversation_text.add_theme_color_override("font_color", Color.GREEN)
	_conversation_text.add_theme_color_override("font_outline_color", Color.BLACK)
	_conversation_text.add_theme_constant_override("outline_size", 6)
	_conversation_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_conversation_text.visible = false  # nothing said yet
	layer.add_child(_conversation_text)
	# Italic, by slanting the label's OWN font rather than swapping in Poppins-Italic: this keeps the
	# same typeface as the name tag above it and only leans the glyphs. Same slant as the other UI
	# (see rock_depot_ui.tscn). Done after add_child so the theme lookup sees the real inherited font.
	var italic := FontVariation.new()
	italic.base_font = _conversation_text.get_theme_font("font")
	italic.variation_transform = Transform2D(Vector2(1.0, 0.415), Vector2(0.0, 1.0), Vector2.ZERO)
	_conversation_text.add_theme_font_override("font", italic)

## Project the head position to the screen (CPU, double precision) and place the 2D tag there,
## centered over the head and hidden when the player is behind the camera.
func _update_name_tag() -> void:
	if _name_tag == null:
		return
	var cam := get_viewport().get_camera_3d()
	var head: Vector3 = player.global_position + player.global_transform.basis.y * 2.2
	# Hide when behind the camera or farther than the cutoff (too far to read anyway).
	if cam == null or cam.is_position_behind(head) \
			or player.global_position.distance_to(cam.global_position) > NAME_TAG_MAX_DISTANCE:
		_name_tag.visible = false
		if _conversation_text != null:
			_conversation_text.visible = false
		return
	_name_tag.visible = true
	_name_tag.position = cam.unproject_position(head) - _name_tag.size * 0.5
	# Conversation line rides just under the name tag, sharing its visibility rules.
	if _conversation_text != null and not _conversation_text.text.is_empty():
		_conversation_text.visible = true
		_conversation_text.position = _name_tag.position \
				+ Vector2(_name_tag.size.x * 0.5 - _conversation_text.size.x * 0.5, _name_tag.size.y)

## Set the remote player's name tag text (no-op until the tag exists).
func set_player_name(player_name) -> void:
	if _name_tag != null:
		_name_tag.text = str(player_name)

## Owner-local: predict whether the carry key picks up or drops, to stow/unstow the
## perforator right away. The server stays authoritative (it may reject, e.g. a piece
## already taken); a mismatch self-corrects on the next interaction.
func _predict_carry_stow(aim: Node) -> void:
	if player._owner_carrying:
		player._owner_carrying = false
		player.mining_tool.set_stowed(false)
		return
	# Predict with the SAME validated target we send the server (it already passed the
	# line-of-sight + not-carried-by-another checks), so the optimistic stow can't flicker
	# into a brief "[E] Drop" when the grab is actually blocked (wall / another player's prop).
	if aim != null and aim.interact():
		player._owner_carrying = true
		player.mining_tool.set_stowed(true)

## Apply a server->client property update (position, rotation, torch, carry prompt, mining state,
## carry reconciliation). Only a client receives this for a player; the Player facade delegates here.
func client_channel_data_update(data: Dictionary) -> void:
	if data.has("position"):
		player.position = Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
	if data.has("rotation"):
		player.rotation = Vector3(
			data["rotation"]["x"],
			data["rotation"]["y"],
			data["rotation"]["z"]
		)
	if data.has("flashlight"):
		var torch_on := bool(data["flashlight"])  # replicated torch state (owner + remotes)
		# Click only on a REAL flip, and never on the state a remote player spawns with (a torch that
		# was already lit before we ever saw them must not click in our ears).
		if _sfx_live and torch_on != player.flashlight.visible:
			_play_torch_sfx(torch_on)
		player.flashlight.visible = torch_on
	if data.has("carry_prompt") and not player.remote_player:
		player._carry_prompt = str(data["carry_prompt"])  # server-decided E prompt for the owner
	if data.has("action"):
		# The server tags each jump "jump:<n>". "action" is a replicated STATE (Horizon merges it into
		# the player object and may re-broadcast it: new subscriber, zone re-entry…), so the same value
		# can land here several times — playing on every arrival made one jump sound like a burst. Only
		# a value we have never seen is a new jump.
		var action := str(data["action"])
		if action.begins_with(JUMP) and action != _last_jump_action:
			_last_jump_action = action
			player.is_jumping = true
			_airborne = true  # feet off the ground: no footsteps until we land (see _update_footsteps)
			_air_time = 0.0
			if _sfx_live:  # not the spawn snapshot: someone really jumped
				_play_jump_sfx()
		elif action.begins_with("land") and action != _last_land_action:
			_last_land_action = action
			_airborne = false  # crisp: the server just touched ground -> end the jump loop now
		elif action.begins_with("emote:") and action != _last_emote_action:
			_last_emote_action = action
			player.emote_key = action.split(":")[1]  # "emote:<key>:<n>" -> the emote key
		elif action.begins_with("seat:") and action != _last_seat_action:
			_last_seat_action = action
			if player.remote_player:
				player.seated_role = action.split(":")[1]  # "seat:<role>:<n>" -> drive/passenger sit pose
		elif action.begins_with("unseat") and action != _last_seat_action:
			_last_seat_action = action
			if player.remote_player:
				player.seated_role = ""  # left the seat -> normal locomotion pose
			elif is_instance_valid(player._seat_node):
				_leave_vehicle(false)  # server refused our seat (occupied/blocked) -> revert optimistic entry
		elif action.begins_with("vault:") and action != _last_vault_action:
			_last_vault_action = action
			player.vault_key = action  # "vault:<key>:<height>:<n>" -> the animator plays the matching climb clip
			if _sfx_live:  # not the spawn snapshot: someone really vaulted -> the per-type sound
				_play_vault_sfx(action.split(":")[1])
	_sfx_live = true  # from now on, replicated changes are real events → they get their sound
	if data.has("stance"):
		player.stance = int(data["stance"])  # server-owned: owner reads the echo AND remotes get the pose
	# Replicated mining state (tool visibility, camera aim, perforation) is applied
	# on remote players by the MiningTool component.
	if player.remote_player:
		if data.has("head"):
			# Look pitch is a GENERAL player property: the body owns applying it to its camera pivot, and
			# every component consumes it (the puppet's head-tilt, the mining tool's aim) — one writer, DRY.
			player.camera_pivot.rotation.x = float(data["head"])
		if data.has("head_yaw"):
			player.camera_pivot.rotation.y = float(data["head_yaw"])  # seated free-look yaw (0 while standing)
		player.mining_tool.apply_remote(data)
		if data.has("carrying"):
			_remote_carrying = bool(data["carrying"])  # drives the remote avatar's carry pose
		if data.has("conversation"):
			print("RECU!!!")
			if _conversation_text == null:
				_conversation_text.visible = false
			else:
				# null = the server's "done talking" marker, sent once the dialog queue drains. Guard it:
				# str(null) is the literal "<null>", which would hang that text over the NPC's head.
				var line = data["conversation"]
				_conversation_text.text = "" if line == null else str(line)
				# Empty text must not leave an invisible-but-present bubble; _update_name_tag re-shows it
				# as soon as there is something to read again.
				if _conversation_text.text.is_empty():
					_conversation_text.visible = false
				else:
					_conversation_text.visible = true
	elif data.has("carrying"):
		# Owner: reconcile the optimistic carry prediction with the server's verdict
		# (e.g. a missed pickup) so we never get stuck stowed (issue #124).
		var server_carrying := bool(data["carrying"])
		if server_carrying != player._owner_carrying:
			player._owner_carrying = server_carrying
			player.mining_tool.set_stowed(server_carrying)

# ------------------------------------------------------------------------------
# Audio SFX (client only — the game server has no audio). Sounds are positional and played on EVERY
# player body, ours and the remote avatars', so you hear the others walk, jump and click their torch.
# ------------------------------------------------------------------------------
## Derive this body's motion from its LOCAL position delta (the planet's own motion is excluded — same
## reasoning as the footsteps below) and cache it on the facade, so the footsteps AND the puppet's
## CharacterAnimator read one shared computation. Runs for the owner AND every remote avatar (a remote
## has no velocity / is_on_floor to read, only its interpolated position — exactly enough here).
func _sample_locomotion(delta: float) -> void:
	var here: Vector3 = player.position
	var moved: Vector3 = here - _loco_last_position
	_loco_last_position = here
	var dt: float = maxf(delta, 0.0001)
	var teleport: bool = moved.length() > 5.0  # spawn offset / reparent snap: not real walking
	var body_basis: Basis = player.transform.basis
	var up: Vector3 = body_basis.y.normalized()  # body's own up (gravity-oriented, in the LOCAL frame)
	var climb: float = moved.dot(up)
	var horizontal: Vector3 = moved - up * climb
	var local: Vector3 = body_basis.inverse() * horizontal  # body frame: -Z forward, +X right
	# Raw per-frame motion is bursty (30 Hz position + interpolator settling => some frames move 0), which
	# would flicker the walk animation idle<->walk. Low-pass speed/direction; the footsteps use the same
	# smoothed speed (its integral is preserved, so the step cadence is unchanged).
	if teleport:
		_smooth_speed = 0.0
		_smooth_forward = 0.0
		_smooth_right = 0.0
	else:
		var k: float = clampf(delta * LOCO_SMOOTH_RATE, 0.0, 1.0)
		_smooth_speed = lerpf(_smooth_speed, horizontal.length() / dt, k)
		_smooth_forward = lerpf(_smooth_forward, -local.z / dt, k)
		_smooth_right = lerpf(_smooth_right, local.x / dt, k)
	# Yaw rate (rad/s) around up: how fast the body pivots, for the in-place turn animation. Signed angle
	# the flattened body-forward swept since last frame, over dt. Zeroed on a teleport/reparent snap.
	var forward_now: Vector3 = -body_basis.z
	var yaw_rate: float = 0.0
	if not teleport and _loco_last_forward != Vector3.ZERO:
		var prev_flat: Vector3 = _loco_last_forward - up * _loco_last_forward.dot(up)
		var now_flat: Vector3 = forward_now - up * forward_now.dot(up)
		if prev_flat.length() > 0.01 and now_flat.length() > 0.01:
			yaw_rate = prev_flat.normalized().signed_angle_to(now_flat.normalized(), up) / dt
	_loco_last_forward = forward_now
	_smooth_yaw_rate = 0.0 if teleport else lerpf(_smooth_yaw_rate, yaw_rate, clampf(delta * LOCO_SMOOTH_RATE, 0.0, 1.0))
	player.locomotion_sample = {
		"planar_speed": _smooth_speed,
		"climb_speed": absf(climb) / dt,
		"forward": _smooth_forward,
		"right": _smooth_right,
		"airborne": _airborne,
		"seated": player.seated_role != "",  # replicated seat state (see Player.seated_role)
		"driver": player.seated_role == "driver",
		"carrying": _remote_carrying if player.remote_player else player._owner_carrying,
		"stance": player.stance,  # 0 standing / 1 crouched / 2 prone (server-owned, drives crouch/crawl anim)
		"yaw_rate": _smooth_yaw_rate,  # turn rate (rad/s) around up, for the in-place turn animation
		"teleport": teleport,
	}

## Footsteps, measured in DISTANCE WALKED rather than time: one step per `sfx_footstep_stride` metres.
## The cadence then follows the speed for free (running covers ground faster => faster steps), it works
## the same on our own body and on a remote avatar (whose position is interpolated, with no velocity or
## is_on_floor to read), and a player pushed around without walking makes no sound.
func _update_footsteps(delta: float) -> void:
	if player.sfx_footsteps.is_empty():
		return
	var s: Dictionary = player.locomotion_sample
	if s.is_empty():
		return
	# Seated in a vehicle, or a teleport / spawn snap (the whole offset in one frame): no steps.
	if bool(s["seated"]) or bool(s["teleport"]):
		_step_distance = 0.0
		return
	var climb_speed: float = float(s["climb_speed"])  # vertical part: jumping / falling / a lift
	# Airborne: no footsteps until we land. The vertical-speed test alone is NOT enough — at the top of
	# a jump the vertical speed passes through zero, so a jump made while running forward would sneak a
	# step out in mid-air. The jump event opens the window; a slow vertical speed, once we have actually
	# been in the air a moment, closes it (that is the landing).
	if _airborne:
		_air_time += delta
		if _air_time > MIN_AIR_TIME and climb_speed < MAX_LANDED_CLIMB_SPEED:
			_airborne = false
		else:
			_step_distance = 0.0
			return
	if climb_speed > MAX_STEP_CLIMB_SPEED:  # falling off a ledge: no jump event, caught here
		return
	# Standing still is NOT perfectly still: the replicated position is rounded (half a centimetre) and
	# the body settles on the terrain, so a raw accumulator drifts and eventually fires a phantom step
	# while we only look around. Below a real walking speed, nothing counts and the tally resets.
	var planar_speed: float = float(s["planar_speed"])
	if planar_speed < MIN_WALK_SPEED:
		_step_distance = 0.0
		return
	_step_distance += planar_speed * delta
	if _step_distance < player.sfx_footstep_stride:
		return
	_step_distance = 0.0
	_play_footstep()

## One footstep: a random sample, never the same one twice in a row, with a touch of random pitch.
## Both tricks fight the "machine gun" effect a single repeated sample gives.
func _play_footstep() -> void:
	var count: int = player.sfx_footsteps.size()
	var index: int = randi() % count
	if count > 1 and index == _step_last_index:
		# Draw again, UNIFORMLY among the other samples: replacing the repeat with "the next one" would
		# make that neighbour come up more often than the rest.
		index = randi() % (count - 1)
		if index >= _step_last_index:
			index += 1
	_step_last_index = index
	var jitter: float = player.sfx_footstep_pitch_jitter
	Sfx3D.play_pitched(player, player.sfx_footsteps[index], player.sfx_footstep_db,
			player.sfx_footstep_falloff, player.sfx_footstep_distance, player.sfx_footstep_attenuation,
			randf_range(1.0 - jitter, 1.0 + jitter))

## The torch was just flipped (replicated state): click it. Silent on the spawn snapshot (see _sfx_live).
func _play_torch_sfx(on: bool) -> void:
	if on:
		Sfx3D.play(player, player.sfx_torch_on, player.sfx_torch_on_db, player.sfx_torch_on_falloff,
				player.sfx_torch_on_distance, player.sfx_torch_on_attenuation)
	else:
		Sfx3D.play(player, player.sfx_torch_off, player.sfx_torch_off_db, player.sfx_torch_off_falloff,
				player.sfx_torch_off_distance, player.sfx_torch_off_attenuation)

## The jump effort (not the landing).
func _play_jump_sfx() -> void:
	Sfx3D.play(player, player.sfx_jump, player.sfx_jump_db, player.sfx_jump_falloff,
			player.sfx_jump_distance, player.sfx_jump_attenuation)

## The auto-vault effort, one sound per type (SafetyVault / ClimbUp_1m / ClimbUp_2m). `key` comes from
## the replicated "vault:<key>:<height>:<n>" event, so every body plays it.
func _play_vault_sfx(key: String) -> void:
	match key:
		"climb_1m":
			Sfx3D.play(player, player.sfx_climb_1m, player.sfx_climb_1m_db, player.sfx_climb_1m_falloff,
					player.sfx_climb_1m_distance, player.sfx_climb_1m_attenuation)
		"climb_2m":
			Sfx3D.play(player, player.sfx_climb_2m, player.sfx_climb_2m_db, player.sfx_climb_2m_falloff,
					player.sfx_climb_2m_distance, player.sfx_climb_2m_attenuation)
		_:
			Sfx3D.play(player, player.sfx_vault, player.sfx_vault_db, player.sfx_vault_falloff,
					player.sfx_vault_distance, player.sfx_vault_attenuation)
