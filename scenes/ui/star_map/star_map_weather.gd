extends Node3D
## The weather of the body under the star map's ground, while the weather debug option is on: isobars
## every 2 hPa, the wind as translucent arrows (their length says its speed) on a lattice that follows the
## zoom, the highs and lows marked with their names, and the weather at the cursor in the readout.
##
## Read from the planet's own WeatherSource, the door every consumer of the weather goes through: for a
## ClimateWeather its regional sample (ClimateWeather.sample_at: the atmosphere model's fresh field when the
## planet has one, else the climate profile and the systems Horizon delivered), so the chart shows what the
## game uses. The local layers (a canyon's channelled wind, gusts, dust devils) are left out: at the scale of
## a chart they are noise.
##
## A child of the body's sphere, like the roads: it inherits the spin and the drawn size, and its own frame
## is the body's (HEALPix longitude / latitude). The grid is sampled on a worker (star_map_weather_grid.gd)
## every REFRESH_MS, or when the systems or the clock jump: nothing is computed per frame but where the
## arrows stand, and only when the zoom or the view's centre moved by a lattice step.
##
## Loaded by path (preload) from the chart: no class name.

const Grid := preload("res://scenes/ui/star_map/star_map_weather_grid.gd")
const SHADER := preload("res://scenes/ui/star_map/star_map_weather.gdshader")

## The drawn radius of every body's sphere (StarMap.MESH_RADIUS).
const MESH_RADIUS: float = 0.5
## Wall-clock milliseconds between two samplings when nothing else asks for one.
const REFRESH_MS: int = 8000
## A jump of the simulated clock bigger than this (the dev clock) samples again at once, s.
const TIME_JUMP_S: float = 120.0
## The wind an arrow reaches its full length at, the shortest share of it an arrow keeps, and the calm
## under which none is drawn (m/s).
const ARROW_MAX_MS: float = 30.0
const ARROW_MIN_SHARE: float = 0.2
const ARROW_MIN_MS: float = 0.5
## An arrow's full length, as a share of the lattice step.
const ARROW_FILL: float = 0.85
const ARROW_COLOUR: Color = Color(0.85, 0.87, 0.9, 0.55)
const ISOBAR_COLOUR: Color = Color(0.95, 0.96, 1.0, 0.6)
const LOW_COLOUR: Color = Color(1.0, 0.45, 0.4)
const HIGH_COLOUR: Color = Color(0.5, 0.7, 1.0)
const STORM_COLOUR: Color = Color(0.95, 0.7, 0.35)
## Over the roads and the canyons.
const RENDER_PRIORITY: int = 6
## The cursor's weather is sampled again when it moved this far (degrees) or after this long (ms).
const READOUT_CELL_DEG: float = 0.01
const READOUT_KEPT_MS: int = 500

## Key of the body (its scene key).
var body_key: String = ""
## The highs and lows, drawn over the chart's face (the chart adds it under its cursor readout).
var labels: Labels = null

var _isobars: MeshInstance3D = null
var _arrows: MultiMeshInstance3D = null
var _grid: Dictionary = {}
## Samples the weather at (longitude, latitude), as the last grid was sampled: for the cursor readout.
var _sampler: Callable = Callable()
## The centres to mark, in the body's frame: [{dir: Vector3, letter, name, colour}].
var _marks: Array = []
var _task: int = -1
var _pending: Dictionary = {}
var _drawn_at_ms: int = -1
var _drawn_t: float = -INF
var _drawn_systems: int = -1
var _arrow_key: Vector3 = Vector3(INF, INF, INF)
var _readout_key: Vector2i = Vector2i(2147483647, 0)
var _readout_at_ms: int = -1
var _readout: String = ""


func _init() -> void:
	_isobars = MeshInstance3D.new()
	_isobars.material_override = _material(ISOBAR_COLOUR, RENDER_PRIORITY)
	_isobars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_isobars)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _arrow_mesh()
	multimesh.instance_count = (Grid.ARROW_HALF * 2 + 1) * (Grid.ARROW_HALF * 2 + 1)
	multimesh.visible_instance_count = 0
	_arrows = MultiMeshInstance3D.new()
	_arrows.multimesh = multimesh
	_arrows.material_override = _material(ARROW_COLOUR, RENDER_PRIORITY + 1)
	_arrows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arrows)
	labels = Labels.new()
	labels.visible = false
	visible = false


