extends Label

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_name.connect(_set_gameserver_name)

func _set_gameserver_name(server_name):
	text = str(server_name)
