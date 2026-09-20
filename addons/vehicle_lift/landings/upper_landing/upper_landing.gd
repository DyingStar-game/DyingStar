@tool
extends StaticBody3D


@onready var beacon_left: Node3D = %"Beacon Left"
@onready var beacon_right: Node3D = %"Beacon Right"

@onready var landing_interface: Control = %"Upper Landing Interface"


var beacon_speed: float = 270.0


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
