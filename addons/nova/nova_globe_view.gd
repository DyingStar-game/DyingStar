@tool
extends Control
## The Nova dock's miniature of a body: the planet seen from space, in its own colours.
##
## Each variant wears its rock's colour, the ground is shaded by the body's real relief (NovaAtlas.relief,
## exaggerated: true to scale a 10 km mountain is invisible on a planet), a sun lights it and its air
## hazes the limb. The selected variant is outlined in white. A drag turns it, the wheel zooms, a click
## asks to go there ([signal go_to]). All of it is one shader (nova_globe.gdshader, sharing the planet's look
## with the editor's far sphere): turning and zooming cost nothing on the CPU.

## Left click on the planet: the ground point under the cursor (unit, body frame).
signal go_to(dir: Vector3)
## Left click on a point of interest: its index in [member pois].
signal poi_clicked(index: int)
## The mouse moved over the planet: a line for the dock (variant and coordinates), "" when it left.
signal hovered(text: String)

const MAX_ZOOM := 40.0
## Disc radius at zoom 1, as a share of half the smaller side.
const FILL := 0.9
## Ground colour of a body that names no rock for it.
const COLOR_GROUND := Color(0.5, 0.47, 0.43)
## Points of interest: their dot's colour, and how near the mouse must be to pick one (pixels).
const POI_COLOR := Color(1.0, 0.86, 0.2)
const POI_PICK_PX := 7.0
## How much of an overlay picture (the weather map) covers the body's own colours.
const OVERLAY_MIX := 0.92
## How many times steeper than life the relief is shaded.
const RELIEF_GAIN := 40.0
## Variant outlined in white (≤ 1: none).
var highlight := 0:
	set(v):
		highlight = v
		_mat.set_shader_parameter("selected", v)
## Ground point under the editor camera (unit, body frame), ZERO when unknown.
var camera_dir := Vector3.ZERO:
	set(v):
		if not v.is_equal_approx(camera_dir):
			camera_dir = v
			_overlay.queue_redraw()

## The body's points of interest (StarMapPoi records: dir, label, kind), drawn as dots.
var pois: Array = []:
	set(v):
		pois = v
		_overlay.queue_redraw()

var _atlas: NovaAtlas
var _nova: NovaBody
var _lon := 0.0  # the point facing the viewer, degrees
var _lat := 0.0
var _zoom := 1.0
var _mat := ShaderMaterial.new()
var _disc := ColorRect.new()
var _overlay := Control.new()
var _press := Vector2.INF
var _dragged := false


func _init() -> void:
	clip_contents = true
	_mat.shader = preload("res://addons/nova/nova_globe.gdshader")
	_disc.material = _mat
	_disc.visible = false
	for c: Control in [_disc, _overlay]:
		c.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(c)
	_overlay.draw.connect(_draw_camera)
	resized.connect(_update_view)


## Show [param atlas] of [param nova]: [param colors] = variant id → Color, [param radius] the body's, metres.
func show_atlas(atlas: NovaAtlas, nova: NovaBody, colors: Dictionary, radius: float) -> void:
	_atlas = atlas
	_nova = nova
	_disc.visible = true
	apply_look(_mat, atlas, colors, radius)
	_update_view()


## Lay [param picture] over the body (longitude/latitude, west → east and north → south, as the atlas's
## map: the weather map), null to show the body bare again.
func show_overlay(picture: Image) -> void:
	_mat.set_shader_parameter("overlay", ImageTexture.create_from_image(picture) if picture != null else null)
	_mat.set_shader_parameter("overlay_mix", OVERLAY_MIX if picture != null else 0.0)


## Show nothing and answer no click, until the next [method show_atlas].
func clear() -> void:
	_atlas = null
	_disc.visible = false


## Give [param mat] (a shader including nova_planet.gdshaderinc) the look of [param atlas]'s body.
static func apply_look(mat: ShaderMaterial, atlas: NovaAtlas, colors: Dictionary, radius: float) -> void:
	if atlas.map != null:
		mat.set_shader_parameter("ids", ImageTexture.create_from_image(atlas.map))
	mat.set_shader_parameter("has_relief", atlas.relief != null)
	if atlas.relief != null:
		mat.set_shader_parameter("relief", ImageTexture.create_from_image(atlas.relief))
		mat.set_shader_parameter("slope_gain", RELIEF_GAIN / maxf(radius, 1.0))
	mat.set_shader_parameter("palette", palette_texture(colors))


## The shaders' palette: one pixel a variant id, [param colors] = variant id → Color (id 0 reads id 1's).
static func palette_texture(colors: Dictionary) -> ImageTexture:
	var img := Image.create_empty(256, 1, false, Image.FORMAT_RGB8)
	for id in 256:
		img.set_pixel(id, 0, colors.get(maxi(id, 1), COLOR_GROUND))
	return ImageTexture.create_from_image(img)


