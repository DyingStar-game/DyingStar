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
	return _altitude_only() + _frame_suffix()

## The scene-graph parent the player is currently attached to — the MOVING FRAME that carries them.
## Shows a body's name (e.g. "Tarsis4", or a structure on it) while bound to it; the universe root once
## released to deep space by the server frame-boundary. Tells at a glance whether a body's spin/orbit
## still carries you: "deep space · frame: Tarsis4" is bound (dragged), "· frame: <root>" is free.
func _frame_suffix() -> String:
	var player: Node = owner
	if not is_instance_valid(player):
		return ""
	var parent_node: Node = (player as Node).get_parent()
	if not is_instance_valid(parent_node):
		return "\nframe: (none)"
	return "\nframe: %s" % parent_node.name

func _altitude_only() -> String:
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
	# Longitude/latitude on the same "where am I" readout, in compass form (N/S, E/O), matching the
	# terrain geography. On its own line under the altitude, above the moving-frame suffix.
	var lonlat: Vector2 = (planet as Planet).lonlat_of((player as Node3D).global_position)
	var lat_str: String = "%.4f° %s" % [absf(lonlat.y), "N" if lonlat.y >= 0.0 else "S"]
	var lon_str: String = "%.4f° %s" % [absf(lonlat.x), "E" if lonlat.x >= 0.0 else "O"]
	return "alt %s  (%s)\n%s  %s" % [alt_str, where, lat_str, lon_str]
