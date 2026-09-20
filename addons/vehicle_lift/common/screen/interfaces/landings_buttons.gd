extends VBoxContainer


@onready var call_button: Button = %"Button Call"
@onready var emergency_stop_button: Button


var vehicle_lift: VehicleLift
var screen: Control


func setup(_p_vehicle_lift: VehicleLift, _screen: Control) -> void:
	vehicle_lift = _p_vehicle_lift
	screen = _screen
	
	if vehicle_lift:
		call_button.pressed.connect(_on_call_pressed)
		if emergency_stop_button:
			emergency_stop_button.pressed.connect(vehicle_lift.stop_movement)


func _on_call_pressed() -> void:
	print_rich("[color=green]On a cliqué sur CALL[/color]")
	match screen.landing:
		screen.landing_list.LOWER_LANDING:
			vehicle_lift.move_down()
		screen.landing_list.UPPER_LANDING:
			vehicle_lift.move_up()
		_:
			pass
