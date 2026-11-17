class_name CloudPlanetMap
extends RefCounted
## The planet's colour as the cloud layer sees it (cloud_layer.gdshaderinc, cloud_planet): an
## equirectangular map of the dust's colour, the ground's as a dust albedo (WeatherSky.blow_albedo_of).
## With it every billow, past the weather grid and seen from orbit, takes the colour of its biome;
## without it the far sea was painted in the colour of the pixel behind (the terrain's grain, speckled
## from 30 km) or in one flat ochre.
##
## Built once per planet on a worker thread: half a million colour queries, seconds of work the main
## thread never feels. The query only reads what the planet loaded (the biome zones and rocks:
## GroundLook.colour_at, which the chunk workers read the same way), and it is asked once on the main
## thread first, so whatever it builds lazily is built before the worker starts. The texture is made on
## the main thread once the job is done, and handed over complete. The job's result is its own object,
## held by the job's closure, and a map freed mid-job waits for it (StormField learnt that the hard way).

const WIDTH: int = 1024
const HEIGHT: int = 512

## The map, once built: rgb = the dust albedo.
var ready: bool = false
var texture: ImageTexture = null
## The build's time on its worker (ms), for the dust probe.
var last_build_ms: float = 0.0

var _task: int = -1
var _job: JobResult = null


class JobResult extends RefCounted:
	var texels: PackedFloat32Array = PackedFloat32Array()
	var build_us: int = 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)


## Start the build when none ran, collect it when done: [param colour] gives the ground's colour along a
## planet-local unit direction (a dust albedo is made of it). Returns true the frame the map is complete.
func update(colour: Callable) -> bool:
	if ready:
		return false
	if _task < 0:
		_start(colour)
		return false
	if not WorkerThreadPool.is_task_completed(_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var image := Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_RGBF, _job.texels.to_byte_array())
	texture = ImageTexture.create_from_image(image)
	last_build_ms = _job.build_us / 1000.0
	_job = null
	ready = true
	return true


func _start(colour: Callable) -> void:
	# One query on this thread: a lazily built cache is built here, not raced on the worker.
	colour.call(Vector3.UP)
	var result := JobResult.new()
	_job = result
	_task = WorkerThreadPool.add_task(func() -> void:
		var t0: int = Time.get_ticks_usec()
		var texels := PackedFloat32Array()
		texels.resize(WIDTH * HEIGHT * 3)
		for j in HEIGHT:
			CloudPlanetMap.build_row(texels, j, colour)
		result.build_us = Time.get_ticks_usec() - t0
		result.texels = texels, false, "cloud planet map")


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
## longitude runs from +X toward -Z, the QGIS convention).
static func direction_of(i: int, j: int) -> Vector3:
	var lon: float = ((i + 0.5) / float(WIDTH) - 0.5) * TAU
	var lat: float = (0.5 - (j + 0.5) / float(HEIGHT)) * PI
	return Vector3(cos(lat) * cos(lon), sin(lat), -cos(lat) * sin(lon))
