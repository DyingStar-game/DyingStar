class_name WeatherLab
extends Node3D
## A dev scene that looks at the weather from anywhere, without a server: Tarsis 3 and its star from
## the menu's world scene, a camera rig placed at each viewpoint of a tour (longitude, latitude,
## altitude, heading, pitch, the sun's height), the player's own sky around it (ClientSky: sun,
## atmosphere, cloud volume, moons). At each viewpoint it waits for the ground and the weather grid,
## then saves a screenshot and a sidecar of numbers (the weather there, the frame rate, the GPU time),
## and quits once the tour is done. A cloud sea has to be judged from below, inside, above and from
## orbit: flying there by hand takes minutes per look and nothing measures it.
##
## Run: godot --path . res://levels/weather_lab/weather_lab.tscn -- --tour=<json> --out=<dir> [--stay]
## The tour: {"systems": [WeatherSystem.state() dicts, optional], "views": [{"name", "lon", "lat",
## "alt" (m over the reference sphere) or "agl" (m over the ground), "heading" (deg, 0 = north,
## 90 = east), "pitch" (deg, + up), "sun" (deg over the horizon, morning side), "wait" (s),
## "ground": "lowest" (stand on the lowest ground within "search_deg" of lon/lat instead),
## "layers_off": [WeatherPanel layer labels]}]}.

const WORLD_SCENE: String = "res://levels/menu_stage/menu_stage_world.tscn"
const PLANET_NODE: String = "Tarsis3"
const DEFAULT_WAIT_S: float = 10.0
const DEFAULT_SUN_DEG: float = 25.0
## How long the frame rate and the GPU time are averaged before a capture (s).
const MEASURE_S: float = 2.0
## Longest wait for the first ground before the tour starts anyway (s).
const GROUND_TIMEOUT_S: float = 20.0

var _session := StageSession.new()
var _planet: Planet = null
var _rig: StageRig = null
var _banner: DevBanner = null
var _readback: ScreenReadback = null
var _tour: Dictionary = {}
var _out_dir: String = ""
var _stay: bool = false
var _survey: bool = false
var _frame_ms: PackedFloat64Array = []
var _gpu_ms: PackedFloat64Array = []
var _measuring: bool = false


func _ready() -> void:
	_read_args()
	_banner = DevBanner.new("WeatherLabBanner")
	add_child(_banner)
	_readback = ScreenReadback.new()
	add_child(_readback)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_banner.show_text("weather lab: loading %s" % PLANET_NODE)
	_run.call_deferred()


func _exit_tree() -> void:
	_session.end()


func _process(delta: float) -> void:
	if _measuring:
		_frame_ms.append(delta * 1000.0)
		_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))


## --tour=<path> (res:// or absolute; the built-in tour without it), --out=<dir>, --stay.
func _read_args() -> void:
	_out_dir = OS.get_user_data_dir().path_join("lab")
	var tour_path: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--tour="):
			tour_path = arg.trim_prefix("--tour=")
		elif arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=")
		elif arg == "--stay":
			_stay = true
		elif arg == "--survey":
			_survey = true
	_tour = _load_tour(tour_path)
	DirAccess.make_dir_recursive_absolute(_out_dir)


## The tour at [param path], or the built-in one (the user's cliff, below, inside, above, orbit).
## Longitudes are the planet's QGIS ones (lon = atan2(-z, x) since the re-export of 2026-10-08): a place
## keeps its longitude, its 3D position is what the re-export mirrored.
static func _load_tour(path: String) -> Dictionary:
	if path != "" and FileAccess.file_exists(path):
		var text: String = FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			return parsed
		push_warning("[WeatherLab] %s is not a JSON object; the built-in tour runs instead" % path)
	return {"views": [
		{"name": "cliff_4102m_n", "lon": -16.90, "lat": 0.49, "alt": 4102.0, "heading": 0.0, "pitch": -5.0},
		{"name": "cliff_4102m_e", "lon": -16.90, "lat": 0.49, "alt": 4102.0, "heading": 90.0, "pitch": -5.0},
		{"name": "cliff_4102m_s", "lon": -16.90, "lat": 0.49, "alt": 4102.0, "heading": 180.0, "pitch": -5.0},
		{"name": "cliff_4102m_w", "lon": -16.90, "lat": 0.49, "alt": 4102.0, "heading": 270.0, "pitch": -5.0},
		{"name": "valley_floor", "lon": -16.90, "lat": 0.49, "ground": "lowest", "search_deg": 1.5, "agl": 2.0,
			"heading": 0.0, "pitch": 10.0},
		{"name": "inside_2000m", "lon": -16.90, "lat": 0.49, "ground": "lowest", "search_deg": 1.5, "alt": 2000.0,
			"heading": 0.0, "pitch": 0.0},
		{"name": "above_6km", "lon": -16.90, "lat": 0.49, "alt": 6000.0, "heading": 90.0, "pitch": -15.0},
		{"name": "air_12km", "lon": -16.90, "lat": 0.49, "alt": 12000.0, "heading": 90.0, "pitch": -25.0},
		{"name": "high_30km", "lon": -16.90, "lat": 0.49, "alt": 30000.0, "heading": 90.0, "pitch": -35.0},
		{"name": "high_80km", "lon": -16.90, "lat": 0.49, "alt": 80000.0, "heading": 90.0, "pitch": -45.0},
		{"name": "orbit_400km", "lon": -16.90, "lat": 0.49, "alt": 400000.0, "heading": 90.0, "pitch": -60.0},
		{"name": "orbit_2000km", "lon": -16.90, "lat": 0.49, "alt": 2000000.0, "heading": 90.0, "pitch": -80.0},
	]}


