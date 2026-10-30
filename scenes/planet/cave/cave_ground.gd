class_name CaveGround
extends RefCounted
## The ground under a cave, read through the terrain's native sampler (PlanetData.TileFrame, the chunk builders'
## C# path) instead of one GDScript query per point: bit-identical to PlanetData.crack_aware_surface_dist, 4 to 22
## times faster (measured 2026-10-30 on the Tarsis III caves: 115-513 µs a point down to 19-31 µs).
##
## A cave fit or a cave plan reads the ground under every roof point of the network, tens of thousands of them,
## all in one or two export tiles: the frames are prepared once per export tile and kept for the job.
##
## A TileFrame is not thread-safe and keeps what it read (a tile missing when first read stays missing), so it
## lives for ONE job on ONE thread: [method run] opens it around the job and every query made from that thread
## inside the job uses it (CaveEntrance.ground_in_frame). Outside a job, a query takes the plain GDScript path.

const _PLANET_DATA := preload("res://scenes/planet/planet_data.gd")

static var _scopes: Dictionary = {}  # thread caller id -> CaveGround
static var _mutex := Mutex.new()

var _data: PlanetData
var _frames: Dictionary = {}  # export ipix -> PlanetData.TileFrame


## Runs [param job] with this thread's ground queries on [param data] answered by the native sampler. A
## PlanetData subclass (the tests' synthetic planets) keeps its own crack_aware_surface_dist.
static func run(data: PlanetData, job: Callable) -> Variant:
    if data.get_script() != _PLANET_DATA:
        return job.call()
    var ground := CaveGround.new()
    ground._data = data
    var thread := OS.get_thread_caller_id()
    _mutex.lock()
    var outer: Variant = _scopes.get(thread)
    _scopes[thread] = ground
    _mutex.unlock()
    var result: Variant = job.call()
    _mutex.lock()
    if outer == null:
        _scopes.erase(thread)
    else:
        _scopes[thread] = outer
    _mutex.unlock()
    return result


## Distance (m) from the planet centre of the ground along [param direction], cracks included.
static func surface_dist(data: PlanetData, direction: Vector3) -> float:
    _mutex.lock()
    var ground: CaveGround = _scopes.get(OS.get_thread_caller_id())
    _mutex.unlock()
    if ground == null or ground._data != data:
        return data.crack_aware_surface_dist(direction, data.export_nside)
    return ground._surface_dist(direction)


func _surface_dist(direction: Vector3) -> float:
    var nside := _data.export_nside
    var ipix := HEALPix.vec2pix_nest(nside, direction)
    var frame: PlanetData.TileFrame = _frames.get(ipix)
    if frame == null:
        # What the chunk builders give a chunk's frame: the mountains and cracks of its export tile.
        frame = _data.make_tile_frame()
        _data.prepare_mountain_frame(frame, nside, ipix)
        CrackCarve.prepare_frame(_data, frame, nside, ipix)
        _frames[ipix] = frame
    return _data.radius + _data.sample_height_for_direction(direction, ipix, -1, Vector2i(-1, -1), null, nside, frame,
        0.0, CrackCarve.AUTO)
