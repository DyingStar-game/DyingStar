extends Label

## Altitude above the surface of the body the player is on, and whether they are in the atmosphere or
## in space. Follows whichever body's gravity the player is in (like the local-time readout), so it
## updates on its own when moving between bodies and reads "space" in free fall between them.

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(0.25).timeout
			text = _altitude_text()
	else:
		visible = false

func _altitude_text() -> String:
	var player: Node = owner
	if not is_instance_valid(player) or not player is Node3D:
		return "alt --"
	# The gravity area (PlanetGravity) sits under PlanetTerrain, itself under the Planet.
	var area = player.get_current_gravity_parent()
	if area == null or area.get_parent() == null:
		return "alt --  (deep space)"
	var planet: Node = area.get_parent().get_parent()
	if not (planet is Planet) or (planet as Planet).planet_data == null:
		return "alt --"
	var data := (planet as Planet).planet_data
	# Altitude above the real terrain surface (samples the heightmap), ~0 when standing on the ground —
	# not distance to the core, which would read the planet radius.
	var altitude: float = (planet as Planet).surface_altitude_of((player as Node3D).global_position)
	# In the air while below the atmosphere top (Tarsis4 = 50 km; other bodies have no value yet), in
	# space above it. Airless bodies (height 0) read as space above the ground.
	var in_air: bool = data.atmosphere_height > 0.0 and altitude <= data.atmosphere_height
	var where: String = "atmosphere" if in_air else "space"
	var alt_str: String = "%.2f km" % (altitude / 1000.0) if absf(altitude) >= 1000.0 else "%.0f m" % altitude
	return "alt %s  (%s)" % [alt_str, where]
