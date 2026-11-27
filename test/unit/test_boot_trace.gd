extends GutTest
## The start written step by step to the log (BootTrace): the step a stuck start is on, and a watch on its own
## thread that is stopped and joined with its node.


func test_a_step_is_remembered_with_its_time() -> void:
	var before := Time.get_ticks_msec()
	BootTrace.step("test: a quiet step", true)
	var at: Array = BootTrace.current()
	assert_eq(at[0], "test: a quiet step")
	assert_between(int(at[1]), before, Time.get_ticks_msec())


func test_the_watch_runs_on_its_own_thread_and_stops_with_its_node() -> void:
	var trace := BootTrace.new()
	add_child(trace)
	assert_not_null(trace._thread, "watching")
	assert_true(trace._thread.is_started())
	remove_child(trace)  # _exit_tree stops and joins it
	assert_null(trace._thread, "joined")
	trace.free()


func test_the_pool_line_names_the_threads_the_loads_get() -> void:
	var line := BootTrace.pool_line()
	assert_string_contains(line, "CPU threads")
	assert_string_contains(line, "for loads")
