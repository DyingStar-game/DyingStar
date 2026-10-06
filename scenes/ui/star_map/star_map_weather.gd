class_name StarMapWeather
extends Node3D
## The weather of ONE body, laid over its globe the way a synoptic chart does: the pressure anomaly as
## a diverging fill (blue where the air is low, red where it is high) with isobars every ISOBAR_PA,
## the dust in the air as an ochre veil, and the wind as arrows laid on the ground. Read from the
## SAME numbers the sky and the physics read — WeatherSampler, fed the body's climate profile and the
## systems Horizon delivered — so the chart can never disagree with what the player feels.
##
## A child of the body's sphere, like the ground and the roads: it inherits the spin and the drawn
## size for nothing, and its own frame is the body's fixed frame (HEALPix: longitude = atan2(z, x),
## latitude = asin(y)), which is the frame the sampler speaks.
##
## The fields are sampled on a lon/lat grid by a worker thread (ten thousand samples, a few hundred
## milliseconds of GDScript — never on the main thread), and redrawn when the clock jumps (the dev
## clock), when the systems change, or every REFRESH_S; the arrows are placed from the same grid.
## Only the body you are near has its weather: Horizon delivers the systems of what is around you,
## and the chart draws nothing for a body it has no systems of (its climate alone would pass for the
## day's weather, and it is not).

## How far over the drawn sphere the shell floats, as a fraction of its radius: above the tallest
## relief the ground can draw (a mountain is 0.2 % of a radius), under the markers.
const LIFT: float = 0.012
## The drawn radius of every body's sphere (StarMap.MESH_RADIUS): the tiles, the roads and this shell
## are all built in these units so that the sphere's scale sizes them for nothing.
const MESH_RADIUS: float = 0.5
## The grid the fields are sampled on: 2.5° cells.
const GRID_W: int = 144
const GRID_H: int = 72
## One arrow every so many cells: 48 × 24 arrows.
const ARROW_EVERY: int = 3
## Wall-clock seconds between two redraws when nothing else asks for one.
const REFRESH_S: float = 5.0
## A jump of the simulated clock bigger than this (the dev clock) redraws at once.
const TIME_JUMP_S: float = 120.0
## Isobars every 4 hPa; the fill saturates at ±20 hPa.
const ISOBAR_PA: float = 400.0
const PRESSURE_RANGE_PA: float = 2000.0
## The wind an arrow reaches its full length at, and under which no arrow is drawn (calm).
const ARROW_MAX_MS: float = 30.0
const ARROW_MIN_MS: float = 1.0
## An arrow's full length, as a fraction of the spacing between arrows.
const ARROW_FILL: float = 0.85
## Where the layer fades with the zoom: readable from the whole globe, gone when a pixel covers less
## than ~2 km of ground — the chart is then about the ground, not the sky over it.
const PIXEL_M_MIN: float = 1500.0
const PIXEL_M_FULL: float = 4000.0
## Over the roads and the canyons (StarMapTileLines priorities are ≤ 0).
const RENDER_PRIORITY: int = 5
const ARROW_COLOUR: Color = Color(0.08, 0.08, 0.10, 0.9)

const SHADER := preload("res://scenes/ui/star_map/star_map_weather.gdshader")

## Key of the body (its scene key), for the readouts.
var body_key: String = ""
## Switched by the star map's weather key: off, nothing is drawn nor computed.
var enabled: bool = true

var _shell: MeshInstance3D = null
var _material: ShaderMaterial = null
var _arrows: MultiMeshInstance3D = null
var _arrow_material: StandardMaterial3D = null
var _texture: ImageTexture = null
## The inputs of the last redraw: for the cursor's reading, and to tell when a redraw is due.
var _profile: ClimateProfile = null
var _systems: Array = []
var _sub_lon: float = 0.0
var _decl: float = 0.0
var _drawn_t: float = -INF
var _drawn_count: int = -1
var _drawn_at_ms: int = -1
## The worker's task, -1 when none; its result lands in _pending.
var _task: int = -1
var _pending: Dictionary = {}
var _alpha: float = 0.0


func _init() -> void:
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.render_priority = RENDER_PRIORITY
	_material.set_shader_parameter(&"isobar_pa", ISOBAR_PA)
	_material.set_shader_parameter(&"range_pa", PRESSURE_RANGE_PA)
	_material.set_shader_parameter(&"alpha", 0.0)
	var mesh := SphereMesh.new()
	mesh.radius = MESH_RADIUS * (1.0 + LIFT)
	mesh.height = mesh.radius * 2.0
	mesh.radial_segments = 48
	mesh.rings = 24
	_shell = MeshInstance3D.new()
	_shell.mesh = mesh
	_shell.material_override = _material
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shell)
	_arrow_material = StandardMaterial3D.new()
	_arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_arrow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_arrow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_arrow_material.render_priority = RENDER_PRIORITY + 1
	_arrow_material.albedo_color = ARROW_COLOUR
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _arrow_mesh()
	multimesh.instance_count = (GRID_W / ARROW_EVERY) * (GRID_H / ARROW_EVERY)
	multimesh.visible_instance_count = 0
	_arrows = MultiMeshInstance3D.new()
	_arrows.multimesh = multimesh
	_arrows.material_override = _arrow_material
	_arrows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arrows)
	visible = false


