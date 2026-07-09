extends Label

func _ready() -> void:
	visible = false

func _set_gameserver_coordinates(coordinates):
	text = "Xmin: " + str(coordinates.min_x) + "\n"
	text += "Xmax: " + str(coordinates.max_x) + "\n"
	text += "Ymin: " + str(coordinates.min_y) + "\n"
	text += "Ymax: " + str(coordinates.max_y) + "\n"
	text += "Zmin: " + str(coordinates.min_z) + "\n"
	text += "Zmax: " + str(coordinates.max_z) + "\n"

func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_gameserver_coordinates.connect(_set_gameserver_coordinates)
	else:
		visible = false
		NetworkOrchestrator.set_gameserver_coordinates.disconnect(_disconnect)
