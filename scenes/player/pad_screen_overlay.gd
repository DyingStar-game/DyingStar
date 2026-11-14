class_name PadScreenOverlay
extends CanvasLayer

## The tablet's picture drawn in 2D over the wrist's screen while it is read, exactly where that screen
## stands in the view.
##
## Read, the DataPad's screen fills the view at a field of some 12 degrees: a pixel is 35 µm of screen.
## The engine draws the 3D screen from WORLD transforms, and out where the world is (4e10 m) a double
## tells positions apart by about 8 µm: the camera's and the screen's each round on their own, and anew
## each time the vehicle under them moves by a micron. The picture shook by 0.5 to 1.7 px on any vehicle
## not held by its handbrake, with nothing moving between the eye and the screen (measured 2026-11-13,
## PadShakeProbe: 0.00 px in the body's frame, "engine px" for what was drawn).
##
## So the picture is laid over the 3D screen from the same figures that read 0.00: the screen's place
## in the CAMERA's frame, multiplied up from local transforms only, projected here. The 3D screen stays
## under it (the pointer's ray still reads it, WristDatapad._input) and shows nowhere.

## Under every other layer of the interface: the picture is part of the scene, the HUD goes over it.
const LAYER: int = -1
## Cells along each side of the picture. The screen is seen a little askew (the eyes drift after the
## cursor, and it turns to the eye during the zoom): one quad would bend the picture along its diagonal,
## a grid follows the perspective to well under a pixel.
const CELLS: int = 8

var _picture: Polygon2D = null


func _init() -> void:
	layer = LAYER
	_picture = Polygon2D.new()
	_picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_picture.visible = false
	add_child(_picture)


## Where [param point] (the camera's frame: -z ahead, +y up) falls in a view of [param view_size] seen
## with a field of [param fov_deg] degrees, vertical or horizontal as [param keep_height] says
## (Camera3D.keep_aspect). INF behind the eye. Static and pure, for the tests.
static func project(point: Vector3, fov_deg: float, view_size: Vector2, keep_height: bool = true) -> Vector2:
	if point.z >= -1e-6:
		return Vector2.INF
	var reach: float = tan(deg_to_rad(fov_deg) * 0.5)
	# Pixels per unit of slope: the same both ways (square pixels), set by the side the field is kept on.
	var scale: float = (view_size.y if keep_height else view_size.x) * 0.5 / maxf(reach, 1e-9)
	return Vector2(view_size.x * 0.5 + point.x / -point.z * scale, view_size.y * 0.5 - point.y / -point.z * scale)


## The grid of points ((cells + 1) squared, row by row from the top-left) a screen of [param size_m]
## metres standing at [param screen_in_camera] is drawn on; empty when part of it is behind the eye.
## Static and pure, for the tests.
static func grid(screen_in_camera: Transform3D, size_m: Vector2, fov_deg: float, view_size: Vector2,
		keep_height: bool = true, cells: int = CELLS) -> PackedVector2Array:
	var out := PackedVector2Array()
	for row: int in cells + 1:
		for column: int in cells + 1:
			var uv := Vector2(float(column) / cells, float(row) / cells)
			var at: Vector2 = project(screen_in_camera * Vector3((uv.x - 0.5) * size_m.x, (0.5 - uv.y) * size_m.y, 0.0),
					fov_deg, view_size, keep_height)
			if at == Vector2.INF:
				return PackedVector2Array()
			out.append(at)
	return out


## Lay [param texture] (the tablet's viewport) over the screen standing at [param screen_in_camera].
func place(texture: Texture2D, screen_in_camera: Transform3D, size_m: Vector2, fov_deg: float, view_size: Vector2,
		keep_height: bool = true) -> void:
	var points: PackedVector2Array = grid(screen_in_camera, size_m, fov_deg, view_size, keep_height)
	if points.is_empty() or texture == null:
		clear()
		return
	_picture.polygon = points  # before the rest: uv and polygons are checked against their count
	if _picture.texture != texture or _picture.polygons.is_empty():
		_picture.texture = texture
		_picture.uv = picture_uvs(texture.get_size())
		_picture.polygons = cells()
	_picture.visible = true


## The texture's own points (pixels) at the grid's points, in the same order. Static and pure.
static func picture_uvs(pixels: Vector2, count: int = CELLS) -> PackedVector2Array:
	var out := PackedVector2Array()
	for row: int in count + 1:
		for column: int in count + 1:
			out.append(Vector2(pixels.x * column / count, pixels.y * row / count))
	return out


## The grid's cells, each the four indices of its corners. Static and pure.
static func cells(count: int = CELLS) -> Array:
	var out: Array = []
	for row: int in count:
		for column: int in count:
			var first: int = row * (count + 1) + column
			out.append(PackedInt32Array([first, first + 1, first + count + 2, first + count + 1]))
	return out


## Nothing laid: the 3D screen shows as it is.
func clear() -> void:
	_picture.visible = false