## Once a frame, from the chart: the live planet of this body (null out of range), whether the weather
## debug option is on, how much ground a pixel covers, the body's radius (m), the direction under the
## camera (body frame), the radius the layer floats at (a share of the sphere's: the ground under the
## camera and a little over it) and the chart's camera.
func refresh(planet: Planet, on: bool, metres_per_pixel: float, radius_m: float, centre: Vector3,
		radius_factor: float, camera: Camera3D) -> void:
	if _task >= 0:
		_collect()
	var source: WeatherSource = planet.current_weather_source() if on and planet != null and _has_air(planet) else null
	if source == null:
		visible = false
		labels.visible = false
		_sampler = Callable()
		return
	scale = Vector3.ONE * maxf(radius_factor, 0.01)
	var t: float = ClimateWeather.now()
	var systems: int = (source as ClimateWeather).systems(planet).size() if source is ClimateWeather else 0
	if _task < 0 and _due(t, systems):
		_start(planet, source, t, systems)
	visible = not _grid.is_empty()
	labels.visible = visible
	if not visible:
		return
	_place_arrows(metres_per_pixel, radius_m, centre)
	labels.place(self, camera, _marks)


## The weather at [param local] (a direction in the body's frame) for the cursor readout, "" when nothing
## is drawn. Sampled again only when the cursor moved READOUT_CELL_DEG or after READOUT_KEPT_MS.
func cursor_line(local: Vector3) -> String:
	if not visible or not _sampler.is_valid():
		return ""
	var ll: Vector2 = HEALPix.vec2lonlat(local)
	var key := Vector2i(roundi(ll.x / READOUT_CELL_DEG), roundi(ll.y / READOUT_CELL_DEG))
	var ms: int = Time.get_ticks_msec()
	if key != _readout_key or ms - _readout_at_ms > READOUT_KEPT_MS:
		_readout_key = key
		_readout_at_ms = ms
		_readout = Grid.readout_text(_sampler.call(ll.x, ll.y), func(k: String) -> String: return tr(k))
	return _readout


## Let the worker finish and take the labels off the chart: the layer is going.
func clear() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_pending = {}
	if is_instance_valid(labels):
		labels.queue_free()
	labels = null


func _exit_tree() -> void:
	# Parked by a rebuild, or going: the labels must not stand alone over the chart meanwhile.
	if is_instance_valid(labels):
		labels.visible = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		clear()


static func _has_air(planet: Planet) -> bool:
	var profile: AtmosphereProfile = planet.planet_data.atmosphere_profile if planet.planet_data != null else null
	return profile != null and profile.has_atmosphere()


func _due(t: float, systems: int) -> bool:
	if _drawn_at_ms < 0 or systems != _drawn_systems or absf(t - _drawn_t) > TIME_JUMP_S:
		return true
	return Time.get_ticks_msec() - _drawn_at_ms > REFRESH_MS


## Sample the grid on a worker, the way the game samples the weather now (read on this thread: the
## systems, the field, where the star stands).
func _start(planet: Planet, source: WeatherSource, t: float, systems: int) -> void:
	var sampler: Callable
	var marks_from: Array = []
	var weather := source as ClimateWeather
	if weather != null and weather.profile != null:
		var sun: Vector2 = weather.sun_over(planet)
		var live: Array = weather.systems(planet)
		# The atmosphere model's field (when the game has it): it then stands for the systems.
		var field: Array = weather.call("fresh_field", planet, t) if weather.has_method("fresh_field") else []
		if field.is_empty():
			sampler = func(lon: float, lat: float) -> Dictionary:
				return weather.sample_at(lon, lat, 0.0, sun.y, sun.x, live)
			marks_from = live
		else:
			sampler = func(lon: float, lat: float) -> Dictionary:
				return weather.call("sample_at", lon, lat, 0.0, sun.y, sun.x, live, field, t)
	else:
		sampler = func(lon: float, lat: float) -> Dictionary:
			return source.sample(planet, HEALPix.lonlat2vec(lon, lat))
	_sampler = sampler
	var find_extrema: bool = weather != null and marks_from.is_empty()
	var out: Dictionary = {}
	_pending = out
	_task = PerfTasks.add_task("starmap:weather", func() -> void: out.merge(_build(sampler, find_extrema)))
	if not find_extrema:
		_marks = _system_marks(marks_from)
	_drawn_t = t
	_drawn_systems = systems
	_drawn_at_ms = Time.get_ticks_msec()


