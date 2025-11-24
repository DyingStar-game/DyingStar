extends Label

func _ready() -> void:
	visible = false

func _set_gameserver_number_objects(number_objects_server):
	text = str(int(number_objects_server)) + " objects"
	
func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_gameserver_number_objects.connect(_set_gameserver_number_objects)
	else:
		visible = false
		NetworkOrchestrator.set_gameserver_number_objects.disconnect(_disconnect)
