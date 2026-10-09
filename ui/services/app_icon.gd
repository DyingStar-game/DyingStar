class_name ServiceAppIcon
extends Control

## A monochrome vector glyph for a tablet app, drawn in code — the project ships no app-icon set, so
## the marks live here rather than as assets. Each one is a small, flat pictogram in the accent colour,
## kept to the same visual family (rounded corners, even stroke, generous margins) so the app grid
## reads as one system.

enum Kind { IDENTITY, CONTACTS, CORPORATIONS, MISSIONS, BANK, REPORTS, DIAGNOSTICS, INVENTORY, MARKET, SQUAD, POIS }

@export var kind: Kind = Kind.IDENTITY
@export var colour: Color = Color(1, 1, 1, 1)


func _init() -> void:
	custom_minimum_size = Vector2(44, 44)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var side: float = minf(size.x, size.y)
	if side <= 0.0:
		return
	var origin := Vector2((size.x - side) * 0.5, (size.y - side) * 0.5)
	var stroke: float = maxf(2.0, side * 0.055)
	match kind:
		Kind.IDENTITY:
			_identity(origin, side, stroke)
		Kind.CONTACTS:
			_contacts(origin, side, stroke)
		Kind.CORPORATIONS:
			_corporations(origin, side, stroke)
		Kind.MISSIONS:
			_missions(origin, side, stroke)
		Kind.BANK:
			_bank(origin, side, stroke)
		Kind.REPORTS:
			_reports(origin, side, stroke)
		Kind.DIAGNOSTICS:
			_diagnostics(origin, side, stroke)
		Kind.INVENTORY:
			_inventory(origin, side, stroke)
		Kind.MARKET:
			_market(origin, side, stroke)
		Kind.SQUAD:
			_squad(origin, side, stroke)
		Kind.POIS:
			_pois(origin, side, stroke)


func _p(origin: Vector2, side: float, x: float, y: float) -> Vector2:
	return origin + Vector2(x, y) * side


## An ID card: rounded frame, a portrait bust, and two text lines.
func _identity(o: Vector2, s: float, w: float) -> void:
	draw_rect(Rect2(_p(o, s, 0.08, 0.20), Vector2(0.84, 0.60) * s), colour, false, w, true)
	draw_circle(_p(o, s, 0.30, 0.42), 0.085 * s, colour)
	draw_arc(_p(o, s, 0.30, 0.62), 0.14 * s, PI, TAU, 24, colour, w, true)
	draw_line(_p(o, s, 0.50, 0.40), _p(o, s, 0.84, 0.40), colour, w, true)
	draw_line(_p(o, s, 0.50, 0.52), _p(o, s, 0.80, 0.52), colour, w, true)
	draw_line(_p(o, s, 0.19, 0.68), _p(o, s, 0.47, 0.68), colour, w, true)


## Two people: a front bust and a smaller one behind it.
func _contacts(o: Vector2, s: float, w: float) -> void:
	draw_circle(_p(o, s, 0.62, 0.40), 0.085 * s, colour)
	draw_arc(_p(o, s, 0.62, 0.66), 0.15 * s, PI, TAU, 24, colour, w, true)
	draw_circle(_p(o, s, 0.36, 0.34), 0.12 * s, colour)
	draw_arc(_p(o, s, 0.36, 0.66), 0.21 * s, PI, TAU, 28, colour, w, true)


## A corporation: an org chart, one head over two members.
func _corporations(o: Vector2, s: float, w: float) -> void:
	draw_rect(Rect2(_p(o, s, 0.40, 0.10), Vector2(0.20, 0.14) * s), colour, false, w, true)
	draw_line(_p(o, s, 0.50, 0.24), _p(o, s, 0.50, 0.38), colour, w, true)
	draw_line(_p(o, s, 0.20, 0.38), _p(o, s, 0.80, 0.38), colour, w, true)
	draw_line(_p(o, s, 0.20, 0.38), _p(o, s, 0.20, 0.52), colour, w, true)
	draw_line(_p(o, s, 0.80, 0.38), _p(o, s, 0.80, 0.52), colour, w, true)
	draw_rect(Rect2(_p(o, s, 0.08, 0.52), Vector2(0.24, 0.16) * s), colour, false, w, true)
	draw_rect(Rect2(_p(o, s, 0.68, 0.52), Vector2(0.24, 0.16) * s), colour, false, w, true)


