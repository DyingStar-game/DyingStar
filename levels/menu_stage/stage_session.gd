class_name StageSession
extends RefCounted
## The global state the menu stage borrows while it lives, handed back when it goes: the universe
## root the sky looks its star up in, a frozen clock (the stage picks its own hour), the mouse.
## A snapshot is taken, so whatever the game had set is what it gets back — the stage must never
## leak a frozen sun or a shifted clock into the session that follows.

var _saved : Dictionary = {}


func begin(root: Node) -> void:
	_saved = {
		"universe_scene": NetworkOrchestrator.universe_scene,
		"time_scale": Globals.time_scale,
		"debug_time_offset": Globals.debug_time_offset,
		"mouse_mode": Input.mouse_mode,
	}
	NetworkOrchestrator.universe_scene = root
	# time_scale 0: sim_time() is then exactly debug_time_offset, which is how StageClock sets the hour.
	Globals.time_scale = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func end() -> void:
	if _saved.is_empty():
		return
	# Back from a session, the universe saved by begin() has been freed since: hand back none rather
	# than fail here and leave the frozen clock (time_scale 0) and the mouse to the next session.
	var universe = _saved["universe_scene"]
	NetworkOrchestrator.universe_scene = universe if is_instance_valid(universe) else null
	Globals.time_scale = _saved["time_scale"]
	Globals.debug_time_offset = _saved["debug_time_offset"]
	Input.mouse_mode = _saved["mouse_mode"]
	_saved = {}
