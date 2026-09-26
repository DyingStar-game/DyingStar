@tool
extends StaticBody3D


@onready var beacon_left: Node3D = %"Beacon Left"
@onready var beacon_right: Node3D = %"Beacon Right"

@onready var landing_interface: Control = %"Upper Landing Interface"


var beacon_speed: float = 270.0


var active_player: Player


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	set_process(false)
	
	if Engine.is_editor_hint():
		var railing: Node3D = get_node_or_null("Railing")
		var railing_json_path: StringName = &"res://addons/vehicle_lift/landing/upper_landing/railing_datas.json"
		
		if railing:
			VehicleLift.generate_railings(railing, railing_json_path)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	var rotation_step: float = deg_to_rad(beacon_speed) * _delta
	
	if beacon_left:
		beacon_left.spin_lights(rotation_step)
	if beacon_right:
		beacon_right.spin_lights(rotation_step)


func start_beacons() -> void:
	set_process(true)
	beacon_left.toggle_lights(true)
	beacon_right.toggle_lights(true)


func stop_beacons() -> void:
	set_process(false)
	beacon_left.toggle_lights(false)
	beacon_right.toggle_lights(false)


func update_interface_lift_progress(progress: float, eta: int, status: String) -> void:
	landing_interface.display_progress(progress, eta, status)


func update_screen(data: Dictionary):
	print_rich("[color=green]update_screen de upper_landing.gd[/color]")
	var action: Dictionary = data["elevator_screen_action"]
	var vehicle_lift = get_parent()
	
	if vehicle_lift == null or not vehicle_lift is VehicleLift:
		return
	
	print_rich("[color=gold]Actions : [/color]")
	print(action)
	if action.has("landing"):
		match action["landing"]:
			"lower":
				vehicle_lift.move_down()
			"upper":
				vehicle_lift.move_up()
			_:
				pass


## Where a player's camera should look while using this screen: the screen SURFACE, not the depot's
## origin (they are metres apart). Part of the informal "3D screen" contract — PlayerClient calls it
## when present and falls back to the node itself, so a simpler screen needs nothing at all.
func screen_look_target() -> Node3D:
	var screen = get_node_or_null("Kiosk/Kiosk Pivot Base Arm 01/Kiosk Arm 01/Kiosk Pivot Z Arm 01 Arm 02/Kiosk Pivot Y Arm 01 Arm 02/Kiosk Arm 02/Kiosk Z Pivot Arm 02 BallJoint/Kiosk Ball Joint/Kiosk Tablet/Screen Display")
	return screen as Node3D


## 3D-screen contract: a player's proximity monitor gained (or lost) this console. The PLAYER owns
## `screen_interacting` and is the single active monitor of the game (Player.connect_area_detect), so
## all we do here is note who is using the machine.
## This used to be a pair of body_entered / body_exited handlers on our own Area3D, with a half-second
## grace period bolted on to survive the planet's spin. Both are gone: an area-to-area overlap cannot
## desynchronise across a moving frame, so there is no false exit left to absorb (see ScreenZone).
func screen_focus_changed(player: Player, focused: bool) -> void:
	if focused:
		active_player = player
		return
	if is_instance_valid(active_player) and active_player.client_uuid == player.client_uuid:
		active_player = null


func _on_call_button_triggered(datas: Dictionary) -> void:
	if GameOrchestrator.is_server():
		return
	print_rich("[color=green]On a cliqué sur CALL et on est dans upper_landing.gd[/color]")
	var player: Player = NetworkOrchestrator.network_agent.player_entity
	player.client_send_action_to_server({
		"action": "screen_state",
		"elevator_screen_action": datas
	})
	pass
