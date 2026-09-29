class_name GraphicsOverlay
extends RefCounted
## The rendering options over the running game, to compare their effect live: an OverlayPanel on the
## left edge with the frame rate / GPU time and the same GraphicsOptionsView as the Graphics page —
## not a copy of it. Built here, by composition; the panel does the rest (see OverlayPanel).

const WIDTH_PX : float = 470.0


## In game: switched on in Settings > General, the mouse taken while AltGr is held.
static func in_game() -> OverlayPanel:
	var panel := OverlayPanel.new(OverlayPanel.Edge.LEFT, WIDTH_PX, "%%MENU_GFX_OVERLAY_HINT")
	panel.enabled_rule = func() -> bool: return SettingsManager.render.is_overlay_enabled()
	panel.watch(SettingsManager.render.overlay_changed)
	return _compose(panel, [])


## Always shown and always interactive, with `extra` sections pinned above the options (the tuning
## scene's viewpoints and hour) and `lead` ones above everything (its way back). Never touches the
## Settings > General switch.
static func always_on(extra: Array[OverlaySection], lead: Array[OverlaySection] = []) -> OverlayPanel:
	var panel := OverlayPanel.new(OverlayPanel.Edge.LEFT, WIDTH_PX)
	panel.pointer_mode = OverlayPanel.PointerMode.ALWAYS
	for section in lead:
		panel.add_section(section, true)
	return _compose(panel, extra)


static func _compose(panel: OverlayPanel, extra: Array[OverlaySection]) -> OverlayPanel:
	panel.add_section(ReadoutSection.new("", PerfReadout.lines, 0.25), true)
	for section in extra:
		panel.add_section(section, true)
	panel.add_section(WidgetSection.new("", _build_options))
	return panel


static func _build_options(owner: Node, content: VBoxContainer, factory: SettingsRowFactory) -> void:
	var view := GraphicsOptionsView.new(factory)
	owner.add_child(view)
	view.build(content)