## Turn the planet to face [param dir] (unit, body frame); the zoom is the user's.
func focus(dir: Vector3) -> void:
	var ll := HEALPix.vec2lonlat(dir)
	_lon = ll.x
	_lat = clampf(ll.y, -89.0, 89.0)
	_update_view()


## Body frame of the view: x right, y up, z towards the viewer.
func _basis() -> Basis:
	var f := HEALPix.lonlat2vec(_lon, _lat)
	var r := Vector3.UP.cross(f).normalized()
	return Basis(r, f.cross(r), f)


func _radius() -> float:
	return maxf(minf(size.x, size.y) * 0.5 * FILL * _zoom, 1.0)


func _update_view() -> void:
	_mat.set_shader_parameter("view", _basis())
	_mat.set_shader_parameter("scale", size / _radius())
	_overlay.queue_redraw()


## The ground point under pixel [param p] (unit, body frame), ZERO off the planet.
func _dir_at(p: Vector2) -> Vector3:
	var q := (p - size * 0.5) / _radius()
	if q.length_squared() >= 1.0:
		return Vector3.ZERO
	return _basis() * Vector3(q.x, -q.y, sqrt(1.0 - q.length_squared()))


func _gui_input(event: InputEvent) -> void:
	if _atlas == null:
		return
	var mb := event as InputEventMouseButton
	var mm := event as InputEventMouseMotion
	if mb != null and mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var before := _dir_at(mb.position)
		_zoom = clampf(_zoom * (1.25 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8), 1.0, MAX_ZOOM)
		var after := _dir_at(mb.position)
		if before != Vector3.ZERO and after != Vector3.ZERO:
			# Keep the point under the cursor where it was.
			var shift := HEALPix.vec2lonlat(before) - HEALPix.vec2lonlat(after)
			_turn(wrapf(shift.x, -180.0, 180.0), shift.y)
		_update_view()
		accept_event()
	elif mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_press = mb.position
			_dragged = false
		else:
			var d := _dir_at(mb.position)
			var poi := _poi_at(mb.position)
			if not _dragged and _press != Vector2.INF and poi >= 0:
				poi_clicked.emit(poi)
			elif not _dragged and _press != Vector2.INF and d != Vector3.ZERO:
				go_to.emit(d)
			_press = Vector2.INF
		accept_event()
	elif mm != null:
		if _press != Vector2.INF and (_dragged or mm.position.distance_to(_press) > 4.0):
			_dragged = true
			var deg := rad_to_deg(1.0 / _radius())
			_turn(-mm.relative.x * deg / maxf(cos(deg_to_rad(_lat)), 0.2), mm.relative.y * deg)
			_update_view()
		hovered.emit(_hover_text(mm.position))


func _turn(dlon: float, dlat: float) -> void:
	_lon = wrapf(_lon + dlon, -180.0, 180.0)
	_lat = clampf(_lat + dlat, -89.0, 89.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		hovered.emit("")


func _hover_text(p: Vector2) -> String:
	var poi := _poi_at(p)
	if poi >= 0:
		return "POI : %s (%s) — clic pour y aller" % [str(pois[poi].label), str(pois[poi].kind)]
	var d := _dir_at(p)
	if d == Vector3.ZERO or _atlas.map == null:
		return ""
	var ll := HEALPix.vec2lonlat(d)
	var id := _atlas.map.get_pixelv(NovaAtlas.map_pixel(d)).r8
	return "%s  (lon %.2f°, lat %.2f°)" % [str(_nova.variant(maxi(id, 1)).get("label", "?")), ll.x, ll.y]


## Where body direction [param dir] is drawn, Vector2.INF on the far side.
func _point_of(dir: Vector3) -> Vector2:
	var v := _basis().transposed() * dir
	return size * 0.5 + Vector2(v.x, -v.y) * _radius() if v.z > 0.0 else Vector2.INF


## The point of interest under pixel [param p] (within POI_PICK_PX), -1 when none.
func _poi_at(p: Vector2) -> int:
	var best := -1
	var best_d := POI_PICK_PX
	for i in pois.size():
		var d := _point_of(pois[i].dir).distance_to(p)
		if d < best_d:
			best_d = d
			best = i
	return best


## The overlay: the points of interest as dots, then the editor camera as a white sight.
func _draw_camera() -> void:
	for poi: Dictionary in pois:
		var at := _point_of(poi.dir)
		if at != Vector2.INF:
			_overlay.draw_circle(at, 3.5, Color.BLACK)
			_overlay.draw_circle(at, 2.5, POI_COLOR)
	var p := _point_of(camera_dir) if camera_dir != Vector3.ZERO else Vector2.INF
	if p == Vector2.INF:
		return
	_overlay.draw_circle(p, 6.0, Color.BLACK, false, 4.0, true)
	_overlay.draw_circle(p, 6.0, Color.WHITE, false, 2.0, true)
	for a: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		_overlay.draw_line(p + a * 4.0, p + a * 11.0, Color.WHITE, 2.0)