## The grid, its isobars and (with [param find_extrema]) its pressure centres. Pure: runs on the worker.
static func _build(sampler: Callable, find_extrema: bool) -> Dictionary:
	var grid: Dictionary = Grid.sample_grid(sampler, Grid.COARSE_W, Grid.COARSE_H)
	var lines := PackedVector2Array()
	var centres: Array[Dictionary] = []
	if grid["has_pressure"]:
		var fine: PackedFloat32Array = Grid.upsample(grid["pressure"], Grid.COARSE_W, Grid.COARSE_H, Grid.UPSAMPLE)
		lines = Grid.isobars(fine, Grid.COARSE_W * Grid.UPSAMPLE, Grid.COARSE_H * Grid.UPSAMPLE, Grid.ISOBAR_PA)
		if find_extrema:
			centres = Grid.extrema(grid["pressure"], Grid.COARSE_W, Grid.COARSE_H)
	return {"grid": grid, "lines": lines, "centres": centres, "extrema": find_extrema}


func _collect() -> void:
	if not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if not _pending.has("grid"):
		return
	_grid = _pending["grid"]
	_isobars.mesh = _line_mesh(_pending["lines"])
	if _pending["extrema"]:
		_marks = _extremum_marks(_pending["centres"])
	_pending = {}
	_arrow_key = Vector3(INF, INF, INF)


## The systems Horizon delivered (WeatherSystem.state()) as marks: L / H / the dust storm, and their name.
func _system_marks(systems: Array) -> Array:
	var out: Array = []
	for system: Dictionary in systems:
		var kind: StringName = StringName(str(system.get("kind", "")))
		var letter: String
		var colour: Color
		if kind == WeatherSampler.KIND_DEPRESSION:
			letter = tr("%%HUD_MAP_WEATHER_LOW")
			colour = LOW_COLOUR
		elif kind == WeatherSampler.KIND_ANTICYCLONE:
			letter = tr("%%HUD_MAP_WEATHER_HIGH")
			colour = HIGH_COLOUR
		elif kind == WeatherSampler.KIND_DUST_STORM:
			letter = tr("%%HUD_MAP_WEATHER_STORM")
			colour = STORM_COLOUR
		else:
			continue
		out.append({"dir": HEALPix.lonlat2vec(float(system.get("lon", 0.0)), float(system.get("lat", 0.0))),
				"letter": letter, "name": str(system.get("name", "")), "colour": colour})
	return out


## The pressure centres found in a field (star_map_weather_grid.gd extrema) as marks, with their pressure.
func _extremum_marks(centres: Array) -> Array:
	var out: Array = []
	for c: Dictionary in centres:
		var high: bool = c["high"]
		out.append({"dir": HEALPix.lonlat2vec(float(c["lon"]), float(c["lat"])),
				"letter": tr("%%HUD_MAP_WEATHER_HIGH" if high else "%%HUD_MAP_WEATHER_LOW"),
				"name": "%.0f hPa" % (float(c["pressure_pa"]) / 100.0), "colour": HIGH_COLOUR if high else LOW_COLOUR})
	return out


## Lay the arrows again when the zoom changed the lattice's step or the view's centre moved by one.
func _place_arrows(metres_per_pixel: float, radius_m: float, centre: Vector3) -> void:
	var step: float = Grid.arrow_step_deg(metres_per_pixel, radius_m)
	var ll: Vector2 = HEALPix.vec2lonlat(centre) if centre != Vector3.ZERO else Vector2.ZERO
	var key := Vector3(step, roundf(ll.x / step), roundf(ll.y / step))
	if key == _arrow_key:
		return
	_arrow_key = key
	var w: int = _grid["w"]
	var h: int = _grid["h"]
	var east_grid: PackedFloat32Array = _grid["east"]
	var north_grid: PackedFloat32Array = _grid["north"]
	var multimesh: MultiMesh = _arrows.multimesh
	var spacing: float = deg_to_rad(step) * MESH_RADIUS
	var n: int = 0
	for p: Vector2 in Grid.arrow_lattice(ll.x, ll.y, step):
		if n >= multimesh.instance_count:
			break
		var east: float = Grid.bilinear(east_grid, w, h, p.x, p.y)
		var north: float = Grid.bilinear(north_grid, w, h, p.x, p.y)
		if east * east + north * north < ARROW_MIN_MS * ARROW_MIN_MS:
			continue
		multimesh.set_instance_transform(n, arrow_transform(p.x, p.y, east, north, MESH_RADIUS, spacing))
		n += 1
	multimesh.visible_instance_count = n


