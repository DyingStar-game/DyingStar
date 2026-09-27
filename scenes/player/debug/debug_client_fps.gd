extends RichTextLabel

var _poll: Timer = null

func _ready() -> void:
	_poll = DebugPoll.attach(self, 1.0, _refresh)

func _on_normal_player_display_debug(show: bool) -> void:
	DebugPoll.set_shown(self, _poll, show, _refresh)

func _refresh() -> void:
	var fps = int(Performance.get_monitor(Performance.TIME_FPS))
	if fps >= 30:
		text = "[color=green]" + str(int(fps)) + "[/color] FPS"
	else:
		text = "[color=red]" + str(int(fps)) + "[/color] FPS"
