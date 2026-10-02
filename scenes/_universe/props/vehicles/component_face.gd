class_name ComponentFace
extends RefCounted
## Where something painted on a face of a vehicle part goes: the face's frame (right, up, outward
## normal), its centre just off the surface, and how big a piece of content of a given size can be
## drawn there. The pictogram and the battery's charge gauge are both laid out by it, so they can
## never disagree on which way is up on a face.
##
## Derived from the part's own collision box: right whatever size the part is.

## One face: the flag that selects it (VehicleComponent.icon_faces), its outward normal, and which
## way is "up" on it before the content is turned to the face's long axis.
const FACES: Array[Dictionary] = [
	{"bit": 1, "normal": Vector3.UP, "up": Vector3.FORWARD},
	{"bit": 2, "normal": Vector3.FORWARD, "up": Vector3.UP},
	{"bit": 4, "normal": Vector3.BACK, "up": Vector3.UP},
	{"bit": 8, "normal": Vector3.LEFT, "up": Vector3.UP},
	{"bit": 16, "normal": Vector3.RIGHT, "up": Vector3.UP},
]
## How far off the surface paint sits (m). Enough to beat depth fighting with the hull at the
## distances this is looked at, small enough that it still reads as paint and not as a floating sign.
const LIFT := 0.003


## The faces of [param faces] (a VehicleComponent.icon_faces bit field), in FACES order.
static func selected(faces: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for face in FACES:
		if faces & int(face["bit"]) != 0:
			out.append(face)
	return out


## Lay content [param content_size] (any unit, e.g. texture pixels) on [param face] of [param box],
## along the face's LONG axis. Returns {"transform": the frame at the face's centre (x right, y up,
## z out), "scale": metres per content unit to fit the face, "span": the face's size in that frame
## (m)}, or {} when the face or the content is degenerate.
##
## A landscape icon dropped on the short side of an oblong face fits in a fraction of the room and
## reads as rotated next to the serial, which runs the long way: both quarter turns are measured and
## the roomier one wins, so this stays right for a face of any proportion.
static func layout(box: AABB, face: Dictionary, content_size: Vector2) -> Dictionary:
	var normal: Vector3 = face["normal"]
	var up: Vector3 = face["up"]
	var right: Vector3 = up.cross(normal)
	var span_w: float = absf(right.dot(box.size))
	var span_h: float = absf(up.dot(box.size))
	if span_w <= 0.0 or span_h <= 0.0 or content_size.x <= 0.0 or content_size.y <= 0.0:
		return {}
	var upright: float = minf(span_w / content_size.x, span_h / content_size.y)
	var turned: float = minf(span_h / content_size.x, span_w / content_size.y)
	var span := Vector2(span_w, span_h)
	if turned > upright:
		var was_up: Vector3 = up
		up = right
		right = -was_up
		span = Vector2(span_h, span_w)
	var centre: Vector3 = box.get_center() + normal * (absf(normal.dot(box.size)) * 0.5 + LIFT)
	return {"transform": Transform3D(Basis(right, up, normal), centre), "scale": maxf(upright, turned), "span": span}
