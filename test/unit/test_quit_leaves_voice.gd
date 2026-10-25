extends GutTest
## Quitting leaves the voice room first and waits for it (GameOrchestrator.voice_rooms_left), but never
## longer than its timeout: a room that never answers must not hold the game open. And the autoload that
## quits never loads livekit.gd, which the dedicated server cannot compile.


func after_each() -> void:
	GameOrchestrator.voice_rooms_leaving.clear()


func test_nothing_to_leave_quits_at_once() -> void:
	var start: int = Time.get_ticks_msec()
	await GameOrchestrator.voice_rooms_left(2.0)
	assert_lt(Time.get_ticks_msec() - start, 100, "no room: no wait")


func test_a_room_that_never_answers_waits_the_timeout_only() -> void:
	GameOrchestrator.voice_rooms_leaving.append(RefCounted.new())
	var start: int = Time.get_ticks_msec()
	await GameOrchestrator.voice_rooms_left(0.2)
	var waited: int = Time.get_ticks_msec() - start
	assert_gte(waited, 200, "waits for it")
	assert_lt(waited, 1000, "but not past the timeout")


func test_the_wait_ends_as_the_room_leaves() -> void:
	var room := RefCounted.new()
	GameOrchestrator.voice_rooms_leaving.append(room)
	get_tree().create_timer(0.1).timeout.connect(func() -> void: GameOrchestrator.voice_rooms_leaving.erase(room))
	var start: int = Time.get_ticks_msec()
	await GameOrchestrator.voice_rooms_left(2.0)
	assert_lt(Time.get_ticks_msec() - start, 1000, "left: the game quits")


func test_the_autoload_that_quits_never_loads_the_voice_script() -> void:
	# The dedicated server's export leaves the LiveKit extension out: livekit.gd does not compile there,
	# and an autoload loading it would stop the server.
	var source: String = FileAccess.get_file_as_string("res://scenes/globals/game_orchestrator.gd")
	assert_false(source.contains("audio/livekit.gd"), "GameOrchestrator must not load livekit.gd")


func test_the_voice_library_pin_is_usable_and_harmless() -> void:
	# The pin that keeps LiveKit's library loaded at exit must be in the assembly, and pinning a library
	# that is not loaded (or any library off Windows) only answers false.
	var script: Script = NativeScript.load_usable(GameOrchestrator.NATIVE_LIBRARY_PIN_SCRIPT, ["Pin"])
	assert_not_null(script, "NativeLibraryPin.cs is built into the assembly")
	if script != null:
		assert_false(script.new().Pin("no_such_library_dyingstar.dll"), "nothing loaded under that name")
