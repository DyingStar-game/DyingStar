extends Label

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_number_objects.connect(_set_gameserver_number_objects)

func _set_gameserver_number_objects(number_objects_server):
	text = str(int(number_objects_server)) + " objects"
