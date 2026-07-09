class_name PlayerClient
extends Node

const JUMP: String = "jump"  # kept in sync with Player.JUMP
## Hide a remote player's name tag beyond this distance from the local camera.
const NAME_TAG_MAX_DISTANCE: float = 25.0

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

## One-time init, called by Player._ready() once `player` is wired and both are in the tree.
func setup() -> void:
	pass

## Per-frame client work: REMOTE avatar interpolation + name tag, or the OWNER's seat ride / camera /
## HUD prompts / mouse capture / input sampling. Runs on this role's own child node, so the engine
## calls it only on a client (never the dedicated server). Reaches the shared body through `player`.
func _process(_delta: float) -> void:
	if player.remote_player:
		player._interp.update(player, _delta)  # entity interpolation: glide between server updates
		_update_name_tag()
		return
	# Seated in a vehicle: ride the seat HERE, in sync with the vehicle's own _process
	# interpolation, so the camera stays glued to the (smoothly moving) cabin — no jitter/blur.
	if is_instance_valid(player._seat_node):
		player._ride_seat(player._seat_node)
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

	# Mining (aim, perforation, head sync) runs in the MiningTool; here we just
	# apply its effect on the local mouse look before moving the camera.
	player.mining_tool.update_local(_delta)
	if player.mining_tool.is_aiming:
		player.mouse_motion *= player.mining_tool.aim_sensitivity_factor
	if player.mining_tool.is_perforating:
		player.mouse_motion = Vector2.ZERO  # mouse frozen during perforation

	# Free the mouse + freeze the camera whenever the player isn't in direct control: focused on a
	# 3D screen, the spawn wheel, OR the pause menu is open. Otherwise capture the mouse and move the
	# camera. (Without the pause case, this would re-capture every frame and hide the menu cursor.)
	var ui_focus: bool = player.screen_interacting != null \
		or (player._spawn_wheel != null and player._spawn_wheel.visible) \
		or GameOrchestrator.current_state == GameOrchestrator.GameStates.PAUSE_MENU
	if ui_focus:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		player.mouse_motion = Vector2.ZERO
		# Turn the camera toward a 3D screen so it's centered in view.
		if player.screen_interacting and player.screen_position != player.camera.global_position:
			var look: Transform3D = player.camera.global_transform.looking_at(player.screen_position, player.up_direction)
			player.camera.global_transform = player.camera.global_transform.interpolate_with(look, 0.15)
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
				if Input.is_action_just_pressed("interact"):
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
	var sprint = null

	#apply_parent_movement()

	if not player.direct_chat.can_write:
		dir_vect = Input.get_vector(player.MOVE_LEFT, player.MOVE_RIGHT, player.MOVE_FORWARD, player.MOVE_BACK)
		sprint = Input.is_action_pressed(player.SPRINT)

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

	var dir_vect = Vector3.ZERO
	var sprint = null

	#apply_parent_movement()

	if not player.direct_chat.can_write:
		dir_vect = Input.get_vector(player.MOVE_LEFT, player.MOVE_RIGHT, player.MOVE_FORWARD, player.MOVE_BACK)
		sprint = Input.is_action_pressed(player.SPRINT)

	if dir_vect:
		player.input_direction = dir_vect
	else:
		player.input_direction = Vector2.ZERO
	# send move_direction
	var short_rotation = snapped(player.global_rotation, Vector3(0.0001, 0.0001, 0.0001))
	if player.input_direction != player.client_last_input_direction or short_rotation != player.client_last_global_rotation:
		player.client_last_input_direction = player.input_direction
		player.client_last_global_rotation = short_rotation
		player.emit_signal("hs_client_action_move", player.input_direction, short_rotation)
	player.update_last_basis()

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

