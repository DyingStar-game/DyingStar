extends Control

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
	else:
		visible = false
