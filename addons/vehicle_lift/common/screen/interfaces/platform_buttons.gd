extends VBoxContainer


@onready var down_button: Button = %"Button Down"
@onready var stop_button: Button = %"Button Stop"
@onready var up_button: Button = %"Button Up"


func setup(vehicle_lift: VehicleLift, _screen: Control) -> void:
	if GameOrchestrator.is_server():
		print_rich("[color=dodger_blue][server][/color][color=gold] platform_buttons : setup : [/color][/color]")
		return
	else:
		print_rich("[color=crimson][client][/color][color=gold] platform_buttons : setup : [/color]")
	
	if not vehicle_lift or not _screen:
		print_rich("\t[color=red]screen ou vehicle_lift non présent[/color]")
		return
	else:
		print_rich("\t[color=green]screen et vehicle_lift sont présents[/color]")
	
	var platform: RigidBody3D = vehicle_lift.get_node_or_null("Platform System/Platform")
	if platform:
		print_rich("\t\t[color=green]on existe[/color]")
		if platform.has_method("_on_call_button_triggered"):
			print_rich("\t\t\t[color=green]platform possède la méthode _on_call_button_triggered[/color]")
			if not down_button.pressed.is_connected(platform._on_call_button_triggered):
				print_rich("\t\t\t[color=green]on est pas déjà connecté alors on se connecte[/color]")
				down_button.pressed.connect(platform._on_call_button_triggered.bind({
					"button": "down"
				}))
			if not stop_button.pressed.is_connected(platform._on_call_button_triggered):
				print_rich("\t\t\t[color=green]on est pas déjà connecté alors on se connecte[/color]")
				stop_button.pressed.connect(platform._on_call_button_triggered.bind({
					"button": "stop"
				}))
			if not up_button.pressed.is_connected(platform._on_call_button_triggered):
				print_rich("\t\t\t[color=green]on est pas déjà connecté alors on se connecte[/color]")
				up_button.pressed.connect(platform._on_call_button_triggered.bind({
					"button": "up"
				}))
		else:
			print_rich("\t\t\t[color=red]platform ne possède pas la méthode _on_call_button_triggered[/color]")
	
	#down_button.pressed.connect(vehicle_lift.move_down)
	#stop_button.pressed.connect(vehicle_lift.stop_movement)
	#up_button.pressed.connect(vehicle_lift.move_up)
