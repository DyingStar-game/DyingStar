extends GutTest
## PlanetTerrain.join_task: waits for a task still running, like wait_for_task_completion, but keeps
## the RenderingServer's queue moving meanwhile. The deadlock it prevents (a mesh task reading its
## mesh back while the main thread waits for it) needs a real renderer, which GUT's headless run
## does not have; this checks the waiting itself.


func test_it_returns_once_the_task_has_run() -> void:
	var done : Array = [false]
	var tid := WorkerThreadPool.add_task(func() -> void:
		OS.delay_msec(100)
		done[0] = true)
	PlanetTerrain.join_task(tid)
	assert_true(done[0], "the task ran to its end before the join returned")


func test_a_finished_task_joins_at_once() -> void:
	var tid := WorkerThreadPool.add_task(func() -> void: pass)
	while not WorkerThreadPool.is_task_completed(tid):
		OS.delay_msec(1)
	var t0 := Time.get_ticks_msec()
	PlanetTerrain.join_task(tid)
	assert_lt(Time.get_ticks_msec() - t0, 50, "nothing to wait for")
