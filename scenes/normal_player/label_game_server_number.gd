extends Label

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_number_servers.connect(_set_gameserver_number_servers)

func _set_gameserver_number_servers(nb_servers):
	text = str(nb_servers)
