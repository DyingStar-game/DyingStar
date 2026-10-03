extends VBoxContainer


@onready var down_button: Button = %"Button Down"
@onready var stop_button: Button = %"Button Stop"
@onready var up_button: Button = %"Button Up"


func setup(vehicle_lift: VehicleLift, _screen: Control) -> void:
	if GameOrchestrator.is_server():
		return
	
	if not vehicle_lift or not _screen:
		push_error("vehicle_lift ou _screen non présents dans %s" % name)
		return
	
	var platform: RigidBody3D = vehicle_lift.get_node_or_null("Platform System/Platform")
	if platform:
		if platform.has_method("_on_call_button_triggered"):
			if not down_button.pressed.is_connected(platform._on_call_button_triggered):
				down_button.pressed.connect(platform._on_call_button_triggered.bind({
					"button": "down"
				}))
			if not stop_button.pressed.is_connected(platform._on_call_button_triggered):
				stop_button.pressed.connect(platform._on_call_button_triggered.bind({
					"button": "stop"
				}))
			if not up_button.pressed.is_connected(platform._on_call_button_triggered):
				up_button.pressed.connect(platform._on_call_button_triggered.bind({
					"button": "up"
				}))
