class_name RadialMenu
extends Control

# Generic text-based radial (wheel) menu, reusable by any dev. Supports ONE level of submenus:
# a top-level entry with a "submenu" array is a CATEGORY — hovering it deploys its children as an
# arc further out, and releasing on a child emits that child's data.
# Usage:
#   var wheel := RadialMenu.new()
#   some_canvaslayer.add_child(wheel)
#   wheel.option_selected.connect(func(data): ...)
#   # hold a key, then open with a (possibly nested) list:
#   wheel.open([
#       { "text": "Rock", "submenu": [{ "text": "S", "data": "rock_s" }, { "text": "L", "data": "rock_l" }] },
#       { "text": "Box", "data": "box" },
#   ])
#   # on release:
#   wheel.confirm()
# Move the mouse toward a slice to highlight it; push further out over a category to reach its
# children. confirm() emits option_selected(data) for the highlighted leaf (or cancelled otherwise).

signal option_selected(data)
signal cancelled

@export var radius: float = 305.0
@export var inner_radius: float = 110.0
@export var font_size: int = 23
@export var title: String = ""
## How far past `radius` the submenu arc sits, and the angular gap (rad) between its children.
@export var submenu_radius_gap: float = 110.0
@export var submenu_spread: float = 0.42

var _options: Array = []
var _selected: int = -1      # hovered top-level slice (-1 = none)
var _sub_selected: int = -1  # hovered submenu child of _selected (-1 = none)

func _ready() -> void:
	# Independent of the parent's transform so the wheel always sits in viewport space.
	top_level = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_process(false)

## Open the wheel with a list of { "text", "data" } and/or { "text", "submenu": [...] } entries.
func open(options: Array) -> void:
	_options = options
	_selected = -1
	_sub_selected = -1
	visible = true
	set_process(true)
	queue_redraw()

func close() -> void:
	visible = false
	set_process(false)

## Emit the highlighted LEAF option (or cancelled) and close.
func confirm() -> void:
	var opt: Dictionary = _current_option()
	if opt.has("data"):
		option_selected.emit(opt["data"])
	else:
		cancelled.emit()
	close()

## The option a release acts on: a hovered submenu child, else a hovered LEAF top entry. Empty
## dict when nothing actionable is hovered (center, or a category with no child picked → cancel).
func _current_option() -> Dictionary:
	if _selected < 0 or _selected >= _options.size():
		return {}
	var top: Dictionary = _options[_selected]
	var sub: Array = top.get("submenu", [])
	if sub.is_empty():
		return top  # leaf top-level entry (e.g. Dépôt / Camion)
	if _sub_selected >= 0 and _sub_selected < sub.size():
		return sub[_sub_selected]
	return {}  # hovering a category but no child → nothing to spawn

## Clockwise-from-top angle of submenu child `j` of category `top_i` (m children), centered on the
## category's own direction and spread by submenu_spread.
func _submenu_child_angle(top_i: int, j: int, m: int) -> float:
	var base := float(top_i) / _options.size() * TAU
	return base + (float(j) - float(m - 1) / 2.0) * submenu_spread

func _process(_delta: float) -> void:
	var center := get_viewport_rect().size / 2.0
	var v := get_local_mouse_position() - center
	var dist := v.length()
	if _options.is_empty() or dist < inner_radius:
		_selected = -1
		_sub_selected = -1
	elif dist <= radius:
		# In the main ring: pick the top-level slice by angle (0 at top, clockwise).
		var ang := wrapf(atan2(v.x, -v.y), 0.0, TAU)
		_selected = int(round(ang / TAU * _options.size())) % _options.size()
		_sub_selected = -1
	else:
		# Pushed OUT past the ring: KEEP the engaged category (sticky) and pick among ITS children
		# only, so moving toward a child never re-selects a neighbouring top-level slice.
		var sub: Array = [] if _selected < 0 else _options[_selected].get("submenu", [])
		_sub_selected = _nearest_child(v, sub)
	queue_redraw()

## Index of the submenu child of `_selected` nearest the mouse vector `v` (by angle), or -1.
func _nearest_child(v: Vector2, sub: Array) -> int:
	if sub.is_empty():
		return -1
	var ang := wrapf(atan2(v.x, -v.y), 0.0, TAU)
	var best := -1
	var best_d := INF
	for j in sub.size():
		var d := absf(wrapf(ang - _submenu_child_angle(_selected, j, sub.size()), -PI, PI))
		if d < best_d:
			best_d = d
			best = j
	return best

func _draw() -> void:
	if _options.is_empty():
		return
	var center := get_viewport_rect().size / 2.0
	var font := get_theme_default_font()
	# Dim circular backdrop.
	draw_circle(center, radius + 16.0, Color(0.0, 0.0, 0.0, 0.55))
	draw_circle(center, inner_radius, Color(0.0, 0.0, 0.0, 0.5))
	var n := _options.size()
	for i in n:
		var a := float(i) / n * TAU - PI / 2.0
		var pos := center + Vector2(cos(a), sin(a)) * ((radius + inner_radius) / 2.0)
		var is_category: bool = not _options[i].get("submenu", []).is_empty()
		var text: String = str(_options[i].get("text", ""))
		if is_category:
			text += " ▸"  # marks an entry that opens a submenu
		var col := Color(1, 1, 1)
		# Highlight the top slice unless we've reached one of its children.
		if i == _selected and _sub_selected < 0:
			col = Color(1.0, 0.85, 0.2)
			draw_circle(pos, font_size * 1.7, Color(1, 1, 1, 0.18))
		_draw_label(font, pos, text, col)
	# Submenu arc for the selected category, over a gray background band.
	if _selected >= 0:
		var sub: Array = _options[_selected].get("submenu", [])
		if not sub.is_empty():
			var m := sub.size()
			var sub_r := radius + submenu_radius_gap
			var a0 := _submenu_child_angle(_selected, 0, m) - PI / 2.0 - submenu_spread * 0.6
			var a1 := _submenu_child_angle(_selected, m - 1, m) - PI / 2.0 + submenu_spread * 0.6
			draw_arc(center, sub_r, a0, a1, 48, Color(0.0, 0.0, 0.0, 0.55), font_size * 2.8, true)
			for j in m:
				var da := _submenu_child_angle(_selected, j, m) - PI / 2.0
				var pos := center + Vector2(cos(da), sin(da)) * sub_r
				var col := Color(1, 1, 1)
				if j == _sub_selected:
					col = Color(1.0, 0.85, 0.2)
					draw_circle(pos, font_size * 1.6, Color(1, 1, 1, 0.2))
				_draw_label(font, pos, str(sub[j].get("text", "")), col)
	# Title / current selection in the center.
	var cur: Dictionary = _current_option()
	var center_text: String = title
	if not cur.is_empty():
		center_text = str(cur.get("text", title))
	elif _selected >= 0:
		center_text = str(_options[_selected].get("text", ""))
	if center_text != "":
		_draw_label(font, center, center_text, Color(1, 1, 1))

func _draw_label(font: Font, pos: Vector2, text: String, col: Color) -> void:
	var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	font.draw_string(get_canvas_item(), pos - Vector2(ts.x / 2.0, -font_size / 3.0),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
