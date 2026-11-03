extends GutTest
## Shared PlanetData state the WorkerThreadPool reads while another thread writes it. A Windows client
## crashed on 2026-11-01 (STATUS_HEAP_CORRUPTION, free() during a Dictionary insert in a static GDScript
## function on a worker, a second worker in GDScript too). Two such races were found:
##
## - stargrot_plans: replaced by the main thread at every residency change (CaveResidentSet._publish)
##   while every chunk task reads it (stargrot_placements, when no cut site is published). Replacing an
##   Array member is not atomic: a worker taking its reference while the main thread drops the last one
##   reads a freed Array (as crack_pois, test_crack_pois_thread_safety).
## - the biome cache: built lazily by whichever thread asks first; the star map's offline copy of a
##   planet came cold to three workers, which cleared and filled the same dictionaries together.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_worker_shared_state_thread_safety.gd

const PUBLICATIONS := 20000
const COLD_BUILDS := 200

var _pd: PlanetData
var _stop: bool = false
var _reads: int = 0
var _misses: int = 0


func before_each() -> void:
	_pd = PlanetData.new()
	_stop = false
	_reads = 0
	_misses = 0


func _plans_reader(_i: int) -> void:
	while not _stop:
		# What a chunk task does when no cut site is published.
		_pd.stargrot_placements()
		_reads += 1


func test_publishing_cave_plans_while_workers_read_them() -> void:
	var placement := CavePlacement.new()
	var group: int = WorkerThreadPool.add_group_task(_plans_reader, 4, 4, true)
	for k in PUBLICATIONS:
		var plans: Array[Dictionary] = []
		for j in k % 3:
			plans.append({"placement": placement})
		_pd.stargrot_plans = plans
	_stop = true
	WorkerThreadPool.wait_for_group_task_completion(group)
	assert_gt(_reads, 0, "the workers did read while the plans were being replaced")
	assert_eq(_pd.stargrot_placements().size(), (PUBLICATIONS - 1) % 3, "the last publication is the one read")


func _biome_reader(_i: int) -> void:
	if _pd.get_biome_by_type(ArideDesertCorundumPlateauTerrain.BIOME_TYPE) == null:
		_misses += 1


func test_cold_biome_cache_asked_by_several_workers_at_once() -> void:
	# The shared list of biome resources is loaded on the main thread, as in the game (planet_body,
	# warm_mountains): ResourceLoader on workers while this thread waits for them would block. What
	# stays cold is each instance's own cache — the star map's offline copy.
	PlanetData.new().warm_biome_cache()
	for k in COLD_BUILDS:
		_pd = PlanetData.new()  # cold, like the star map's offline copy
		var group: int = WorkerThreadPool.add_group_task(_biome_reader, 4, 4, true)
		WorkerThreadPool.wait_for_group_task_completion(group)
	assert_eq(_misses, 0, "every worker found the biome, none read a half-built cache")
