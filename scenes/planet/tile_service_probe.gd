class_name TileServiceProbe
extends RefCounted
## Is the terrain tile service reachable for a planet? The menu stage asks before building its 3D
## scene: without the tiles the relief is flat and the buildings would float kilometres above it,
## so it keeps its still image instead.
##
## The request is synchronous (RemoteTileSource.open_planet, up to its timeout), so start() runs it
## on a worker thread and the caller polls is_done(). Keep the probe referenced until then — or call
## wait() — since the worker writes into it.

var ok : bool = false
var _task : int = -1


## The same question, answered on the calling thread. `fetcher` replaces the HTTP layer in tests.
static func check_now(planet_name: String, base_url: String = RemoteTileSource.configured_base_url(),
		fetcher: Callable = Callable()) -> bool:
	if base_url == "" or planet_name == "":
		return false
	var source := RemoteTileSource.new()
	if fetcher.is_valid():
		source.fetcher = fetcher
	return source.open_planet(base_url, planet_name)


func start(planet_name: String) -> void:
	var base_url : String = RemoteTileSource.configured_base_url()
	_task = WorkerThreadPool.add_task(func() -> void: ok = check_now(planet_name, base_url))


func is_done() -> bool:
	return _task < 0 or WorkerThreadPool.is_task_completed(_task)


## Block until the answer is in. Always call it once, even after is_done(): the pool requires every
## task to be waited for, and one left unwaited crashed the engine on exit.
func wait() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
