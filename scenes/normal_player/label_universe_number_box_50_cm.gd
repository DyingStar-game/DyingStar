extends Label

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_number_boxes50cm.connect(_set_gameserver_number_boxes50cm)

func _set_gameserver_number_boxes50cm(number_boxes_50cm_server):
	text = str(number_boxes_50cm_server)
