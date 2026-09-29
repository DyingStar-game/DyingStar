extends Label

var _poll: Timer = null

func _ready() -> void:
	_poll = DebugPoll.attach(self, 1.0, _refresh)

func _on_normal_player_display_debug(show: bool) -> void:
	DebugPoll.set_shown(self, _poll, show, _refresh)

func _refresh() -> void:
	var number_objects = Performance.get_monitor(Performance.OBJECT_COUNT)
	text = str(int(number_objects)) + " objects"


func _on_player_display_debug(show: bool) -> void:
	pass # Replace with function body.
