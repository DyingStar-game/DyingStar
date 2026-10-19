extends GutTest
## The crack POI list is read by the chunk builders on worker threads (CrackCarve.prepare_frame,
## chunk_cache_ineligible) while the main thread publishes a new one every time a POI village is
## registered (PlanetTerrain.set_poi_zone). Replacing an Array member is not atomic in Godot: a worker
## taking its reference while the main thread drops the last one of the old list read a freed Array —
## "Condition !success" in Array::_ref, then SIGSEGV (test/perf/server_ingest_bench, 2026-10-16, 3 runs
## in 12 while 118 villages came in). This hammers both sides at once; before the fix it crashed the
## test runner within a few thousand publications.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_crack_pois_thread_safety.gd

const RADIUS := 6356000.0
const PUBLICATIONS := 20000

var _pd: PlanetData
var _stop: bool = false
var _reads: int = 0


func before_each() -> void:
	_pd = PlanetData.new()
	_pd.radius = RADIUS
	_pd.crack_poi_margin_m = 300.0
	_stop = false
	_reads = 0


func _reader(_i: int) -> void:
	var near := HEALPix.lonlat2vec(-39.555, 24.857)
	while not _stop:
		# What a chunk task does: the subset around its tile, then whether it may be cached.
		_pd.crack_pois_near(near, 5000.0)
		_pd.chunk_cache_ineligible(8192, 214258375)
		_reads += 1


func test_publishing_villages_while_workers_read_them() -> void:
	var group: int = WorkerThreadPool.add_group_task(_reader, 4, 4, true)
	for k in PUBLICATIONS:
		var pois: Array = []
		for j in 1 + k % 7:
			pois.append({"dir": HEALPix.lonlat2vec(-39.555 + 0.01 * j, 24.857), "radius": 1000.0})
		_pd.set_dynamic_crack_exclusions(pois)
	_stop = true
	WorkerThreadPool.wait_for_group_task_completion(group)
	assert_gt(_reads, 0, "the workers did read while the list was being replaced")
	assert_eq(_pd.crack_pois().size(), 1 + (PUBLICATIONS - 1) % 7, "the last publication is the one read")