## A mission: a target with a crosshair.
func _missions(o: Vector2, s: float, w: float) -> void:
	var c: Vector2 = _p(o, s, 0.5, 0.5)
	draw_arc(c, 0.34 * s, 0, TAU, 48, colour, w, true)
	draw_arc(c, 0.19 * s, 0, TAU, 40, colour, w, true)
	draw_circle(c, 0.045 * s, colour)
	draw_line(_p(o, s, 0.5, 0.06), _p(o, s, 0.5, 0.18), colour, w, true)
	draw_line(_p(o, s, 0.5, 0.82), _p(o, s, 0.5, 0.94), colour, w, true)
	draw_line(_p(o, s, 0.06, 0.5), _p(o, s, 0.18, 0.5), colour, w, true)
	draw_line(_p(o, s, 0.82, 0.5), _p(o, s, 0.94, 0.5), colour, w, true)


## A bank: a pediment over three columns on a base.
func _bank(o: Vector2, s: float, w: float) -> void:
	var roof := PackedVector2Array([
		_p(o, s, 0.12, 0.38), _p(o, s, 0.50, 0.14), _p(o, s, 0.88, 0.38), _p(o, s, 0.12, 0.38)])
	draw_polyline(roof, colour, w, true)
	draw_line(_p(o, s, 0.10, 0.44), _p(o, s, 0.90, 0.44), colour, w, true)
	for x: float in [0.24, 0.50, 0.76]:
		draw_line(_p(o, s, x, 0.52), _p(o, s, x, 0.78), colour, w, true)
	draw_line(_p(o, s, 0.12, 0.84), _p(o, s, 0.88, 0.84), colour, w, true)


## A report: a warning triangle with an exclamation.
func _reports(o: Vector2, s: float, w: float) -> void:
	var warning := PackedVector2Array([
		_p(o, s, 0.50, 0.12), _p(o, s, 0.90, 0.84), _p(o, s, 0.10, 0.84), _p(o, s, 0.50, 0.12)])
	draw_polyline(warning, colour, w, true)
	draw_line(_p(o, s, 0.50, 0.40), _p(o, s, 0.50, 0.62), colour, w, true)
	draw_circle(_p(o, s, 0.50, 0.72), 0.035 * s, colour)


## Diagnostics: a heartbeat trace.
func _diagnostics(o: Vector2, s: float, w: float) -> void:
	var trace := PackedVector2Array([
		_p(o, s, 0.08, 0.56), _p(o, s, 0.30, 0.56), _p(o, s, 0.40, 0.28),
		_p(o, s, 0.52, 0.80), _p(o, s, 0.62, 0.56), _p(o, s, 0.92, 0.56)])
	draw_polyline(trace, colour, w, true)


## Inventory: a crate with a lid line and a clasp.
func _inventory(o: Vector2, s: float, w: float) -> void:
	draw_rect(Rect2(_p(o, s, 0.12, 0.28), Vector2(0.76, 0.56) * s), colour, false, w, true)
	draw_line(_p(o, s, 0.12, 0.42), _p(o, s, 0.88, 0.42), colour, w, true)
	draw_rect(Rect2(_p(o, s, 0.42, 0.36), Vector2(0.16, 0.12) * s), colour, false, maxf(w * 0.8, 1.0), true)


## Market: two opposing arrows, an exchange.
func _market(o: Vector2, s: float, w: float) -> void:
	draw_line(_p(o, s, 0.18, 0.38), _p(o, s, 0.78, 0.38), colour, w, true)
	draw_line(_p(o, s, 0.68, 0.28), _p(o, s, 0.80, 0.38), colour, w, true)
	draw_line(_p(o, s, 0.68, 0.48), _p(o, s, 0.80, 0.38), colour, w, true)
	draw_line(_p(o, s, 0.82, 0.62), _p(o, s, 0.22, 0.62), colour, w, true)
	draw_line(_p(o, s, 0.32, 0.52), _p(o, s, 0.20, 0.62), colour, w, true)
	draw_line(_p(o, s, 0.32, 0.72), _p(o, s, 0.20, 0.62), colour, w, true)


## Squad: three heads in a triangle formation, linked — a temporary group, not an org chart.
func _squad(o: Vector2, s: float, w: float) -> void:
	var top: Vector2 = _p(o, s, 0.50, 0.30)
	var left: Vector2 = _p(o, s, 0.26, 0.70)
	var right: Vector2 = _p(o, s, 0.74, 0.70)
	draw_line(left, right, colour, w, true)
	draw_line(top, left, colour, w, true)
	draw_line(top, right, colour, w, true)
	draw_circle(top, 0.10 * s, colour)
	draw_circle(left, 0.10 * s, colour)
	draw_circle(right, 0.10 * s, colour)


## Points of interest: a map pin — a ring around a point, over a stem.
func _pois(o: Vector2, s: float, w: float) -> void:
	draw_circle(_p(o, s, 0.50, 0.38), 0.26 * s, colour, false, w, true)
	draw_circle(_p(o, s, 0.50, 0.38), 0.08 * s, colour)
	draw_line(_p(o, s, 0.50, 0.64), _p(o, s, 0.50, 0.88), colour, w, true)
