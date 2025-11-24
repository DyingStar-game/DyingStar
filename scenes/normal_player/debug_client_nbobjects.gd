extends Label

func _ready() -> void:
	while true:
		await get_tree().create_timer(1.0).timeout
		var number_objects = Performance.get_monitor(Performance.OBJECT_COUNT)
		text = str(int(number_objects)) + " objects"
