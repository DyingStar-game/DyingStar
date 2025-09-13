extends Label

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_numberBoxes50cm.connect(_set_gameserver_numberBoxes50cm)

func _set_gameserver_numberBoxes50cm(number_boxes_50cm_server):
	text = str(number_boxes_50cm_server)