func _run() -> void:
	for i in 2:
		await get_tree().process_frame
	var world: Node3D = load(WORLD_SCENE).instantiate()
	_session.begin(world)
	add_child(world)
	_planet = world.get_node(PLANET_NODE)
	# The menu's set (its outpost, its dictated wind) is not the weather: gone.
	for extra: String in ["Outpost", "StageWind"]:
		var node: Node = _planet.get_node_or_null(extra)
		if node != null:
			node.queue_free()
	for system: Variant in _tour.get("systems", []):
		if system is Dictionary:
			_planet.debug_weather_systems.append(system)
	if _survey:
		survey(_planet.planet_data)
	_rig = StageRig.new()
	_planet.add_child(_rig)
	ClientSky.attach(_rig)
	var ground_ready: Array = [false]
	if _planet.planet_terrain != null:
		_planet.planet_terrain.initial_chunks_ready.connect(func() -> void: ground_ready[0] = true, CONNECT_ONE_SHOT)
	var views: Array = _tour.get("views", [])
	if views.is_empty():
		push_warning("[WeatherLab] no view in the tour")
	else:
		_place(views[0])
		var waited: float = 0.0
		while waited < GROUND_TIMEOUT_S and not ground_ready[0]:
			await get_tree().process_frame
			waited += get_process_delta_time()
		print("[WeatherLab] first ground after %.1f s (%s)" % [waited, "ready" if ground_ready[0] else "late"])
	for view: Dictionary in views:
		await _visit(view)
	print("[WeatherLab] tour done: %d views in %s" % [views.size(), _out_dir])
	if not _stay:
		get_tree().quit()


## Stand at [param view], wait, measure, capture.
func _visit(view: Dictionary) -> void:
	var where: Dictionary = _place(view)
	var name: String = String(view.get("name", "view"))
	var off: Array = view.get("layers_off", [])
	WeatherPanel.off.clear()
	for label: Variant in off:
		for i in WeatherPanel.LAYERS.size():
			if WeatherPanel.LAYERS[i][0] == String(label):
				WeatherPanel.set_layer(i, false)
	var wait: float = float(view.get("wait", DEFAULT_WAIT_S))
	var clock: float = 0.0
	_frame_ms.clear()
	_gpu_ms.clear()
	_measuring = false
	while clock < wait:
		await get_tree().process_frame
		clock += get_process_delta_time()
		_measuring = clock >= wait - MEASURE_S
		_banner.show_text("%s  %s  %.0f s" % [name, _caption(where), wait - clock])
	_measuring = false
	var fps: Dictionary = WeatherBench.stats(_frame_ms)
	var gpu: Dictionary = WeatherBench.stats(_gpu_ms)
	_banner.show_text("%s  %s  %.0f fps  gpu %.1f ms" % [name, _caption(where),
			1000.0 / maxf(float(fps["mean"]), 0.001), float(gpu["median"])])
	await get_tree().process_frame
	var image: Image = await _readback.capture(get_tree().root)
	image.convert(Image.FORMAT_RGB8)
	var png: String = _out_dir.path_join(name + ".png")
	var err: Error = image.save_png(png)
	var sample: Dictionary = _planet.weather_at(_rig.global_position)
	var report: Dictionary = {
		"view": view, "where": where, "frame_ms": fps, "gpu_ms": gpu,
		"fps": 1000.0 / maxf(float(fps["mean"]), 0.001),
		"wind_speed_m_s": sample.get("wind_speed_m_s", 0.0), "wind_from_deg": sample.get("wind_from_deg", 0.0),
		"dust_tau": sample.get("dust_tau", 0.0), "pressure_anomaly_pa": sample.get("pressure_anomaly_pa", 0.0),
		"adapter": RenderingServer.get_video_adapter_name(), "window": get_viewport().get_visible_rect().size,
		"layers_off": off,
	}
	var json := FileAccess.open(_out_dir.path_join(name + ".json"), FileAccess.WRITE)
	if json != null:
		json.store_string(JSON.stringify(report, "\t"))
	print("[WeatherLab] %s: %s -> %s (%s) %.0f fps, gpu %.1f ms" % [name, _caption(where), png, error_string(err),
			report["fps"], float(gpu["median"])])


