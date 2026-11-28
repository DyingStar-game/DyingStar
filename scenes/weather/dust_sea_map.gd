class_name DustSeaMap
extends RefCounted
## The colour of the rock under the dust sea, as the sea's shader sees it (dust_sea.gdshaderinc, sea_map):
## an equirectangular map of the ground's dust albedo (WeatherSky.blow_albedo_of) over the whole planet,
## so the sea is tinted by the rock it lies on, past the drawn terrain and from orbit.
##
## Built once per planet on a worker thread (the October cloud layer's CloudPlanetMap, smaller: the tint
## is a broad wash, a texel ~150 km wide at the equator is plenty). The query reads only what the planet
## loaded (GroundLook.colour_at, as the chunk workers do), and is asked once on the main thread first so
## whatever it builds lazily is built before the worker starts. The job's result is its own object, held
## by the job's closure, and a map freed mid-job waits for it.
##
## Kept on disk once built (CACHE_DIR, keyed by the planet's look_signature): 32 768 ground colours took one
## worker ~110 s at every arrival on tarsis_3 (2026-11-27), for the same map each time.

const WIDTH: int = 256
const HEIGHT: int = 128
## Where built maps are kept, one file a planet and look: <planet>_<look_signature>_f<FORMAT>.bin.
const CACHE_DIR := "user://dust_sea_map/"
## Bump when the map's own rule changes (WIDTH/HEIGHT, direction_of, WeatherSky.blow_albedo_of): the planet's
## key does not see those.
const FORMAT := 1

## The map, once built: rgb = the dust albedo.
var ready: bool = false
var texture: ImageTexture = null

var _task: int = -1
var _job: JobResult = null
## The cache key of the build running (update's).
var _key: String = ""


class JobResult extends RefCounted:
	var texels: PackedFloat32Array = PackedFloat32Array()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _task >= 0:
		PerfTasks.wait(_task, "dust_sea_map")


## The cache key of [param data]'s map (cache_path), "" when the planet has no look signature yet.
static func cache_key(data: PlanetData) -> String:
	return "" if data == null or data.look_signature == "" else "%s_%s" % [data.planet_name, data.look_signature]


## The file of the map of key [param key] (cache_key).
static func cache_path(key: String) -> String:
	return CACHE_DIR + "%s_f%d.bin" % [key, FORMAT]


## Start the build when none ran, collect it when done: [param colour] gives the ground's colour along a
## planet-local unit direction. [param key] (cache_key): the map is read from the disk when it was built
## before with this key, and written there once built; "" builds it every time. Returns true the frame the
## map is complete.
func update(colour: Callable, key: String = "") -> bool:
	if ready:
		return false
	if _task < 0:
		var cached := _read(key)
		if not cached.is_empty():
			_publish(cached)
			return true
		_key = key
		_start(colour)
		return false
	if not WorkerThreadPool.is_task_completed(_task):
		return false
	PerfTasks.wait(_task, "dust_sea_map")
	_task = -1
	_write(_key, _job.texels)
	_publish(_job.texels)
	_job = null
	return true



func _publish(texels: PackedFloat32Array) -> void:
	var image := Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_RGBF, texels.to_byte_array())
	texture = ImageTexture.create_from_image(image)
	ready = true


## The texels kept for [param key], empty when there are none (or not of the right size).
static func _read(key: String) -> PackedFloat32Array:
	if key == "" or not FileAccess.file_exists(cache_path(key)):
		return PackedFloat32Array()
	var bytes := FileAccess.get_file_as_bytes(cache_path(key))
	if bytes.size() != WIDTH * HEIGHT * 3 * 4:
		return PackedFloat32Array()
	return bytes.to_float32_array()


## Keeps [param texels] for [param key], and drops the planet's maps of other keys (an older look).
static func _write(key: String, texels: PackedFloat32Array) -> void:
	if key == "":
		return
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	# The planet is all but the signature (hex, no "_"): tarsis_3 must not take tarsis_30's maps along.
	var planet := key.substr(0, key.rfind("_") + 1)
	for old: String in DirAccess.get_files_at(CACHE_DIR):
		if old.begins_with(planet) and old.trim_prefix(planet).count("_") == 1 \
				and old != cache_path(key).get_file():
			DirAccess.remove_absolute(CACHE_DIR + old)
	AtomicFile.write_buffer(cache_path(key), texels.to_byte_array())


func _start(colour: Callable) -> void:
	colour.call(Vector3.UP)  # a lazily built cache is built here, not raced on the worker
	var result := JobResult.new()
	_job = result
	_task = PerfTasks.add_task("weather:dust_sea_map", func() -> void:
		var texels := PackedFloat32Array()
		texels.resize(WIDTH * HEIGHT * 3)
		for j in HEIGHT:
			DustSeaMap.build_row(texels, j, colour)
		result.texels = texels, false, "dust sea map")


## Row [param j] of [param texels] (WIDTH x HEIGHT x 3): each texel's dust albedo.
static func build_row(texels: PackedFloat32Array, j: int, colour: Callable) -> void:
	for i in WIDTH:
		var albedo: Vector3 = WeatherSky.blow_albedo_of(colour.call(direction_of(i, j)))
		var k: int = (j * WIDTH + i) * 3
		texels[k] = albedo.x
		texels[k + 1] = albedo.y
		texels[k + 2] = albedo.z


## The planet-local unit direction at the centre of texel ([param i], [param j]): the inverse of
## PlanetData.direction_to_uv (u the longitude from -180 deg, v the latitude from the north pole;
## longitude runs from +X toward -Z).
static func direction_of(i: int, j: int) -> Vector3:
	var lon: float = ((i + 0.5) / float(WIDTH) - 0.5) * TAU
	var lat: float = (0.5 - (j + 0.5) / float(HEIGHT)) * PI
	return Vector3(cos(lat) * cos(lon), sin(lat), -cos(lat) * sin(lon))
