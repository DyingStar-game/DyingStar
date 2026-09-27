extends Label

var _poll: Timer = null

func _ready() -> void:
	_poll = DebugPoll.attach(self, 1.0, _refresh)

func _on_normal_player_display_debug(show: bool) -> void:
	DebugPoll.set_shown(self, _poll, show, _refresh)

func _refresh() -> void:
	# Same guard as the players panel: this keeps polling while no network agent exists.
	var agent = NetworkOrchestrator.network_agent
	if agent == null or not "props_list" in agent:
		text = "- scenes"
		return
	var nb_scenes = 0
	for proptype in agent.props_list.keys():
		nb_scenes += agent.props_list[proptype].size()
	text = str(nb_scenes) + " scenes"
