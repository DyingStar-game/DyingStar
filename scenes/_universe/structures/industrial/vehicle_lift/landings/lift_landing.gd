@tool
class_name LiftLanding
extends StaticBody3D
## One landing of the vehicle lift, upper or lower: its two spinning beacons and departure alarm while
## the platform travels, the kiosk screen that shows the trip and calls the platform here. Both
## landings behave the same; what tells them apart is data (which end they stand at, their railing,
## their screen), set on each scene's root, so one script serves both.


## Which end of the lift this landing stands at: its call button sends the platform up here (on) or
## down here (off).
@export var is_upper: bool = false
## The railing layout (JSON) drawn around this landing in the editor (VehicleLift.generate_railings).
@export_file("*.json") var railing_json_path: String = ""
## The kiosk screen of this landing (a lift_base_interface): it shows the platform's progress.
@export var landing_interface: Control


@onready var beacon_left: Node3D = %"Beacon Left"
@onready var beacon_right: Node3D = %"Beacon Right"
## The departure alarm, looping for as long as the platform travels (the beacons' sound).
@onready var departure_alarm: AmbientLoop3D = %"Departure Alarm"


var beacon_speed: float = 270.0


var active_player: Player


func _ready() -> void:
	set_process(false)

	if Engine.is_editor_hint():
		var railing: Node3D = get_node_or_null("Railing")

		if railing and not railing_json_path.is_empty():
			VehicleLift.generate_railings(railing, railing_json_path)


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
	departure_alarm.set_running(true)


func stop_beacons() -> void:
	set_process(false)
	beacon_left.toggle_lights(false)
	beacon_right.toggle_lights(false)
	departure_alarm.set_running(false)


func update_interface_lift_progress(progress: float, eta: int, status: String) -> void:
	landing_interface.display_progress(progress, eta, status)


## SERVER: a call from this landing's screen (landings_buttons sends "upper" or "lower"). A landing
## only calls the platform to ITSELF: a call naming the other end is not this screen's to make.
func update_screen(data: Dictionary):
	var action: Dictionary = data["elevator_screen_action"]
	var vehicle_lift = get_parent()

	if vehicle_lift == null or not vehicle_lift is VehicleLift:
		return

	if action.get("landing") != ("upper" if is_upper else "lower"):
		return
	if is_upper:
		vehicle_lift.move_up()
	else:
		vehicle_lift.move_down()


## SERVER, screen contract (ScreenTarget): who sent the screen action about to be handled. The
## crosshair points at the kiosk's screen; there is no zone in front of it any more.
func set_screen_actor(player: Player) -> void:
	active_player = player


## CLIENT: a button of the kiosk's screen. ScreenTarget.send names this screen in the action, so the
## server finds it again and checks the player is within reach of it.
func _on_call_button_triggered(datas: Dictionary) -> void:
	if GameOrchestrator.is_server():
		return
	ScreenTarget.send(self, {"elevator_screen_action": datas})
