@tool
extends StaticBody3D


@onready var beacon_left: Node3D = %"Beacon Left"
@onready var beacon_right: Node3D = %"Beacon Right"

@onready var landing_interface: Control = %"Lower Landing Interface"


var beacon_speed: float = 270.0


var active_player: Player

func _ready() -> void:
	set_process(false)

	if Engine.is_editor_hint():
		var railing: Node3D = get_node_or_null("Railing")
		var railing_json_path: StringName = &"res://scenes/_universe/structures/industrial/vehicle_lift/landings/lower_landing/railing_datas.json"

		if railing:
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


func stop_beacons() -> void:
	set_process(false)
	beacon_left.toggle_lights(false)
	beacon_right.toggle_lights(false)


func update_interface_lift_progress(progress: float, eta: int, status: String) -> void:
	landing_interface.display_progress(progress, eta, status)


func update_screen(data: Dictionary):
	var action: Dictionary = data["elevator_screen_action"]
	var vehicle_lift = get_parent()

	if vehicle_lift == null or not vehicle_lift is VehicleLift:
		return

	if action.has("landing"):
		match action["landing"]:
			"lower":
				vehicle_lift.move_down()
			_:
				pass


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
