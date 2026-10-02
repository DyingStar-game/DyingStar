class_name DevOverlay
extends RefCounted
## The debug readouts over the running game: one OverlayPanel on the right edge, growing with what it
## shows. It replaces the fixed-position panels (their lines were placed at fixed heights, so a long
## zone list ran over the next panel) and gathers the readouts that used to float on their own:
##
##   alert        red, pinned — the dev clock is shifted (shown even with the debug panels off)
##   Universe     servers, players, local time, altitude / position / moving frame   (show debug)
##   Server       TPS, players, objects, scenes of the Godot server                   (show debug)
##   Server box   its name and zones, as a table that scrolls on its own              (show debug)
##   Client       FPS, objects, scenes, x/y/z, VRAM, events/s, chunks on screen       (show debug)
##   Ground       what we stand on and how it was decided                  (Settings: Surface debug)
##   Music        the track, its playlist, the rule that chose it         (Settings: Music debug)
##   Star map     bodies, focus, zoom, sim time, relief tiles, map open (Settings: Star map debug)
##   Movement     speed, walk target, clip, vault / step                  (Settings: Movement debug)
##   Vehicle      the driver's readout while driving                    (Settings: Vehicle dashboard)
##
## Built here by composition; the panel does the rest (see OverlayPanel). The toggles and the server
## values live as children of the panel, so they go with it.

const WIDTH_PX : float = 400.0
## About three zones with their bounds; a longer list scrolls on its own.
const SERVER_BOX_MAX_HEIGHT_PX : float = 240.0


## `surface_info`: () -> the last SurfaceProbe.explain_under dictionary. `driven_vehicle`: () -> the
## Vehicle we drive, or null. Both answered by PlayerClient, which already knows. `star_map`: the
## chart (F2), if there is one: its readout, and the panel shown over it while it is open.
static func create(body: Node3D, animator: Node, surface_info: Callable, driven_vehicle: Callable,
		star_map: StarMap = null) -> OverlayPanel:
	var panel := OverlayPanel.new(OverlayPanel.Edge.RIGHT, WIDTH_PX, "", true)
	var toggles := DebugToggles.new()
	panel.add_child(toggles)
	var cache := ServerInfoCache.new()
	panel.add_child(cache)
	# The F8 capture previews show_debug for one frame: re-evaluate the moment a switch moves.
	panel.watch(toggles.changed, 0)
	var client := ClientReadout.new()
	var vehicle := VehicleReadout.new()
	var shown := func() -> bool: return toggles.is_on(&"show_debug")
	panel.add_section(ReadoutSection.new("", DevReadouts.clock_alert_lines, 0.25,
		DevReadouts.clock_alert_active, ReadoutSection.Tone.ALERT), true)
	panel.add_section(ReadoutSection.new("%%HUD_DEV_UNIVERSE",
		func() -> PackedStringArray: return DevReadouts.universe_lines(body, cache), 0.25, shown))
	panel.add_section(ReadoutSection.new("%%HUD_DEV_SERVER",
		func() -> PackedStringArray: return DevReadouts.server_lines(cache), 0.5, shown))
	var box := ReadoutSection.new("%%HUD_DEV_SERVER_BOX",
		func() -> PackedStringArray: return DevReadouts.box_lines(cache), 1.0, shown)
	box.max_height_px = SERVER_BOX_MAX_HEIGHT_PX
	panel.add_section(box)
	panel.add_section(ReadoutSection.new("%%HUD_DEV_CLIENT",
		func() -> PackedStringArray: return client.lines(body), 0.5, shown))
	panel.add_section(ReadoutSection.new("%%HUD_DEV_SURFACE",
		func() -> PackedStringArray: return DevReadouts.surface_lines(surface_info.call(), body), 0.25,
		func() -> bool: return toggles.is_on(&"surface_debug")))
	panel.add_section(ReadoutSection.new("%%HUD_DEV_MUSIC",
		func() -> PackedStringArray: return DevReadouts.music_lines(MusicDirector.debug_state()), 0.5,
		func() -> bool: return toggles.is_on(&"music_debug")))
	if star_map != null:
		panel.add_section(ReadoutSection.new("%%HUD_DEV_STAR_MAP", star_map.debug_lines, 0.25,
			func() -> bool: return toggles.is_on(&"star_map_debug") and star_map.is_open()))
		_show_over(panel, star_map)
	panel.add_section(ReadoutSection.new("%%HUD_DEV_MOVEMENT",
		func() -> PackedStringArray: return [ReadoutFormat.escape(animator.movement_debug_text())], 0.1,
		func() -> bool: return toggles.is_on(&"movement_debug") and is_instance_valid(animator)))
	panel.add_section(ReadoutSection.new("%%HUD_DEV_VEHICLE", vehicle.lines, 0.1,
		func() -> bool: return toggles.is_on(&"vehicle_hud") and driven_vehicle.call() != null,
		ReadoutSection.Tone.BODY,
		func(delta: float) -> void: vehicle.tick(driven_vehicle.call(), delta)))
	return panel


## The chart covers the whole screen from a higher layer: while it is open the panel goes over it, and
## the chart's info panel steps aside from the right edge whenever this one shows.
static func _show_over(panel: OverlayPanel, star_map: StarMap) -> void:
	var place := func() -> void:
		panel.layer = StarMap.LAYER + 1 if star_map.is_open() else OverlayPanel.LAYER
		star_map.set_right_inset(panel.footprint_px() if star_map.is_open() and panel.is_shown() else 0.0)
	star_map.visibility_changed.connect(place)
	panel.shown_changed.connect(place.unbind(1))
