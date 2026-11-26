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

const WIDTH: int = 256
const HEIGHT: int = 128

## The map, once built: rgb = the dust albedo.
var ready: bool = false
var texture: ImageTexture = null

var _task: int = -1
var _job: JobResult = null


class JobResult extends RefCounted:
	var texels: PackedFloat32Array = PackedFloat32Array()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)


## Start the build when none ran, collect it when done: [param colour] gives the ground's colour along a
## planet-local unit direction. Returns true the frame the map is complete.
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
	_job = null
	ready = true
	return true


func _start(colour: Callable) -> void:
	colour.call(Vector3.UP)  # a lazily built cache is built here, not raced on the worker
	var result := JobResult.new()
	_job = result
	_task = WorkerThreadPool.add_task(func() -> void:
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