## Once a frame, from the chart: the live planet of this body (null when it is out of range), the
## simulated time and how much ground a pixel covers under the camera.
func refresh(planet: Planet, t: float, metres_per_pixel: float) -> void:
	if _task >= 0:
		_collect()
	_alpha = strength(metres_per_pixel) if enabled else 0.0
	if not enabled or planet == null:
		if planet == null:
			_profile = null
			_systems = []
		visible = false
		return
	var profile: ClimateProfile = planet.climate_profile()
	if profile == null:
		_profile = null
		visible = false
		return
	visible = _alpha > 0.0 and _texture != null
	if _alpha <= 0.0:
		return  # the last picture is kept for when the zoom backs out; nothing to compute meanwhile
	_material.set_shader_parameter(&"alpha", _alpha)
	var colour: Color = ARROW_COLOUR
	colour.a *= _alpha
	_arrow_material.albedo_color = colour
	var systems: Array = planet.weather_systems()
	if _task < 0 and _due(t, systems.size()):
		_start(profile, systems, planet.substellar_lonlat(), t)


## How strongly the layer is drawn, 0 to 1, for a pixel covering [param metres_per_pixel] of ground.
static func strength(metres_per_pixel: float) -> float:
	return smoothstep(PIXEL_M_MIN, PIXEL_M_FULL, metres_per_pixel)


## The local solar hour at [param lon_deg] when the star stands over [param sub_lon_deg] — the
## service's own formula (weather-core spin.rs: local_solar_hours), noon under the star.
static func local_hours(sub_lon_deg: float, lon_deg: float) -> float:
	return fposmod((sub_lon_deg - lon_deg) / 360.0 * 24.0 + 12.0, 24.0)


## One line for the cursor readout: the weather at [param local] (a direction in the body's frame),
## or "" when nothing is drawn.
func cursor_line(local: Vector3) -> String:
	if not enabled or _profile == null or _texture == null:
		return ""
	var ll: Vector2 = HEALPix.vec2lonlat(local)
	var s: Dictionary = WeatherSampler.sample(_profile, _systems, ll.x, ll.y, 0.0,
			local_hours(_sub_lon, ll.x), _decl)
	return tr("%%HUD_MAP_CURSOR_WEATHER") % ["%.0f" % (float(s["wind_speed_m_s"]) * 3.6),
			DevReadouts.compass(float(s["wind_from_deg"])), "%.0f" % (float(s["pressure_pa"]) / 100.0),
			"%+.0f" % (float(s["pressure_anomaly_pa"]) / 100.0), "%.0f" % (float(s["temperature_k"]) - 273.15),
			"%.2f" % float(s["dust_tau"])]


## One line for the debug panel: what is drawn, from how many systems.
func readout() -> String:
	var status: String
	if not enabled:
		status = tr("%%HUD_MAP_WEATHER_OFF")
	elif _profile == null:
		status = tr("%%HUD_MAP_WEATHER_FAR")
	elif _task >= 0:
		status = tr("%%HUD_MAP_WEATHER_BUSY")
	else:
		status = tr("%%HUD_MAP_WEATHER_DRAWN")
	return tr("%%HUD_MAP_WEATHER") % [_systems.size(), GRID_W, GRID_H, status]


## Let the worker finish before the node goes: its result is nobody's then, but a task is never
## abandoned mid-flight.
func clear() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_pending = {}


func _exit_tree() -> void:
	clear()


func _due(t: float, count: int) -> bool:
	if _drawn_count != count or absf(t - _drawn_t) > TIME_JUMP_S:
		return true
	return Time.get_ticks_msec() - _drawn_at_ms > int(REFRESH_S * 1000.0)


func _start(profile: ClimateProfile, systems: Array, substellar: Vector2, t: float) -> void:
	_profile = profile
	_systems = systems.duplicate(true)
	_sub_lon = substellar.x
	_decl = substellar.y
	# The worker's own copies: it reads them while this node goes on answering the cursor.
	var work: Array = _systems.duplicate(true)
	var sub_lon: float = _sub_lon
	var decl: float = _decl
	var out: Dictionary = {}
	_pending = out
	_task = WorkerThreadPool.add_task(func() -> void:
		out.merge(build_fields(profile, work, sub_lon, decl, GRID_W, GRID_H)))
	_drawn_t = t
	_drawn_count = systems.size()
	_drawn_at_ms = Time.get_ticks_msec()