## Where an arrow stands and points for a wind ([param east], [param north] m/s, along the game's own
## local axes, Planet.local_axes) at (lon, lat), on a sphere of [param radius], arrows [param spacing]
## apart: centred on its place, -Z along the wind, +Y out of the ground, its length growing with the wind.
static func arrow_transform(lon: float, lat: float, east: float, north: float, radius: float,
		spacing: float) -> Transform3D:
	var up: Vector3 = HEALPix.lonlat2vec(lon, lat)
	var axes: Array = Planet.local_axes(up)
	var wind: Vector3 = (axes[0] as Vector3) * east + (axes[1] as Vector3) * north
	var speed: float = wind.length()
	if speed <= 0.0:
		return Transform3D(Basis.from_scale(Vector3.ZERO), up * radius)
	var length: float = spacing * ARROW_FILL * clampf(speed / ARROW_MAX_MS, ARROW_MIN_SHARE, 1.0)
	var basis: Basis = Basis.looking_at(wind / speed, up) * Basis.from_scale(Vector3.ONE * length)
	return Transform3D(basis, up * radius)


static func _material(colour: Color, priority: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.render_priority = priority
	material.set_shader_parameter(&"colour", colour)
	return material


## The isobars' segments (longitude / latitude pairs) as lines on the sphere.
static func _line_mesh(segments: PackedVector2Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if segments.size() < 2:
		return mesh
	var vertices := PackedVector3Array()
	vertices.resize(segments.size())
	for i in segments.size():
		vertices[i] = HEALPix.lonlat2vec(segments[i].x, segments[i].y) * MESH_RADIUS
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## A flat arrow of length 1 centred on the origin, pointing down -Z in the XZ plane: a stem and a head.
static func _arrow_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array([
		Vector3(-0.05, 0.0, 0.5), Vector3(0.05, 0.0, 0.5), Vector3(0.05, 0.0, -0.1),
		Vector3(-0.05, 0.0, 0.5), Vector3(0.05, 0.0, -0.1), Vector3(-0.05, 0.0, -0.1),
		Vector3(-0.2, 0.0, -0.05), Vector3(0.2, 0.0, -0.05), Vector3(0.0, 0.0, -0.5),
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The highs, lows and storms written over the chart: a big letter on the centre, its name under it. Only
## those on the face of the body turned to the camera.
class Labels:
	extends Control

	const OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.85)
	const LETTER_SCALE: float = 1.8

	var _drawn: Array = []

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	## Where each of [param marks] stands on screen this frame, for [param layer] seen by [param camera].
	func place(layer: Node3D, camera: Camera3D, marks: Array) -> void:
		var drawn: Array = []
		if camera != null and not marks.is_empty():
			var centre: Vector3 = layer.global_position
			var eye: Vector3 = camera.global_position
			for mark: Dictionary in marks:
				var at: Vector3 = layer.to_global((mark["dir"] as Vector3) * MESH_RADIUS)
				if (at - centre).dot(eye - at) <= 0.0 or camera.is_position_behind(at):
					continue
				drawn.append([camera.unproject_position(at), mark])
		if drawn.is_empty() and _drawn.is_empty():
			return
		_drawn = drawn
		queue_redraw()

	func _draw() -> void:
		var font: Font = get_theme_default_font()
		var size_small: int = get_theme_default_font_size()
		var size_big: int = int(size_small * LETTER_SCALE)
		for item: Array in _drawn:
			var at: Vector2 = item[0]
			var mark: Dictionary = item[1]
			var letter: String = mark["letter"]
			var colour: Color = mark["colour"]
			var span: float = font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, size_big).x
			var base := at + Vector2(-span * 0.5, size_big * 0.35)
			draw_string_outline(font, base, letter, HORIZONTAL_ALIGNMENT_LEFT, -1, size_big, 6, OUTLINE)
			draw_string(font, base, letter, HORIZONTAL_ALIGNMENT_LEFT, -1, size_big, colour)
			var name_text: String = mark["name"]
			if name_text == "":
				continue
			var name_span: float = font.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_small).x
			var under := at + Vector2(-name_span * 0.5, size_big * 0.35 + size_small * 1.2)
			draw_string_outline(font, under, name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_small, 5, OUTLINE)
			draw_string(font, under, name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_small, colour)
