class_name FloorPaint
extends RefCounted

## Text painted on a floor, as a warehouse marks its aisles and shelves (playtest 2026-11-08): a Label3D
## lying flat, matte yellow, no outline, just above the floor so it never flickers into it.

## How far (m) above the floor the paint lies.
const LIFT_M := 0.012
const COLOUR := Color(0.95, 0.78, 0.15, 0.85)
## How far (m) the paint is seen from.
const READ_M := 20.0


## A painted [param text] of [param font_size] (lay it with flat()).
static func label(text: String, font_size: int) -> Label3D:
	var paint := Label3D.new()
	paint.text = text
	paint.font = AresBrand.font()
	paint.font_size = font_size
	paint.pixel_size = 0.004
	paint.outline_size = 0
	paint.modulate = COLOUR
	paint.shaded = true
	paint.double_sided = false
	paint.visibility_range_end = READ_M
	paint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return paint


## The basis that lays a Label3D (facing +Z) flat on a floor facing up, the top of its text turned by
## [param yaw] about the vertical (0: toward -Z).
static func flat(yaw: float) -> Basis:
	return Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -PI / 2.0)
