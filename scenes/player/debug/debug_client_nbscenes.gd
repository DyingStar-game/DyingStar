extends Label

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			# Same guard as the players panel: this keeps polling while no network agent exists.
			var agent = NetworkOrchestrator.network_agent
			if agent == null or not "props_list" in agent:
				text = "- scenes"
				continue
			var nb_scenes = 0
			for proptype in agent.props_list.keys():
				nb_scenes += agent.props_list[proptype].size()
			text = str(nb_scenes) + " scenes"
	else:
		visible = false