func _collect() -> void:
	if not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var image: Image = _pending.get("image")
	if image == null:
		return
	if _texture == null or Vector2i(_texture.get_size()) != image.get_size():
		_texture = ImageTexture.create_from_image(image)
		_material.set_shader_parameter(&"fields", _texture)
	else:
		_texture.update(image)
	_place_arrows(_pending.get("arrows", PackedFloat32Array()))
	_pending = {}


## The fields over the whole body on a [param w] × [param h] lon/lat grid, cell centres from
## longitude -180 (left) and latitude +90 (top): an RGBAF image whose texel is the sample at the
## cell's centre — r = pressure anomaly (Pa), g = dust optical depth, b = humidity, a = wind speed
## (m/s) — and, for every ARROW_EVERY-th cell both ways, [lon, lat, wind east, wind north].
## Pure: runs on the worker.
static func build_fields(profile: ClimateProfile, systems: Array, sub_lon_deg: float, decl_deg: float,
		w: int, h: int) -> Dictionary:
	var image: Image = Image.create_empty(w, h, false, Image.FORMAT_RGBAF)
	var arrows := PackedFloat32Array()
	var pick: int = ARROW_EVERY / 2
	for y in h:
		var lat: float = 90.0 - (float(y) + 0.5) * 180.0 / float(h)
		var arrow_row: bool = y % ARROW_EVERY == pick
		for x in w:
			var lon: float = -180.0 + (float(x) + 0.5) * 360.0 / float(w)
			var s: Dictionary = WeatherSampler.sample(profile, systems, lon, lat, 0.0,
					local_hours(sub_lon_deg, lon), decl_deg)
			image.set_pixel(x, y, Color(float(s["pressure_anomaly_pa"]), float(s["dust_tau"]),
					float(s["humidity"]), float(s["wind_speed_m_s"])))
			if arrow_row and x % ARROW_EVERY == pick:
				arrows.append(lon)
				arrows.append(lat)
				arrows.append(float(s["wind_east_m_s"]))
				arrows.append(float(s["wind_north_m_s"]))
	return {"image": image, "arrows": arrows}


## Where an arrow stands and points for a wind ([param east], [param north] m/s) at (lon, lat), on a
## shell of [param radius] with arrows [param spacing] apart (both in the sphere's units): its -Z along
## the wind, its +Y radial, its length a share of the spacing that grows with the wind to ARROW_MAX_MS.
static func arrow_transform(lon_deg: float, lat_deg: float, east: float, north: float, radius: float,
		spacing: float) -> Transform3D:
	var up: Vector3 = HEALPix.lonlat2vec(lon_deg, lat_deg)
	var axes: Array = WeatherSampler.local_axes(lon_deg, lat_deg)
	var wind: Vector3 = (axes[0] as Vector3) * east + (axes[1] as Vector3) * north
	var speed: float = wind.length()
	if speed <= 0.0:
		return Transform3D(Basis.from_scale(Vector3.ZERO), up * radius)
	var length: float = spacing * ARROW_FILL * minf(speed / ARROW_MAX_MS, 1.0)
	var basis: Basis = Basis.looking_at(wind / speed, up)
	return Transform3D(basis * Basis.from_scale(Vector3(length, length, length)), up * radius)


func _place_arrows(data: PackedFloat32Array) -> void:
	var multimesh: MultiMesh = _arrows.multimesh
	var radius: float = MESH_RADIUS * (1.0 + LIFT)
	var spacing: float = TAU * radius / float(GRID_W / ARROW_EVERY)
	var n: int = 0
	for i in range(0, data.size() - 3, 4):
		var east: float = data[i + 2]
		var north: float = data[i + 3]
		if sqrt(east * east + north * north) < ARROW_MIN_MS or n >= multimesh.instance_count:
			continue
		multimesh.set_instance_transform(n, arrow_transform(data[i], data[i + 1], east, north, radius, spacing))
		n += 1
	multimesh.visible_instance_count = n


## A flat arrow of length 1 pointing down -Z from the origin, in the XZ plane: a stem and a head.
static func _arrow_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array([
		Vector3(-0.06, 0.0, 0.0), Vector3(0.06, 0.0, 0.0), Vector3(0.06, 0.0, -0.62),
		Vector3(-0.06, 0.0, 0.0), Vector3(0.06, 0.0, -0.62), Vector3(-0.06, 0.0, -0.62),
		Vector3(-0.2, 0.0, -0.55), Vector3(0.2, 0.0, -0.55), Vector3(0.0, 0.0, -1.0),
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