## Put the rig at [param view] and the sun where it asks; returns where it stands (lon, lat, alt over
## the sphere, agl over the ground, sun elevation).
func _place(view: Dictionary) -> Dictionary:
	var lon: float = float(view.get("lon", 0.0))
	var lat: float = float(view.get("lat", 0.0))
	var data: PlanetData = _planet.planet_data
	if String(view.get("ground", "")) == "lowest":
		var low: Vector2 = lowest_ground(data, lon, lat, float(view.get("search_deg", 1.0)))
		lon = low.x
		lat = low.y
	var dir: Vector3 = HEALPix.lonlat2vec(lon, lat)
	var ground: float = data.crack_aware_surface_dist(dir)
	var r: float = data.radius + float(view["alt"]) if view.has("alt") else ground + float(view.get("agl", 2.0))
	var eye: Vector3 = dir * r
	var axes: Array = WeatherSampler.local_axes(lon, lat)
	var heading: float = deg_to_rad(float(view.get("heading", 0.0)))
	var pitch: float = deg_to_rad(float(view.get("pitch", 0.0)))
	var flat: Vector3 = (axes[1] as Vector3) * cos(heading) + (axes[0] as Vector3) * sin(heading)
	var forward: Vector3 = flat * cos(pitch) + dir * sin(pitch)
	_rig.frame(eye, eye + forward * 1000.0)
	var sun: float = float(view.get("sun", DEFAULT_SUN_DEG))
	var reached: float = StageClock.set_sun_elevation(_planet, dir * ground, sun, bool(view.get("morning", true)))
	return {"lon": lon, "lat": lat, "alt": r - data.radius, "agl": r - ground, "sun": sun,
			"hour": reached, "ground_alt": ground - data.radius}


static func _caption(where: Dictionary) -> String:
	return "lon %.2f lat %.2f alt %.0f m (agl %.0f, ground %.0f) sun %.0f deg" % [where["lon"], where["lat"],
			where["alt"], where["agl"], where["ground_alt"], where["sun"]]


## --survey: the planet's relief at a glance, from the global heightmap (PlanetData.sample_height_at,
## every 2 degrees): the share of the ground under the sea's top and the ten lowest places, so a tour
## can be laid over lowlands (a sea of clouds is nowhere over a plateau).
static func survey(data: PlanetData) -> void:
	var top: float = data.atmosphere_profile.haze_top if data.atmosphere_profile != null else 4000.0
	var cells: Array = []
	var under: int = 0
	for j in 90:
		for i in 180:
			var lon: float = -180.0 + (i + 0.5) * 2.0
			var lat: float = 90.0 - (j + 0.5) * 2.0
			var h: float = data.sample_height_at(HEALPix.lonlat2vec(lon, lat))
			if h < top:
				under += 1
			cells.append([h, lon, lat])
	cells.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	print("[WeatherLab] survey: %.0f %% of the ground under the sea's top (%.0f m); lowest cells (m, lon, lat):" % [
			100.0 * under / cells.size(), top])
	for c: Array in cells.slice(0, 10):
		print("[WeatherLab]   %6.0f m at lon %7.1f lat %6.1f" % [c[0], c[1], c[2]])
	var mid: Array = cells[cells.size() / 2]
	print("[WeatherLab]   median ground %.0f m; highest %.0f m" % [mid[0], (cells.back() as Array)[0]])


## The (lon, lat) of the lowest ground within [param span_deg] of (lon, lat) on [param data], on a
## 41 x 41 grid.
static func lowest_ground(data: PlanetData, lon: float, lat: float, span_deg: float) -> Vector2:
	var best := Vector2(lon, lat)
	var lowest: float = INF
	for j in 41:
		for i in 41:
			var p := Vector2(lon + span_deg * (i - 20) / 20.0, lat + span_deg * (j - 20) / 20.0)
			var h: float = data.crack_aware_surface_dist(HEALPix.lonlat2vec(p.x, p.y))
			if h < lowest:
				lowest = h
				best = p
	print("[WeatherLab] lowest ground within %.1f deg of (%.2f, %.2f): %.0f m at (%.3f, %.3f)" % [
			span_deg, lon, lat, lowest - data.radius, best.x, best.y])
	return best
