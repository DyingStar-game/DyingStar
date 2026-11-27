extends GutTest
## PerfTasks: the WorkerThreadPool tasks' time put to their site names ([CPerfW]), and ClientPerf's two
## pure readers of the other new lines: thread groups ([CPerfT]) and GPU passes ([CPerfG]).

var _was_on: bool = false


func before_each() -> void:
	_was_on = PerfTasks.on
	PerfTasks.take_window(Time.get_ticks_usec())


func after_each() -> void:
	PerfTasks.on = _was_on
	PerfTasks.take_window(Time.get_ticks_usec())


func test_off_it_is_the_pool_and_records_nothing() -> void:
	PerfTasks.on = false
	var ran := [false]
	var id: int = PerfTasks.add_task("test:off", func() -> void: ran[0] = true)
	WorkerThreadPool.wait_for_task_completion(id)
	assert_true(ran[0], "the task ran")
	assert_false(PerfTasks.take_window(Time.get_ticks_usec()).has("test:off"), "nothing recorded when off")


func test_on_a_task_is_timed_under_its_site() -> void:
	PerfTasks.on = true
	var id: int = PerfTasks.add_task("test:sleep", func() -> void: OS.delay_msec(20))
	WorkerThreadPool.wait_for_task_completion(id)
	var rows: Dictionary = PerfTasks.take_window(Time.get_ticks_usec())
	assert_true(rows.has("test:sleep"))
	var row: Array = rows["test:sleep"]
	assert_between(int(row[0]), 19_000, 2_000_000, "~20 ms held")
	assert_eq(int(row[1]), 1, "one task done")
	assert_eq(int(row[2]), 0, "none running")
	assert_false(PerfTasks.take_window(Time.get_ticks_usec()).has("test:sleep"), "the next window is empty")


func test_a_group_counts_each_element() -> void:
	PerfTasks.on = true
	var hits := [0, 0, 0, 0]  # an Array: a lambda captures a packed array by value
	var mutex := Mutex.new()
	var id: int = PerfTasks.add_group_task("test:group", func(i: int) -> void:
		mutex.lock()
		hits[i] += 1
		mutex.unlock(), 4)
	WorkerThreadPool.wait_for_group_task_completion(id)
	assert_eq(hits, [1, 1, 1, 1], "every element once, with its index")
	assert_eq(int((PerfTasks.take_window(Time.get_ticks_usec())["test:group"] as Array)[1]), 4)


func test_a_running_task_counts_the_part_of_the_window_it_ran_in() -> void:
	PerfTasks.on = true
	var release := Semaphore.new()
	var id: int = PerfTasks.add_task("test:long", func() -> void: release.wait())
	OS.delay_msec(30)
	var rows: Dictionary = PerfTasks.take_window(Time.get_ticks_usec())
	var row: Array = rows["test:long"]
	assert_eq(int(row[2]), 1, "running at the window's end")
	assert_gt(int(row[0]), 20_000, "its time so far is counted")
	release.post()
	WorkerThreadPool.wait_for_task_completion(id)
	var after: Array = PerfTasks.take_window(Time.get_ticks_usec())["test:long"]
	assert_lt(int(after[0]), 20_000, "the next window counts only what it ran after the first one closed")
	assert_eq(int(after[1]), 1)


func test_line_ranks_sites_as_shares_of_one_core() -> void:
	var rows := {"a": [2_000_000, 3, 0, 0.0], "b": [4_000_000, 1, 2, 7.5], "tiny": [1_000, 1, 0, 0.0]}
	assert_eq(PerfTasks.line(rows, 2.0), "busy=300% | b=200%(done=1 run=2 oldest=7.5s) a=100%(done=3)")


func test_thread_groups() -> void:
	assert_eq(ClientPerf.thread_group("Godot_v4.7.2-st", 100, 100, "Godot_v4.7.2-st"), "main")
	assert_eq(ClientPerf.thread_group("Godot_v4.7.2-st", 101, 100, "Godot_v4.7.2-st"), "unnamed")
	assert_eq(ClientPerf.thread_group("WorkerThread 12", 102, 100, "Godot_v4.7.2-st"), "WorkerThread")
	assert_eq(ClientPerf.thread_group(".NET TP Worker", 103, 100, "Godot_v4.7.2-st"), ".NET TP Worker")
	assert_eq(ClientPerf.thread_group("tokio-runtime-w", 104, 100, "Godot_v4.7.2-st"), "tokio-runtime-w")


func test_gpu_passes_follow_the_engine_profile() -> void:
	var names := PackedStringArray(["Begin", "> Render Viewport 0", "Render Shadows", "Render Opaque Pass",
			"< Render Viewport 0", "> Render Viewport 1", "Render Opaque Pass", "< Render Viewport 1", "End"])
	var ms := 1_000_000
	var times := PackedInt64Array([0, 1 * ms, 2 * ms, 6 * ms, 10 * ms, 10 * ms, 11 * ms, 12 * ms, 13 * ms])
	var out: Dictionary = ClientPerf.gpu_passes(names, times)
	assert_almost_eq(float(out["Render Shadows"]), 4.0, 0.001)
	assert_almost_eq(float(out["Render Opaque Pass"]), 4.0 + 1.0, 0.001, "summed over both viewports")
	assert_almost_eq(float(out["viewport 0"]), 9.0, 0.001)
	assert_almost_eq(float(out["viewport 1"]), 2.0, 0.001)
	assert_almost_eq(float(out["total"]), 13.0, 0.001)
	assert_false(out.has("> Render Viewport 0"), "markers are not passes")
	assert_eq(ClientPerf.gpu_passes(PackedStringArray(["one"]), PackedInt64Array([5])), {})
