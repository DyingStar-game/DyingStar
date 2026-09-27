extends Label

var _poll: Timer = null

func _ready() -> void:
	_poll = DebugPoll.attach(self, 1.0, _refresh)

func _on_normal_player_display_debug(show: bool) -> void:
	DebugPoll.set_shown(self, _poll, show, _refresh)

func _refresh() -> void:
	var mem = snapped((Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1024) / 1024, 0.001)
	text = str(int(mem)) + " MB video memory"
