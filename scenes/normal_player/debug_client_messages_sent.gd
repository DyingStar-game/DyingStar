extends Label

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			var messages = Performance.get_custom_monitor('network/events_sent')
			text = str(messages) + " events sent/second"
	else:
		visible = false
