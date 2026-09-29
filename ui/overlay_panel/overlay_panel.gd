class_name OverlayPanel
extends CanvasLayer
## A panel over the running game, on the left or right edge, filled with OverlaySections.
##
## One class for every such panel — the graphics options, the debug readouts, the tuning scene's
## controls — configured, never subclassed: what a panel SHOWS is its sections (composition), what
## it DOES is here, once:
##   - it shows while it is enabled, not hidden by the caller (the pause menu), and has at least one
##     active section; sections appear and disappear with their own gate;
##   - visibility is decided when the wanted state CHANGES and applied to the inner panel, never to
##     this CanvasLayer: the F7 photo hides every CanvasLayer for the frame it captures, and a panel
##     re-asserting "shown" every frame put itself back into the photo;
##   - the mouse stays with the camera. Holding AltGr hands it to the panels (all of them: one key,
##     whichever panel is under the pointer), releasing it gives it back. PlayerClient._ui_focus()
##     asks any_wants_pointer() every frame. While the pointer is not held, the panel takes neither
##     clicks nor keyboard focus, so a captured-mouse click can never land on it.
##   - while it holds the pointer it swallows keys (AltGr turns every key into Ctrl+Alt+key, and the
##     Alt shortcuts would fire) and the wheel outside every panel (it would change the walk speed).

enum Edge { LEFT, RIGHT }

## Below the settings page (5) and the star map (10): the pause menu covers the panels, not the reverse.
const LAYER : int = 4
const GROUP : StringName = &"overlay_panel"
const _MARGIN_PX : float = 12.0
const _PADDING_PX : float = 10.0
const _IDLE_ALPHA : float = 0.85

## Beyond its sections, whether the panel may show at all (the Settings > General switch…).
var enabled_rule : Callable = func() -> bool: return true
## Builds the sections' rows, at the panels' compact size.
var factory : SettingsRowFactory

var _fit_height : bool
var _can_take_pointer : Callable = func() -> bool: return true
var _must_hide : Callable = func() -> bool: return false
var _sections : Array[OverlaySection] = []
var _panel : PanelContainer
var _header : VBoxContainer
var _scroll : ScrollContainer
var _body : VBoxContainer
var _shown : bool = false
var _held : bool = false


## `fit_height`: grow with the content (capped to the window, then scroll) instead of spanning the
## whole height — for a panel whose sections come and go.
func _init(edge: Edge, width_px: float, hint_key: String = "", fit_height: bool = false) -> void:
	layer = LAYER
	add_to_group(GROUP)
	_fit_height = fit_height
	factory = SettingsRowFactory.new(15, 14, 150.0, true)
	_build_frame(edge, width_px, hint_key)


## Hand in the two questions only the caller can answer: may AltGr take the pointer right now (not
## while the player types in the chat — AltGr is how @ # { } are typed on AZERTY), and must the
## panel hide (the pause menu is open).
func setup(can_take_pointer: Callable, must_hide: Callable) -> OverlayPanel:
	_can_take_pointer = can_take_pointer
	_must_hide = must_hide
	return self


## `pinned`: above the scrolling part, always in view (the frame rate, an alert).
func add_section(section: OverlaySection, pinned: bool = false) -> OverlaySection:
	_sections.append(section)
	add_child(section)
	var content : VBoxContainer = section.build(factory)
	content.visible = false  # until reevaluate() finds it active
	(_header if pinned else _body).add_child(content)
	return section


## Re-evaluate at once when `sig` fires, rather than at the next frame: the F8 capture forces the
## debug panels on for ONE frame, and they must already be up to date in it.
func watch(sig: Signal, arg_count: int = 1) -> void:
	sig.connect(reevaluate if arg_count == 0 else reevaluate.unbind(arg_count))


