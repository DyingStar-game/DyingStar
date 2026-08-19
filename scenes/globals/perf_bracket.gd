class_name PerfBracket
extends Node

## TEMPORARY diagnostic (TPS drops, étape 0c). Two instances of this node bracket the whole physics
## tick: one at the lowest process_physics_priority (runs before every other _physics_process in the
## tree) stamps a start time, one at the highest stamps the end. The span between them therefore
## covers EVERY script callback in the tick, instrumented or not.
##
## Why it matters: the per-callback buckets in PropNet only cover the callbacks we thought to
## instrument, so the "jolt+rest" leftover in the report was a catch-all — it silently contained any
## _physics_process we forgot (vehicles, containers, player children). With this span,
## TIME_PHYSICS_PROCESS - span is the engine's own work alone (Jolt step + main-thread sync), which
## is the number that decides whether GDScript optimisation can help at all.
##
## Remove together with the PropNet.PROF block once the drop is diagnosed.

const PRIORITY_FIRST: int = -100000
const PRIORITY_LAST: int = 100000

@export var is_end: bool = false


static func attach_to(host: Node) -> void:
	var first := PerfBracket.new()
	first.name = "PerfBracketStart"
	first.process_physics_priority = PRIORITY_FIRST
	host.add_child(first)
	var last := PerfBracket.new()
	last.name = "PerfBracketEnd"
	last.is_end = true
	last.process_physics_priority = PRIORITY_LAST
	host.add_child(last)


func _physics_process(_delta: float) -> void:
	if not PropNet.PROF:
		return
	if is_end:
		PropNet.prof_span_usec += Time.get_ticks_usec() - PropNet.prof_span_t0
	else:
		PropNet.prof_span_t0 = Time.get_ticks_usec()
