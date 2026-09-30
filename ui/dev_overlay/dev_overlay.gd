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
##   Movement     speed, walk target, clip, vault / step                  (Settings: Movement debug)
##   Vehicle      the driver's readout while driving                    (Settings: Vehicle dashboard)
##
## Built here by composition; the panel does the rest (see OverlayPanel). The toggles and the server
## values live as children of the panel, so they go with it.

const WIDTH_PX : float = 400.0
## About three zones with their bounds; a longer list scrolls on its own.
const SERVER_BOX_MAX_HEIGHT_PX : float = 240.0


## `surface_info`: () -> the last SurfaceProbe.explain_under dictionary. `driven_vehicle`: () -> the
## Vehicle we drive, or null. Both answered by PlayerClient, which already knows.
static func create(body: Node3D, animator: Node, surface_info: Callable, driven_vehicle: Callable) -> OverlayPanel:
	var panel := OverlayPanel.new(OverlayPanel.Edge.RIGHT, WIDTH_PX, "", true)
	var toggles := DebugToggles.new()
	panel.add_child(toggles)
	var cache := ServerInfoCache.new()
	panel.add_child(cache)
	# The F8 capture forces show_debug for one frame: re-evaluate the moment a toggle moves.
	panel.watch(toggles.changed, 0)
	var client := ClientReadout.new()
	var vehicle := VehicleReadout.new()
	var shown := func() -> bool: return toggles.show_debug
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
		func() -> bool: return toggles.surface))
	panel.add_section(ReadoutSection.new("%%HUD_DEV_MUSIC",
		func() -> PackedStringArray: return DevReadouts.music_lines(MusicDirector.debug_state()), 0.5,
		func() -> bool: return toggles.music))
	panel.add_section(ReadoutSection.new("%%HUD_DEV_MOVEMENT",
		func() -> PackedStringArray: return [ReadoutFormat.escape(animator.movement_debug_text())], 0.1,
		func() -> bool: return toggles.movement and is_instance_valid(animator)))
	panel.add_section(ReadoutSection.new("%%HUD_DEV_VEHICLE", vehicle.lines, 0.1,
		func() -> bool: return toggles.vehicle_hud and driven_vehicle.call() != null,
		ReadoutSection.Tone.BODY,
		func(delta: float) -> void: vehicle.tick(driven_vehicle.call(), delta)))
	return panel
