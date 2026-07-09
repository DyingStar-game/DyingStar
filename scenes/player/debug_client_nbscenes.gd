extends Label

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			var nb_scenes = 0
			for proptype in NetworkOrchestrator.network_agent.props_list.keys():
				nb_scenes += NetworkOrchestrator.network_agent.props_list[proptype].size()
			text = str(nb_scenes) + " scenes"
	else:
		visible = false
