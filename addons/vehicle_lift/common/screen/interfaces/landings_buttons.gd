extends VBoxContainer


@onready var call_button: Button = %"Button Call"
@onready var emergency_stop_button: Button


var vehicle_lift: VehicleLift
var screen: Control


func setup(_p_vehicle_lift: VehicleLift, _screen: Control) -> void:
	if GameOrchestrator.is_server():
		print_rich("[color=dodger_blue][server][/color][color=gold] landings_buttons : setup : [/color][/color]")
		return
	else:
		print_rich("[color=crimson][client][/color][color=gold] landings_buttons : setup : [/color]")
	vehicle_lift = _p_vehicle_lift
	screen = _screen
	
	if not vehicle_lift or not screen:
		print_rich("\t[color=red]screen ou vehicle_lift non présent[/color]")
		return
	else:
		print_rich("\t[color=green]screen et vehicle_lift sont présents[/color]")
	
	match screen.landing:
		screen.landing_list.LOWER_LANDING:
			print_rich("\t[color=orange]on est un lower_landing[/color]")
			var lower_landing: StaticBody3D = vehicle_lift.get_node_or_null("Lower Landing")
			if lower_landing:
				print_rich("\t\t[color=green]on existe[/color]")
				if lower_landing.has_method("_on_call_button_triggered"):
					print_rich("\t\t\t[color=green]lower_landing possède la méthode _on_call_button_triggered[/color]")
					if not call_button.pressed.is_connected(lower_landing._on_call_button_triggered):
						print_rich("\t\t\t[color=green]on est pas déjà connecté alors on se connecte[/color]")
						call_button.pressed.connect(lower_landing._on_call_button_triggered.bind({
							"landing": "lower"
						}))
				else:
					print_rich("\t\t\t[color=red]lower_landing ne possède pas la méthode _on_call_button_triggered[/color]")
		screen.landing_list.UPPER_LANDING:
			var upper_landing: StaticBody3D = vehicle_lift.get_node_or_null("Upper Landing")
			if upper_landing:
				if upper_landing.has_method("_on_call_button_triggered"):
					if not call_button.pressed.is_connected(upper_landing._on_call_button_triggered):
						call_button.pressed.connect(upper_landing._on_call_button_triggered.bind({
							"landing": "upper"
						}))
		_:
			pass


func _on_call_pressed() -> void:
	print_rich("[color=green]On a cliqué sur CALL[/color]")
	match screen.landing:
		screen.landing_list.LOWER_LANDING:
			vehicle_lift.move_down()
		screen.landing_list.UPPER_LANDING:
			vehicle_lift.move_up()
		_:
			pass
