class_name FacetPattern
extends Control

## Triangles in shades of one colour, the ARES screens' polygon look: laid out from [member seed_text]
## so one card always looks the same and two side by side do not. Still on a mission tile; alive on a
## screen saver ([member drift] > 0), its inner corners swaying and its shades breathing.

## The colour every facet is a shade of.
var colour: Color = Color.WHITE
## Lays the facets out: the same text, the same pattern.
var seed_text: String = ""
var columns: int = 3
var rows: int = 4
## How fast the pattern moves (rad/s); 0 keeps it still.
var drift: float = 0.0:
	set(value):
		drift = value
		set_process(drift > 0.0)

var _t: float = 0.0


func _ready() -> void:
	set_process(drift > 0.0)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text)
	var cell := Vector2(size.x / columns, size.y / rows)
	var points: Array[Vector2] = []
	for j: int in range(rows + 1):
		for i: int in range(columns + 1):
			var jitter := Vector2(rng.randf_range(-0.3, 0.3), rng.randf_range(-0.3, 0.3))
			var phase: float = rng.randf() * TAU
			var inner: bool = i > 0 and i < columns and j > 0 and j < rows
			if inner and drift > 0.0:
				jitter += Vector2(sin(_t * drift + phase), cos(_t * drift * 0.8 + phase)) * 0.15
			points.append(Vector2(i, j) * cell + (jitter * cell if inner else Vector2.ZERO))
	for j: int in range(rows):
		for i: int in range(columns):
			var a: Vector2 = points[j * (columns + 1) + i]
			var b: Vector2 = points[j * (columns + 1) + i + 1]
			var c: Vector2 = points[(j + 1) * (columns + 1) + i]
			var d: Vector2 = points[(j + 1) * (columns + 1) + i + 1]
			draw_colored_polygon(PackedVector2Array([a, b, d]), _shade(rng))
			draw_colored_polygon(PackedVector2Array([a, d, c]), _shade(rng))


func _shade(rng: RandomNumberGenerator) -> Color:
	var t: float = rng.randf_range(-0.2, 0.3)
	if drift > 0.0:
		t += 0.08 * sin(_t * drift * 0.6 + rng.randf() * TAU)  # the shades breathe
	return colour.lightened(-t) if t < 0.0 else colour.darkened(t)
