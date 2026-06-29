extends Node

## Baseline measurement tool for the collision-layers work (dev only).
## Prints the 3D physics cost every INTERVAL seconds: collision pairs, awake bodies, physics step
## time — tagged SERVER / CLIENT so both sides can be compared BEFORE/AFTER each rollout phase.
## The heavy authority is the SERVER (full world simulation); the client is lighter (no terrain
## collision client-side, most bodies server-driven) → expect a clear server win, a smaller client
## one. Safe to remove once the work is done.

const INTERVAL := 2.0

var _accum: float = 0.0
var _tag: String = "CLIENT"

func _ready() -> void:
	_tag = "SERVER" if OS.has_feature("dedicated_server") else "CLIENT"

func _physics_process(delta: float) -> void:
	_accum += delta
	if _accum < INTERVAL:
		return
	_accum = 0.0
	# NOTE: PHYSICS_3D_COLLISION_PAIRS / ACTIVE_OBJECTS are NOT fed by Jolt (always 0), so we look at
	# where the frame time actually goes: main-thread process vs physics step, + node/object counts.
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var proc_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	prints("[PERF-%s] fps=%.0f  process=%.1fms  physics=%.2fms  nodes=%d  objects=%d" % [
		_tag, fps, proc_ms, phys_ms, nodes, objects])
