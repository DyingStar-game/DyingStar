extends Label

func _ready() -> void:
	visible = false
	# Connected once, for the panel's whole life: the value is known the moment the panel is shown
	# (the F8 capture shows it for one frame), and hiding it no longer tries to disconnect a
	# callable that was never connected (nor showing it to connect the same one twice).
	NetworkOrchestrator.set_gameserver_zones.connect(_set_gameserver_zones)

## One line per zone of the Godot server simulating us: its world (space or a planet) and, when
## the zone is only part of that world, its bounds in that world's coordinates.
func _set_gameserver_zones(zones):
	var lines: PackedStringArray = []
	for zone in zones:
		var label: String = str(zone.get("world", "?"))
		if label == "planet":
			label += " " + str(zone.get("planet_name", zone.get("planet_uuid", "?")))
		var b = zone.get("bounds")
		if b == null:
			label += " (whole)"
		else:
			label += "\n  X: %.0f .. %.0f\n  Y: %.0f .. %.0f\n  Z: %.0f .. %.0f" % [
				b["min_x"], b["max_x"], b["min_y"], b["max_y"], b["min_z"], b["max_z"]]
		lines.append(label)
	text = "\n".join(lines)

func _on_normal_player_display_debug(show: bool) -> void:
	visible = show
