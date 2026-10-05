class_name BadgedPicture
extends Control
## A device picture (the gamepad, the mouse) fitted in its rect, its aspect kept, with the numbers of the
## help's lines laid on the spots they use: the legend beside it says what each number does.

## Diameter of a number badge, as a share of the drawn picture's width.
const BADGE_SHARE : float = 0.045
## The mark of a spot that does something the legend does not list: hover it to know.
const MORE_MARK : String = "?"
## Smallest badge (px), however small the picture is drawn.
const BADGE_MIN_PX : float = 22.0

## The picture, drawn with its aspect kept, centred.
var texture : Texture2D
## Spot -> its place on the picture, in shares of its width and height (0..1).
var spots : Dictionary = {}
## Spot -> the numbers to show there.
var numbers : Dictionary = {}
## Spot -> what it does, shown while the pointer rests on it.
var tips : Dictionary = {}
## The picture's largest size, as a share of its box (0..1): a big picture (the gamepad) filled the
## whole height and crowded the screen; it is drawn smaller, centred.
var max_share : float = 1.0
## Reach of a spot for the pointer, as a share of the drawn picture's width.
const HOVER_SHARE : float = 0.05

var _area : Rect2 = Rect2()


func _init(picture: Texture2D, spot_places: Dictionary) -> void:
	texture = picture
	spots = spot_places
	mouse_filter = Control.MOUSE_FILTER_PASS  # the pointer over a spot shows what it does
	resized.connect(queue_redraw)


func _draw() -> void:
	if texture == null:
		return
	var area : Rect2 = fitted(texture.get_size(), size * max_share)
	area.position += size * (1.0 - max_share) * 0.5  # centred in the whole box
	_area = area
	draw_texture_rect(texture, area, false)
	var badge : float = maxf(area.size.x * BADGE_SHARE, BADGE_MIN_PX)
	for spot: String in numbers:
		if not spots.has(spot):
			continue
		var at : Vector2 = area.position + area.size * (spots[spot] as Vector2)
		draw_badge(self, at, joined(numbers[spot]), badge)
	# A spot that does something outside the legend still says so, or nobody would think to hover it.
	for spot: String in tips:
		if spots.has(spot) and not numbers.has(spot):
			draw_badge(self, area.position + area.size * (spots[spot] as Vector2), MORE_MARK, badge * 0.8)


## What the spot under [param at] does, or "" (no tooltip).
func _get_tooltip(at: Vector2) -> String:
	return spot_tip(tips, spots, _area, at, maxf(_area.size.x * HOVER_SHARE, BADGE_MIN_PX))


## The tip of the spot of [param places] within [param reach] px of [param at], drawn over [param area].
static func spot_tip(tip_texts: Dictionary, places: Dictionary, area: Rect2, at: Vector2, reach: float) -> String:
	var best : String = ""
	var best_distance : float = reach
	for spot: String in tip_texts:
		if not places.has(spot):
			continue
		var distance : float = at.distance_to(area.position + area.size * (places[spot] as Vector2))
		if distance <= best_distance:
			best_distance = distance
			best = tip_texts[spot]
	return best


## The rect a picture of [param picture_size] takes in [param box], aspect kept, centred.
static func fitted(picture_size: Vector2, box: Vector2) -> Rect2:
	if picture_size.x <= 0.0 or picture_size.y <= 0.0:
		return Rect2(Vector2.ZERO, box)
	var scale : float = minf(box.x / picture_size.x, box.y / picture_size.y)
	var drawn : Vector2 = picture_size * scale
	return Rect2((box - drawn) * 0.5, drawn)


## A dark disc ringed in amber with [param text] in amber, [param diameter] px high (wider for "4·12"),
## centred on [param at] — the mark the legend's numbers answer to. Dark, not amber: it sits on lit
## (amber) keys, where an amber badge disappeared.
static func draw_badge(canvas: CanvasItem, at: Vector2, text: String, diameter: float) -> void:
	var font : Font = SettingsRowFactory.FONT
	var font_size : int = int(diameter * 0.55)
	var text_size : Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var width : float = maxf(diameter, text_size.x + diameter * 0.5)
	var box := Rect2(at - Vector2(width, diameter) * 0.5, Vector2(width, diameter))
	var style := StyleBoxFlat.new()
	style.bg_color = ControlsHelp.INK
	style.set_corner_radius_all(int(diameter * 0.5))
	style.border_color = ControlsHelp.ACCENT
	style.set_border_width_all(2)
	canvas.draw_style_box(style, box)
	var baseline := Vector2(at.x - text_size.x * 0.5, at.y + font.get_ascent(font_size) * 0.5 - 1.0)
	canvas.draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ControlsHelp.ACCENT)


## Several numbers on one spot (a button that does two things): "4·17".
static func joined(list: PackedInt32Array) -> String:
	var parts := PackedStringArray()
	for n: int in list:
		parts.append(str(n))
	return "·".join(parts)
