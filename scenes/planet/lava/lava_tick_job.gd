extends RefCounted
## Worker payload owns only a pure solver and immutable integer commands.
## No scene tree, GPU calls, profile evaluation or wall time enters the state.
var solver: RefCounted
var next_tick := 0
var commands := PackedInt64Array()
var ok := false
var cpu_usec := 0

func run() -> void:
	var started := Time.get_ticks_usec()
	ok = solver.advance_tick(next_tick, commands)
	cpu_usec = Time.get_ticks_usec() - started
