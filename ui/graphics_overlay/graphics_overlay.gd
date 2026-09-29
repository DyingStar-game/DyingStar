class_name GraphicsOverlay
extends CanvasLayer
## The rendering options on top of the running game, to compare their effect live.
##
## Switched on in Settings > General. It shows the same GraphicsOptionsView as the Graphics page —
## not a copy of it — plus the frame rate and the GPU time, so the cost of an option is read at the
## moment it is changed.
##
## The mouse stays with the camera. Holding AltGr hands it to the panel, releasing it gives it back:
## PlayerClient._ui_focus() asks wants_pointer() every frame, which frees the cursor, freezes the look
## and puts the mining tool down, exactly as for an in-world screen. While the pointer is NOT held,
## the panel neither takes clicks nor keyboard focus, so a captured-mouse click can never land on it.
##
## AltGr is the RIGHT Alt key. On Windows it also sends a fake left Ctrl, so every key pressed while
## it is held arrives as Ctrl+Alt+key — which would trigger the Alt shortcuts (Alt+T opens the spawn
## wheel, for one). Keys are swallowed while it is held for that reason. And it is left alone while
## the player types (chat, a screen's text field): on an AZERTY keyboard AltGr is how @ # { } are typed.

## Below the settings page (5) and the star map (10): the pause menu covers the overlay, not the reverse.
const LAYER : int = 4
const _WIDTH_PX : float = 470.0
const _MARGIN_PX : float = 12.0
const _STATS_PERIOD_S : float = 0.25

## Whether AltGr may take the pointer right now (false while the player types). Given by PlayerClient.
var _can_take_pointer : Callable = func() -> bool: return true
## Whether the overlay must hide (the pause menu is open). Given by PlayerClient.
var _must_hide : Callable = func() -> bool: return false
var _held : bool = false
var _panel : PanelContainer
var _stats : Label
var _stats_left : float = 0.0


## Hand in the two questions only the player's controller can answer.
func setup(can_take_pointer: Callable, must_hide: Callable) -> void:
	_can_take_pointer = can_take_pointer
	_must_hide = must_hide


## True while AltGr is held over a visible overlay: the cursor belongs to the panel.
func wants_pointer() -> bool:
	return visible and _held


func _ready() -> void:
	layer = LAYER
	_build()
	SettingsManager.render.overlay_changed.connect(_on_overlay_changed)
	# The GPU timer of the game view. ClientPerf may have switched it on already; either way it stays
	# on, which is harmless (a timestamp query per frame).
	RenderingServer.viewport_set_measure_render_time(get_tree().root.get_viewport_rid(), true)
	_set_held(false)
	_update_visibility()


func _process(delta: float) -> void:
	_update_visibility()
	if not visible:
		return
	_stats_left -= delta
	if _stats_left <= 0.0:
		_stats_left = _STATS_PERIOD_S
		_stats.text = "FPS %d  ·  GPU %.1f ms" % [Engine.get_frames_per_second(),
			RenderingServer.viewport_get_measured_render_time_gpu(get_tree().root.get_viewport_rid())]


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.keycode == KEY_ALT and event.location == KEY_LOCATION_RIGHT:
		if event.pressed and not event.echo and _can_take_pointer.call():
			_set_held(true)
			get_viewport().set_input_as_handled()
		elif not event.pressed and _held:
			_set_held(false)
			get_viewport().set_input_as_handled()
		return
	if not _held:
		return
	# See the class comment: every key now carries the fake Ctrl+Alt of AltGr.
	if event is InputEventKey:
		get_viewport().set_input_as_handled()
	# The wheel scrolls the panel under the pointer; anywhere else it would change the walk speed.
	elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
			and not _panel.get_global_rect().has_point(event.position):
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	# The release of a key pressed before alt-tabbing never arrives: do not keep the pointer forever.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_set_held(false)


func _on_overlay_changed(_on: bool) -> void:
	_update_visibility()


func _update_visibility() -> void:
	var wanted : bool = SettingsManager.render.is_overlay_enabled() and not _must_hide.call()
	if wanted != visible:
		visible = wanted
		if not wanted:
			_set_held(false)


func _set_held(on: bool) -> void:
	_held = on
	if _panel == null:
		return
	_panel.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED if on else Control.MOUSE_BEHAVIOR_DISABLED
	_panel.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED if on else Control.FOCUS_BEHAVIOR_DISABLED
	if not on and _panel.is_inside_tree():
		_panel.get_viewport().gui_release_focus()
	_panel.modulate.a = 1.0 if on else 0.85


## Right edge, full height: the scene being tuned stays in view on the left.
func _build() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -_WIDTH_PX - _MARGIN_PX
	_panel.offset_right = -_MARGIN_PX
	_panel.offset_top = _MARGIN_PX
	_panel.offset_bottom = -_MARGIN_PX
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.72)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)
	var column := VBoxContainer.new()
	_panel.add_child(column)
	var factory := SettingsRowFactory.new(15, 14, 150.0)
	_stats = factory.header("")
	_stats.uppercase = false
	column.add_child(_stats)
	var hint := Label.new()
	hint.text = "%%MENU_GFX_OVERLAY_HINT"
	hint.add_theme_font_size_override("font_size", 13)
	hint.modulate = SettingsStyle.INACTIVE_COLOR * Color(1, 1, 1, 0.7)
	column.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	var view := GraphicsOptionsView.new(factory)
	add_child(view)
	view.build(rows)
