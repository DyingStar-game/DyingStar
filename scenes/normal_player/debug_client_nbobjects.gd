extends Label

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			var number_objects = Performance.get_monitor(Performance.OBJECT_COUNT)
			text = str(int(number_objects)) + " objects"
	else:
		visible = false
