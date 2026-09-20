extends VBoxContainer


@onready var down_button: Button = %"Button Down"
@onready var stop_button: Button = %"Button Stop"
@onready var up_button: Button = %"Button Up"


func setup(vehicle_lift: VehicleLift, _screen: Control) -> void:
	if not vehicle_lift:
		return
	
	down_button.pressed.connect(vehicle_lift.move_down)
	stop_button.pressed.connect(vehicle_lift.stop_movement)
	up_button.pressed.connect(vehicle_lift.move_up)
