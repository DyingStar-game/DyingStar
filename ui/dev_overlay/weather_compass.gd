class_name WeatherCompass
extends Control
## A compass dial in the bottom-right corner, beside the debug panel's Weather section (Settings: Weather
## debug): the top of the dial is where the camera looks, the cardinal letters turn around it, and an
## arrow shows where the wind blows TO, its length growing with the speed. Read with the panel's own
## figures (DevReadouts.compass_state), so the dial and the text never disagree.

## Dial radius (px).
const RADIUS_PX : float = 62.0
## Gap from the window's right and bottom edges (px): clear of the "F9" hint in the corner.
const MARGIN_PX : Vector2 = Vector2(28.0, 56.0)
## Wind speed (m/s) at which the arrow reaches the dial's rim; slower winds draw shorter arrows.
const FULL_ARROW_M_S : float = 20.0
## Cardinal letters, as the localisation keys of N, E, S, W, by bearing.
const CARDINALS : Dictionary = {0.0: "%%COMPASS_N", 90.0: "%%COMPASS_E", 180.0: "%%COMPASS_S", 270.0: "%%COMPASS_W"}
const DIAL_COLOUR : Color = Color(0.05, 0.08, 0.12, 0.78)
const RIM_COLOUR : Color = Color(0.85, 0.72, 0.45, 0.95)
const TICK_COLOUR : Color = Color(0.9, 0.9, 0.9, 0.8)
const NORTH_COLOUR : Color = Color(1.0, 0.35, 0.3)
const WIND_COLOUR : Color = Color(0.45, 0.85, 1.0)

## () -> DevReadouts.compass_state of the player, {} when there is nothing to show.
var state_source : Callable = func() -> Dictionary: return {}
## () -> bool: whether the dial may show at all (the switch, the panel shown).
var shown_rule : Callable = func() -> bool: return false

var _state : Dictionary = {}
var _said_not_finite : bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	var side : float = 2.0 * RADIUS_PX + 24.0
	offset_left = -side - MARGIN_PX.x
	offset_top = -side - MARGIN_PX.y
	offset_right = -MARGIN_PX.x
	offset_bottom = -MARGIN_PX.y


func _process(_delta: float) -> void:
	var wanted : bool = bool(shown_rule.call())
	_state = state_source.call() if wanted else {}
	visible = wanted and not _state.is_empty()
	if visible:
		queue_redraw()


func _draw() -> void:
	var centre : Vector2 = size * 0.5
	var heading : float = float(_state.get("heading_deg", 0.0))
	# A size or a heading that is not a number draws nothing but one warning per line, every frame (the Nova
	# game view filled gigabytes of log that way): skip the frame, and say it once.
	if not centre.is_finite() or not is_finite(heading):
		if not _said_not_finite:
			_said_not_finite = true
			push_warning("WeatherCompass: not drawn, size %s heading %s" % [size, heading])
		return
	draw_circle(centre, RADIUS_PX, DIAL_COLOUR)
	draw_arc(centre, RADIUS_PX, 0.0, TAU, 64, RIM_COLOUR, 3.0, true)
	for bearing in range(0, 360, 30):
		var inner : float = RADIUS_PX - (10.0 if bearing % 90 == 0 else 5.0)
		draw_line(dial_point(centre, inner, bearing, heading), dial_point(centre, RADIUS_PX - 2.0, bearing, heading),
				TICK_COLOUR, 2.0, true)
	var font : Font = ThemeDB.fallback_font
	for bearing: float in CARDINALS:
		var letter : String = tr(CARDINALS[bearing])
		var at : Vector2 = dial_point(centre, RADIUS_PX - 22.0, bearing, heading)
		var text_size : Vector2 = font.get_string_size(letter, HORIZONTAL_ALIGNMENT_CENTER, -1, 18)
		draw_string(font, at + Vector2(-text_size.x * 0.5, text_size.y * 0.32), letter, HORIZONTAL_ALIGNMENT_CENTER,
				-1, 18, NORTH_COLOUR if bearing == 0.0 else TICK_COLOUR)
	# Where we look: the fixed notch at the top of the dial.
	draw_colored_polygon(PackedVector2Array([centre + Vector2(0.0, -RADIUS_PX - 8.0),
			centre + Vector2(-7.0, -RADIUS_PX + 4.0), centre + Vector2(7.0, -RADIUS_PX + 4.0)]), RIM_COLOUR)
	var speed : float = float(_state.get("wind_m_s", 0.0))
	if speed >= DevReadouts.CALM_M_S:
		_draw_wind(centre, fmod(float(_state.get("wind_from_deg", 0.0)) + 180.0, 360.0), heading, speed, font)


## Where the wind goes, as an arrow from the centre, and its speed under the dial.
func _draw_wind(centre: Vector2, toward_deg: float, heading: float, speed: float, font: Font) -> void:
	var length : float = (RADIUS_PX - 14.0) * clampf(speed / FULL_ARROW_M_S, 0.25, 1.0)
	var tip : Vector2 = dial_point(centre, length, toward_deg, heading)
	var tail : Vector2 = dial_point(centre, length * 0.55, toward_deg + 180.0, heading)
	draw_line(tail, tip, WIND_COLOUR, 4.0, true)
	var back : Vector2 = (tail - tip).normalized()
	var side : Vector2 = Vector2(-back.y, back.x)
	draw_colored_polygon(PackedVector2Array([tip, tip + back * 14.0 + side * 8.0, tip + back * 14.0 - side * 8.0]),
			WIND_COLOUR)
	var label : String = "%.1f m/s · %.0f km/h" % [speed, speed * 3.6]
	var text_size : Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, 14)
	draw_string(font, Vector2(centre.x - text_size.x * 0.5, size.y - 2.0), label, HORIZONTAL_ALIGNMENT_CENTER, -1, 14,
			WIND_COLOUR)


## The point at [param radius] from [param centre] in the direction of compass [param bearing] (degrees),
## on a dial whose top is [param heading]: north is drawn at -heading, east 90° clockwise from it.
static func dial_point(centre: Vector2, radius: float, bearing: float, heading: float) -> Vector2:
	var angle : float = deg_to_rad(bearing - heading)
	return centre + Vector2(sin(angle), -cos(angle)) * radius
