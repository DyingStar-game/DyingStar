class_name StarMapGestures
extends RefCounted

## The chart's mouse gestures, Google Maps' way: a press that moves past DRAG_PX is a DRAG (left: move
## the map, right: zoom, Ctrl + left: turn the view); one that does not is a CLICK, taken when the
## button comes back up (left: select or drop a pin, right: the context menu).
##
## Only tells a click from a drag and owns the context menu: what a click selects, where the ground is
## under the cursor and how the view moves stay the chart's (StarMap), which this calls back.

## Pixels a press may travel and still be a click.
const DRAG_PX: float = 4.0
## Zoom per pixel of a right-button drag, down = closer (as Google Maps' own).
const ZOOM_DRAG_RATE: float = 0.01
## The ids of the two lines the mission marker adds to the context menu (see [method open_context]).
## Out of the vanilla three's way (0..2), and fixed because they are the ids the handler answers by.
const MISSION_SET: int = 3
const MISSION_CLEAR: int = 4

var _map: StarMap = null
## {"action", "button", "at", "travel", "moved"} while a button is down, {} otherwise.
var _press: Dictionary = {}
var _context: PopupMenu = null
var _context_point: Dictionary = {}  # the point the context menu was opened on ({} for none)


## Gestures for [param map], with the context menu added under [param host] (the chart's face), so it
## opens over the chart and goes with it.
func _init(map: StarMap, host: Control) -> void:
	_map = map
	_context = PopupMenu.new()
	_context.id_pressed.connect(_on_context_chosen)
	host.add_child(_context)


## The chart closed: a button held as it closed must not pan the next opening, and the menu goes.
func reset() -> void:
	_press = {}
	if is_instance_valid(_context):
		_context.hide()


## A mouse button went down on the chart: a click or a drag, told apart once it moves (DRAG_PX).
func begin_press(action: StringName, mouse: InputEventMouseButton) -> void:
	_press = {"action": action, "button": mouse.button_index, "at": mouse.position, "travel": 0.0,
			"moved": false}


## The mouse while a press is down (from StarMap._input, ahead of the GUI, so a drag across a panel
## keeps going); true when it was the press's. Moving: the drag of its button. Released: its click,
## unless it had moved. False at once while no button is down.
func input(event: InputEvent) -> bool:
	if _press.is_empty():
		return false
	var motion := event as InputEventMouseMotion
	if motion != null:
		_press["travel"] = float(_press["travel"]) + motion.relative.length()
		if not bool(_press["moved"]):
			if float(_press["travel"]) <= DRAG_PX:
				return false  # still a click: the hover goes on as usual
			_press["moved"] = true
			_map._pins.clear_pin()
		match StringName(_press["action"]):
			&"star_map_menu":
				var factor: float = exp(motion.relative.y * ZOOM_DRAG_RATE)
				# Mirrors the wheel (see StarMap._mission_radius_step): the drag that would move the
				# view closer widens the zone instead, so every zoom gesture means the same thing
				# while a marker stands — and the zone keeps the same feel under the hand as the view.
				var wide: bool = factor < 1.0
				if not _map._mission_radius_step(wide, maxf(factor, 1.0 / factor)):
					_map._zoom_by(factor)
			_:
				_map._turn_view(motion.relative)  # the map moves with the mouse; Ctrl: over a station, round it
		return true
	var button := event as InputEventMouseButton
	if button == null or button.pressed or button.button_index != int(_press["button"]):
		return false
	var press: Dictionary = _press
	_press = {}
	if not bool(press["moved"]):
		var at: Vector2 = press["at"]
		match StringName(press["action"]):
			&"star_map_select":
				_map._click_at(at, false)
				# On the ground, nothing else under the cursor: the pin, to read where it is.
				_map._pins.pin = {} if _map._named_under(at) else _map._point_under(at)
			&"star_map_menu":
				open_context(at)
	return true


## The context menu (right click), at [param at]: copy the coordinates of the ground there, set the
## marker there, or take the marker away — and, while the chart is answering a form's "where", lay the
## mission marker (the only thing that CAN answer: see StarMap.begin_poi_place) or take it back.
func open_context(at: Vector2) -> void:
	_map._pins.clear_pin()
	_context_point = _map._point_under(at)
	_context.clear()
	_context.add_item("%%HUD_MAP_COPY_COORDS", 0)
	_context.set_item_disabled(_context.get_item_index(0), _context_point.is_empty())
	_context.add_item("%%HUD_MAP_MARKER_SET", 1)
	_context.set_item_disabled(_context.get_item_index(1), _context_point.is_empty())
	if not _map._pins.marker.is_empty():
		_context.add_item("%%HUD_MAP_MARKER_CLEAR", 2)
	# Armed, and only then: over empty space the line is there but dead, the same way "Put a marker
	# here" is — a place needs a body to stand on, and the menu says so by graying rather than by
	# vanishing (the player asked a question by right-clicking; silence would read as no answer).
	if _map.is_placing_poi():
		_context.add_item("%%HUD_MAP_MISSION_SET", MISSION_SET)
		_context.set_item_disabled(_context.get_item_index(MISSION_SET), _context_point.is_empty())
		if _map._has_mission_repere():
			_context.add_item("%%HUD_MAP_MISSION_CLEAR", MISSION_CLEAR)
	_context.reset_size()
	var host: Control = _context.get_parent()
	_context.popup(Rect2i(Vector2i(host.get_global_rect().position + at), Vector2i.ZERO))


## One line of the context menu chosen: the ids are the ones open_context gave its items.
func _on_context_chosen(id: int) -> void:
	match id:
		0:
			if not _context_point.is_empty():
				DisplayServer.clipboard_set(coordinates_text(_context_point["local"]))
		1:
			_map._pins.marker = _context_point
		2:
			_map._pins.marker = {}
		MISSION_SET:
			# From the point the menu OPENED on, not on whatever is under the cursor now: the two
			# can differ by the whole screen if the view turned while the menu was up.
			if not _context_point.is_empty():
				_map._set_mission_repere(_context_point)
		MISSION_CLEAR:
			_map._clear_mission_repere()
			# The cross the marker borrowed goes with it. The pin was already cleared when the menu
			# opened, but the marker's own refresh re-asserts it every frame — until this moment.
			_map._pins.clear_pin()


## The coordinates of [param local] (a body's unit direction) as they are copied: "latitude, longitude"
## in degrees to six decimals (some 10 cm), Google Maps' order. Static and pure.
static func coordinates_text(local: Vector3) -> String:
	var lonlat: Vector2 = HEALPix.vec2lonlat(local)
	return "%.6f, %.6f" % [lonlat.y, lonlat.x]
