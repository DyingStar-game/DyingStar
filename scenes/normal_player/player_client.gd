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
