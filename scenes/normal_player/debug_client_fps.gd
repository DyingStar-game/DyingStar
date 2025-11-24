extends RichTextLabel

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			var fps = int(Performance.get_monitor(Performance.TIME_FPS))
			if fps >= 30:
				text = "[color=green]" + str(int(fps)) + "[/color] FPS"
			else:
				text = "[color=red]" + str(int(fps)) + "[/color] FPS"
	else:
		visible = false
