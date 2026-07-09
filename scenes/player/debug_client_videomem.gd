extends Label

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			var mem = snapped((Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1024) / 1024, 0.001)
			text = str(int(mem)) + " MB video memory"
	else:
		visible = false