## Which sections show, whether the panel shows; a section that just appeared is refreshed now.
func reevaluate() -> void:
	var any_active : bool = false
	var appeared : Array[OverlaySection] = []
	for section in _sections:
		var active : bool = section.is_active()
		any_active = any_active or active
		if active != section.box.visible:
			section.box.visible = active
			if active:
				appeared.append(section)
	var wanted : bool = any_active and bool(enabled_rule.call()) and not bool(_must_hide.call())
	if wanted != _shown:
		_shown = wanted
		_panel.visible = wanted
		if wanted:
			appeared = _active_sections()
		else:
			_set_held(false)
	if _shown:
		for section in appeared:
			section.restart()


func is_shown() -> bool:
	return _shown


func wants_pointer() -> bool:
	return _shown and _held


## Whether any panel in the tree holds the pointer: the one question PlayerClient needs answered.
static func any_wants_pointer(tree: SceneTree) -> bool:
	for panel in tree.get_nodes_in_group(GROUP):
		if (panel as OverlayPanel).wants_pointer():
			return true
	return false


func _ready() -> void:
	_set_held(false)
	reevaluate()


func _process(delta: float) -> void:
	reevaluate()
	if _pointer_wanted() != _held:
		_set_held(not _held)
	if not _shown:
		return
	for section in _active_sections():
		section.tick(delta)
	if _fit_height:
		_fit()


func _input(event: InputEvent) -> void:
	# AltGr itself rather than _held: a key pressed in the same frame as AltGr must be caught too.
	if not _pointer_wanted():
		return
	if event is InputEventKey:
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
			and not _over_a_panel(get_tree(), event.position):
		get_viewport().set_input_as_handled()


func _pointer_wanted() -> bool:
	if not _shown:
		return false
	return AltGr.is_held() and bool(_can_take_pointer.call())


func _set_held(on: bool) -> void:
	_held = on
	_panel.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED if on else Control.MOUSE_BEHAVIOR_DISABLED
	_panel.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED if on else Control.FOCUS_BEHAVIOR_DISABLED
	if not on and _panel.is_inside_tree():
		_panel.get_viewport().gui_release_focus()
	_panel.modulate.a = 1.0 if on else _IDLE_ALPHA


func _active_sections() -> Array[OverlaySection]:
	return _sections.filter(func(s: OverlaySection) -> bool: return s.box.visible)


## Grow with the content, up to the window's height; past it the body scrolls.
func _fit() -> void:
	var window_h : float = get_viewport().get_visible_rect().size.y
	var room : float = window_h - 2.0 * (_MARGIN_PX + _PADDING_PX) - _header.get_combined_minimum_size().y
	_scroll.custom_minimum_size.y = clampf(_body.get_combined_minimum_size().y, 0.0, maxf(room, 0.0))


static func _over_a_panel(tree: SceneTree, position: Vector2) -> bool:
	for panel in tree.get_nodes_in_group(GROUP):
		var overlay := panel as OverlayPanel
		if overlay.is_shown() and overlay._panel.get_global_rect().has_point(position):
			return true
	return false


func _build_frame(edge: Edge, width_px: float, hint_key: String) -> void:
	_panel = PanelContainer.new()
	_panel.visible = false  # until reevaluate() decides otherwise
	var left : bool = edge == Edge.LEFT
	_panel.anchor_left = 0.0 if left else 1.0
	_panel.anchor_right = _panel.anchor_left
	_panel.offset_left = _MARGIN_PX if left else -_MARGIN_PX - width_px
	_panel.offset_right = _panel.offset_left + width_px
	_panel.offset_top = _MARGIN_PX
	if not _fit_height:
		_panel.anchor_bottom = 1.0
		_panel.offset_bottom = -_MARGIN_PX
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.72)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(_PADDING_PX)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)
	var column := VBoxContainer.new()
	_panel.add_child(column)
	_header = VBoxContainer.new()
	column.add_child(_header)
	if hint_key != "":
		var hint := Label.new()
		hint.text = hint_key
		hint.add_theme_font_size_override("font_size", 13)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.modulate = Color(1, 1, 1, 0.7)
		column.add_child(hint)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)
