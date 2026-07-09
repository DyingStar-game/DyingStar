class_name PlayerClient
extends Node

const JUMP: String = "jump"  # kept in sync with Player.JUMP

## Client-side logic for a player — runs on every client instance, never on the server. Covers the
## OWNER (local input, camera, HUD prompts, prediction) and a REMOTE avatar (interpolation, name tag).
## Created by Player as a child node (so it gets its own _process / _unhandled_input from the engine);
## it reaches the shared body, nodes and state through `player`. (Filled in incrementally.)

## The body / facade this role drives (a Player). Untyped ON PURPOSE: typing it `Player` would create a
## cyclic class_name dependency (Player references PlayerServer/PlayerClient, which reference Player) and
## break global script compilation. Untyped duck-typing still reaches every Player member.
var player

## One-time init, called by Player._ready() once `player` is wired and both are in the tree.
func setup() -> void:
	pass

## Per-frame client work: REMOTE avatar interpolation + name tag, or the OWNER's seat ride / camera /
## HUD prompts / mouse capture / input sampling. Runs on this role's own child node, so the engine
## calls it only on a client (never the dedicated server). Reaches the shared body through `player`.
func _process(_delta: float) -> void:
	if player.remote_player:
		player._interp.update(player, _delta)  # entity interpolation: glide between server updates
		player._update_name_tag()
		return
	# Seated in a vehicle: ride the seat HERE, in sync with the vehicle's own _process
	# interpolation, so the camera stays glued to the (smoothly moving) cabin — no jitter/blur.
	if is_instance_valid(player._seat_node):
		player._ride_seat(player._seat_node)
		# Seated: clear the on-foot prompts, but still let a driver/passenger close (or reopen) a door by
		# LOOKING at its handle — the handle rides the door now, so aiming works open or closed.
		player.interact_label.hide()
		var seated_handle = player._aimed_door_handle()
		if seated_handle != null:
			player.interact_label.text = player._door_prompt(seated_handle)
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
		player._handle_camera_motion()


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
		var aimed_handle = player._aimed_door_handle()
		if aimed_handle != null:
			player.interact_label.text = player._door_prompt(aimed_handle)
			player.interact_label.show()

	# Standing in a seat box (on foot): board, or say it's taken / that the door must be opened first.
	if not player.interact_label.visible and is_instance_valid(player._nearby_seat) and player._seat_vehicle_uuid == "":
		if player._seat_is_taken(player._nearby_seat):
			player.interact_label.text = "Driver seat taken"
		elif not player._seat_door_open(player._nearby_seat):
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

func _unhandled_input(event: InputEvent) -> void:
	if player.remote_player: return
	# Leave the seat we occupy (driver or passenger) with Y — but only if this seat's door is open
	# (open it first by looking at its handle). A seat with no door_id leaves directly.
	if player._seat_vehicle_uuid != "" and event.is_action_pressed("exit"):
		if player._seat_door_open(player._seat_node):
			player._leave_vehicle()
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
		var seated_handle = player._aimed_door_handle()
		if seated_handle != null:
			player._toggle_door(seated_handle)
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
		var handle = player._aimed_door_handle()
		if handle != null and is_instance_valid(player._nearby_seat):
			player._toggle_door(handle)
			return
		# Standing in a seat box: E boards — but only once the seat's gating door is open (open it
		# first by looking at the handle). A seat with no door_id boards directly.
		if is_instance_valid(player._nearby_seat):
			if player._seat_door_open(player._nearby_seat):
				player._enter_seat(player._nearby_seat)
			return
		# Otherwise pick up / drop. Send the uuid of the carriable under OUR crosshair so the
		# server grabs exactly that one (its own ray can be slightly off and grab a neighbour).
		var aim = player._aimed_carriable()
		var target_uuid := str(aim.uuid) if aim != null else ""
		player.client_send_action_to_server({"action": "action", "target_uuid": target_uuid})
		player._predict_carry_stow(aim)

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
