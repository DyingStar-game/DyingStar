extends Label

## Local solar time on the body whose gravity we are currently in — so it follows you from planet to
## moon, and shows nothing in space. Planet.get_local_solar_time does the work (a sundial: the angle
## between our meridian and the one facing the star), which is why no clock is synchronised for this.

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			text = _planet_time_text()
	else:
		visible = false

func _planet_time_text() -> String:
	var player: Node = owner
	if not is_instance_valid(player) or not player is Node3D:
		return "-- : --"
	# gravity_parents holds the PlanetGravity Area3D; the planet is its grandparent (the area is
	# created under PlanetTerrain).
	var area = player.get_current_gravity_parent()
	if area == null:
		return "space"  # free fall between bodies: no ground, no local time
	var planet: Node = area.get_parent().get_parent() if area.get_parent() != null else null
	if not (planet is Planet):
		return "-- : --"
	var hours: float = (planet as Planet).get_local_solar_time((player as Node3D).global_position)
	if hours < 0.0:
		return "-- : --"  # not spinning, no star, or standing on a pole
	var whole: int = int(hours)
	var minutes: int = int((hours - float(whole)) * 60.0)
	var label: String = "%02d:%02d %s" % [whole, minutes, (planet as Planet).name]
	# A clock that has been nudged must SAY so: an hour that does not match the authority's is the
	# kind of thing one forgets having set, and then debugs for twenty minutes.
	if not is_zero_approx(Globals.debug_time_offset):
		label += "  (%+.1f h dev)" % (Globals.debug_time_offset / 3600.0)
	return label