## Owner camera + body orientation per frame: align to gravity (planet or 0g), apply the mouse look,
## and replicate the camera pitch ("head") to the server. Called from _process. Acts on the BODY, so
## the transform ops (global_basis / rotate_object_local) go through player, not this role node.
func _handle_camera_motion() -> void:
	var parent_gravity_area: Area3D = player.gravity_parents.back() if not player.gravity_parents.is_empty() else null

	if parent_gravity_area:
		player._no_gravity_time = 0.0
		if parent_gravity_area.gravity_point:
			player.up_direction = parent_gravity_area.global_position.direction_to(player.global_position)
		else:
			player.up_direction = parent_gravity_area.global_basis.y

		player.gravity = player._compute_gravity(parent_gravity_area)
		player.orient_player()
		player.global_basis = player.global_basis.rotated(player.global_basis.y, player.mouse_motion.x * player.camera_sensitivity)
		player.camera_pivot.rotate_object_local(Vector3.RIGHT, player.mouse_motion.y * player.camera_sensitivity)
		player.camera_pivot.rotation_degrees.x = clamp(player.camera_pivot.rotation_degrees.x, -80, 80)
	else:
		# No gravity area. Ignore a brief gap (e.g. a reparent leaving a spawn apartment) — only treat
		# it as real 0g after ZERO_G_GRACE, so the camera pitch survives the transition.
		player._no_gravity_time += player.get_process_delta_time()
		if player._no_gravity_time >= player.ZERO_G_GRACE:
			# 0g movement
			player.gravity = 0.0
			player.camera_pivot.rotation.x = 0
			player.rotate_object_local(Vector3.UP, player.mouse_motion.x * player.camera_sensitivity)
			player.rotate_object_local(Vector3.RIGHT, player.mouse_motion.y * player.camera_sensitivity)

	# Replicate the camera pitch ("head") to the server so others see where we look and
	# the server can aim our interaction ray + place a carried item (tech-debt A / #124).
	var head_q := snappedf(player.camera_pivot.rotation.x, 0.02)
	if head_q != player._last_head_sent:
		player._last_head_sent = head_q
		player.client_send_action_to_server({"action": "update_property", "head": head_q})

	player.mouse_motion = Vector2.ZERO

func _unhandled_input(event: InputEvent) -> void:
	if player.remote_player: return
	# Leave the seat we occupy (driver or passenger) with Y — but only if this seat's door is open
	# (open it first by looking at its handle). A seat with no door_id leaves directly.
	if player._seat_vehicle_uuid != "" and event.is_action_pressed("exit"):
		if _seat_door_open(player._seat_node):
			_leave_vehicle()
		return

	if player._seat_is_driver and player._seat_vehicle_uuid != "" and event.is_action_pressed("vehicle_reset"):
		# Reset the vehicle upright (server-authoritative; driver only).
		player.client_send_action_to_server({"action": "reset_vehicle", "target_uuid": player._seat_vehicle_uuid})

	if player._seat_is_driver and player._seat_vehicle_uuid != "" and event.is_action_pressed("vehicle_lights"):
		# Toggle the vehicle head lights (server-authoritative; driver only).
		player.client_send_action_to_server({"action": "vehicle_lights", "target_uuid": player._seat_vehicle_uuid})

	if event.is_action_pressed("toggle_flashlight"):
		# Toggle the player's torch — on foot AND while seated (driver or passenger), so it must
		# sit before the walk guard. By default it shares the L key with vehicle_lights, so one
		# press toggles both the torch and the head lights; rebind it to a separate key in
		# Settings > Controls to control the torch independently.
		player.client_send_action_to_server({"action": "toggle_flashlight"})

	# Capture mouse look even while seated (free look in a vehicle), before the walk guard.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
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

	if event.is_action_pressed("spawn_wheel"):
		if player._spawn_wheel:
			player._spawn_wheel.open([
				{"text": "Rocher", "submenu": [
					{"text": "S", "data": "rock"},
					{"text": "M", "data": "rock_medium"},
					{"text": "L", "data": "rock_large"},
				]},
				{"text": "Caisse", "submenu": [
					{"text": "50cm", "data": "box"},
					{"text": "Ares", "data": "palette_container"},
					{"text": "Palet", "data": "pallet_plate"},
					{"text": "Cube", "data": "pallet_crate"},
					{"text": "Benne", "data": "pallet_benne"},
					{"text": "Liquid", "data": "pallet_liquid"},
				]},
				{"text": "Dépôt", "data": "depot"},
				{"text": "Camion", "data": "truck"},
			])
	if event.is_action_released("spawn_wheel"):
		if player._spawn_wheel:
			player._spawn_wheel.confirm()

	if event.is_action_pressed("debug_console"):
		if player._display_debug:
			player.display_debug.emit(false)
			player._display_debug = false
		else:
			player.display_debug.emit(true)
			player._display_debug = true

