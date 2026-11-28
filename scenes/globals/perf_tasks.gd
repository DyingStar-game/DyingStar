class_name PerfTasks
extends RefCounted
## WorkerThreadPool, with each task's time put to its name: what keeps the cores busy behind the frame.
##
## A client at the village burnt 6.5-7.8 cores for minutes (2026-11-27, `cpu=` on [CPerf+]) and nothing in
## the log said which tasks: the main thread was starved and every figure it printed was inflated by it.
## Every game call site goes through here with a short site name ("nova:scatter_chunk", "terrain:mesh").
## When ClientPerf is off (`on` false) this is WorkerThreadPool itself, one boolean test more.
##
## The figure is the WALL time the task held a worker thread (thread-seconds), not CPU time: GDScript has
## no per-thread CPU clock. With no more workers than cores the two agree; [CPerfT] gives the CPU side.
## A task still running when a window closes counts the part of the window it ran in, so a 20 s Nova chunk
## shows in every window it spans rather than in the one it ends in.

## Set by ClientPerf when the heartbeat is on. Read on the main thread when a task is added.
static var on: bool = false

static var _mutex: Mutex = Mutex.new()
## token -> [site, start usec]: tasks running now.
static var _running: Dictionary = {}
## site -> usec held inside the current window by the tasks that finished in it.
static var _busy: Dictionary = {}
## site -> tasks finished in the current window.
static var _done: Dictionary = {}
static var _window_start: int = 0
static var _next_token: int = 0


## WorkerThreadPool.add_task, timed under [param site]. Returns the pool's task id.
static func add_task(site: String, action: Callable, high_priority: bool = false, description: String = "") -> int:
	if not on:
		return WorkerThreadPool.add_task(action, high_priority, description)
	return WorkerThreadPool.add_task(func() -> void: _timed(site, action), high_priority, description)


## WorkerThreadPool.add_group_task, each element timed under [param site]. Returns the pool's group id.
static func add_group_task(site: String, action: Callable, elements: int, tasks_needed: int = -1,
		high_priority: bool = false, description: String = "") -> int:
	if not on:
		return WorkerThreadPool.add_group_task(action, elements, tasks_needed, high_priority, description)
	return WorkerThreadPool.add_group_task(func(i: int) -> void: _timed(site, action, [i]),
			elements, tasks_needed, high_priority, description)


## WorkerThreadPool.wait_for_task_completion, the main thread's wait put to [param site] (the caller's file):
## a task joined before it is done holds the frame -- and so does a pool kept full by long tasks, which the
## physics step's own jobs (Jolt) then queue behind. Returns its Error.
static func wait(task_id: int, site: String = "") -> Error:
	if not on or OS.get_thread_caller_id() != OS.get_main_thread_id():
		return WorkerThreadPool.wait_for_task_completion(task_id)
	var start: int = Time.get_ticks_usec()
	var err := WorkerThreadPool.wait_for_task_completion(task_id)
	_add_wait(site, Time.get_ticks_usec() - start)
	return err


## WorkerThreadPool.wait_for_group_task_completion, timed as [method wait].
static func wait_group(group_id: int, site: String = "") -> void:
	if not on or OS.get_thread_caller_id() != OS.get_main_thread_id():
		WorkerThreadPool.wait_for_group_task_completion(group_id)
		return
	var start: int = Time.get_ticks_usec()
	WorkerThreadPool.wait_for_group_task_completion(group_id)
	_add_wait(site, Time.get_ticks_usec() - start)


## [param action] called on the main thread at its next message-queue flush (call_deferred), its time put to
## [param site]: how a task hands its result over. Deferred from a worker while the main thread flushes, it runs
## in that very flush -- after the physics step's, inside ClientPerf's `pengine` (2026-11-28).
static func deferred(site: String, action: Callable) -> void:
	_run_deferred.call_deferred(site, action)


static func _run_deferred(site: String, action: Callable) -> void:
	if not on:
		action.call()
		return
	var start: int = Time.get_ticks_usec()
	action.call()
	var spent: int = Time.get_ticks_usec() - start
	if spent >= 500:
		_waits["defer:" + site] = int(_waits.get("defer:" + site, 0)) + spent


## site -> usec the main thread waited on its tasks since take_waits (only waits of 0.5 ms or more); the
## deferred hand-overs (deferred) as "defer:<site>".
static var _waits: Dictionary = {}


static func _add_wait(site: String, usec: int) -> void:
	if usec >= 500:
		_waits[site] = int(_waits.get(site, 0)) + usec


## The main thread's waits since the last call, emptied (ClientPerf's `wait:<site>` scopes, per frame).
static func take_waits() -> Dictionary:
	var out := _waits
	_waits = {}
	return out


## How many of the game's tasks are running now.
static func running() -> int:
	_mutex.lock()
	var n: int = _running.size()
	_mutex.unlock()
	return n


static func _timed(site: String, action: Callable, args: Array = []) -> void:
	var start: int = Time.get_ticks_usec()
	_mutex.lock()
	_next_token += 1
	var token: int = _next_token
	_running[token] = [site, start]
	_mutex.unlock()
	action.callv(args)
	var end: int = Time.get_ticks_usec()
	_mutex.lock()
	_running.erase(token)
	_busy[site] = int(_busy.get(site, 0)) + end - maxi(start, _window_start)
	_done[site] = int(_done.get(site, 0)) + 1
	_mutex.unlock()


## Closes the window at [param now_usec] (Time.get_ticks_usec) and opens the next one. Returns
## site -> [usec held in the window, tasks finished in it, tasks running at its end, oldest running (s)].
static func take_window(now_usec: int) -> Dictionary:
	var out: Dictionary = {}
	_mutex.lock()
	for site: String in _busy:
		out[site] = [int(_busy[site]), int(_done.get(site, 0)), 0, 0.0]
	for token: int in _running:
		var entry: Array = _running[token]
		var site: String = entry[0]
		var start: int = entry[1]
		var row: Array = out.get(site, [0, 0, 0, 0.0])
		row[0] = int(row[0]) + now_usec - maxi(start, _window_start)
		row[2] = int(row[2]) + 1
		row[3] = maxf(float(row[3]), float(now_usec - start) / 1_000_000.0)
		out[site] = row
	_busy.clear()
	_done.clear()
	_window_start = now_usec
	_mutex.unlock()
	return out


## "site=busy%(done/running, oldest)" from the busiest, for a [param window_s] seconds window, where busy%
## is a share of ONE core (400 % = four workers held the whole window). Sites under [param min_pct] dropped.
static func line(rows: Dictionary, window_s: float, min_pct: float = 1.0) -> String:
	var pct: Dictionary = {}
	var total: float = 0.0
	for site: String in rows:
		pct[site] = float((rows[site] as Array)[0]) / 10_000.0 / maxf(window_s, 0.001)
		total += float(pct[site])
	var names: Array = pct.keys().filter(func(k: String) -> bool: return float(pct[k]) >= min_pct)
	names.sort_custom(func(a: String, b: String) -> bool: return float(pct[a]) > float(pct[b]))
	var parts: PackedStringArray = []
	for site: String in names:
		var row: Array = rows[site]
		var running: String = ""
		if int(row[2]) > 0:
			running = " run=%d oldest=%.1fs" % [int(row[2]), float(row[3])]
		parts.append("%s=%.0f%%(done=%d%s)" % [site, float(pct[site]), int(row[1]), running])
	return "busy=%.0f%% | %s" % [total, " ".join(parts) if not parts.is_empty() else "none"]
