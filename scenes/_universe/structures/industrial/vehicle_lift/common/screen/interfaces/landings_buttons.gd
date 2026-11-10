extends VBoxContainer


@onready var call_button: Button = %"Button Call"
@onready var emergency_stop_button: Button


var vehicle_lift: VehicleLift
var screen: Control


func setup(_p_vehicle_lift: VehicleLift, _screen: Control) -> void:
	if GameOrchestrator.is_server():
		return

	vehicle_lift = _p_vehicle_lift
	screen = _screen

	if not vehicle_lift or not screen:
		push_error("vehicle_lift ou screen non présents dans %s" % name)
		return

	# A stop's landing (VehicleLift.stop_depths) is a copy of the upper one: its button calls the platform
	# to that stop, through its own landing, not the lift's upper landing.
	var own := _own_landing()
	if own != null and own.stop_index >= 0:
		if not call_button.pressed.is_connected(own._on_call_button_triggered):
			call_button.pressed.connect(own._on_call_button_triggered.bind({"landing": "stop"}))
		return

	match screen.landing:
		screen.LandingList.LOWER_LANDING:

			var lower_landing: StaticBody3D = vehicle_lift.get_node_or_null("Lower Landing")
			if lower_landing:
				if lower_landing.has_method("_on_call_button_triggered"):
					if not call_button.pressed.is_connected(lower_landing._on_call_button_triggered):
						call_button.pressed.connect(lower_landing._on_call_button_triggered.bind({
							"landing": "lower"
						}))

		screen.LandingList.UPPER_LANDING:

			var upper_landing: StaticBody3D = vehicle_lift.get_node_or_null("Upper Landing")
			if upper_landing:
				if upper_landing.has_method("_on_call_button_triggered"):
					if not call_button.pressed.is_connected(upper_landing._on_call_button_triggered):
						call_button.pressed.connect(upper_landing._on_call_button_triggered.bind({
							"landing": "upper"
						}))
		_:
			pass


## The landing this screen stands on, or null.
func _own_landing() -> LiftLanding:
	var node: Node = get_parent()
	while node != null and not node is VehicleLift:
		if node is LiftLanding:
			return node as LiftLanding
		node = node.get_parent()
	return null