## True when the seat is occupied (E won't work). Only the DRIVER seat's occupancy is
## replicated (via the vehicle's pilot_uuid); a passenger seat reads as free for now.
func _seat_is_taken(seat: Node) -> bool:
	if seat == null or not seat.is_driver_seat():
		return false
	var veh: Node = seat.vehicle() if seat.has_method("vehicle") else null
	return veh != null and "pilot_uuid" in veh and str(veh.pilot_uuid) != ""

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

## Leave the seat we occupy (driver or passenger): tell the server, walk again, un-parent back into
## the world, and drop the driver HUD. Triggered by Y (exit) — see _unhandled_input.
func _leave_vehicle() -> void:
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
	var sky_material := PhysicalSkyMaterial.new()
	sky_material.rayleigh_coefficient = 2.5
	sky_material.mie_coefficient = 0.02
	sky_material.mie_eccentricity = 0.85
	sky_material.turbidity = 12.0
	sky_material.sun_disk_scale = 3.0
	sky_material.ground_color = Color(0.35, 0.28, 0.22)
	sky_material.energy_multiplier = 1.2
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
	player.camera.environment = env

## Live camera FOV update from the settings menu (local player only).
func _on_fov_changed(fov: float) -> void:
	player.camera.fov = fov

# Dev spawn wheel selection -> spawn the chosen prop in front of the player.
func _on_spawn_selected(data) -> void:
	if player.SPAWN_PROPS.has(data):
		var p: Dictionary = player.SPAWN_PROPS[data]
		spawn_box(p["scene"], p["type"], p["z"], p["y"])
	elif data == "depot":
		_spawn_depot()
	elif data == "truck":
		_spawn_truck()

# Spawn a networked truck (server-authoritative vehicle prop) in front of the player. The
# server simulates its physics and replicates it to every client (B1 vehicle networking).
func _spawn_truck() -> void:
	var spawn_pos: Vector3 = player.position + (-player.global_basis.z * 8.0) + player.global_basis.y * 1.0
	var parent = player.get_parent()
	# Robust to the scene layout: any parent without a uuid (SystemSandbox, a grouping node) = "".
	var parentuuid = str(parent.uuid) if "uuid" in parent else ""
	player.client_send_action_to_server({
		"action": "spawn_vehicle",
		"position": {"x": spawn_pos.x, "y": spawn_pos.y, "z": spawn_pos.z},
		"parent_id": parentuuid,
	})

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
		return
	_name_tag.visible = true
	_name_tag.position = cam.unproject_position(head) - _name_tag.size * 0.5

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
		player.flashlight.visible = bool(data["flashlight"])  # replicated torch state (owner + remotes)
	if data.has("carry_prompt") and not player.remote_player:
		player._carry_prompt = str(data["carry_prompt"])  # server-decided E prompt for the owner
	if data.has("action"):
		match data["action"]:
			JUMP:
				player.is_jumping = true
	# Replicated mining state (tool visibility, camera aim, perforation) is applied
	# on remote players by the MiningTool component.
	if player.remote_player:
		player.mining_tool.apply_remote(data)
	elif data.has("carrying"):
		# Owner: reconcile the optimistic carry prediction with the server's verdict
		# (e.g. a missed pickup) so we never get stuck stowed (issue #124).
		var server_carrying := bool(data["carrying"])
		if server_carrying != player._owner_carrying:
			player._owner_carrying = server_carrying
			player.mining_tool.set_stowed(server_carrying)
