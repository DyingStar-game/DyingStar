extends Node
## CLIENT: the physics catch-up held low while the player arrives in the world.
##
## A frame of 300 ms makes the engine run up to max_physics_steps_per_frame (8) physics steps in a row to
## catch the simulated time up. At arrival a step costs 3 to 40 ms instead of 0.5 (the world's bodies and
## scenes arriving), and the frames are long because the buildings are being spawned: the catch-up made them
## longer still — 17.7 s of the 44 s of a village arrival were physics (2026-11-28, real session). While
## arriving, at most ARRIVAL_STEPS steps a frame: the simulation falls behind the clock during the long
## frames (one's own character moves slower in them; vehicles and everything else are the server's), and
## the frames are shorter. Released for good once the loading splash is gone and the frames have stayed
## under SETTLED_FRAME_MS for SETTLED_S, or after MAX_S whatever happens. Never during play.
## client.ini [debug] arrival_physics_steps: the cap (0 = none, the engine's own value throughout).
## Made by GameOrchestrator when the game scene is entered (loaded by path: an autoload names no gameplay
## class).

## Physics steps a frame at most while arriving (client.ini arrival_physics_steps overrides it).
const ARRIVAL_STEPS := 2
## A frame this long or shorter (ms, wall clock) counts as settled: no hitch. Every frame under 40 ms never
## came on a machine at 40-45 fps with its spikes, and the cap stayed the whole session (2026-11-28).
const SETTLED_FRAME_MS := 100.0
## How long the frames must stay settled, the splash gone, before the cap is released (s).
const SETTLED_S := 5.0
## The cap is released after this long whatever the frames do (s).
const MAX_S := 180.0

var _normal := 8
var _steps := 0
var _started_usec := 0
var _last_usec := 0
var _calm_s := 0.0
var _released := false


func _ready() -> void:
	_steps = ClientConfig.get_int("arrival_physics_steps", ARRIVAL_STEPS)
	_normal = Engine.max_physics_steps_per_frame
	if _steps <= 0 or _steps >= _normal:
		_released = true
		queue_free()
		return
	Engine.max_physics_steps_per_frame = _steps
	_started_usec = Time.get_ticks_usec()
	_last_usec = _started_usec
	print("[Arrival] physics catch-up held at %d steps a frame (instead of %d) until the frames settle"
			% [_steps, _normal])


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last_usec) / 1000.0
	_last_usec = now
	var splash_up := get_tree().root.get_node_or_null("Loading") != null
	if step(frame_ms, (now - _started_usec) / 1000000.0, splash_up):
		queue_free()


## One frame of [param frame_ms] (wall clock), [param elapsed_s] after the cap was set, the loading splash
## still up or not: true once the cap is released (the engine's own value back).
func step(frame_ms: float, elapsed_s: float, splash_up: bool) -> bool:
	if _released:
		return true
	_calm_s = _calm_s + frame_ms / 1000.0 if frame_ms <= SETTLED_FRAME_MS and not splash_up else 0.0
	if _calm_s < SETTLED_S and elapsed_s < MAX_S:
		return false
	release("settled" if _calm_s >= SETTLED_S else "%.0f s passed" % MAX_S, elapsed_s)
	return true


## Gives the engine its own catch-up back ([param why], [param elapsed_s] after the cap was set).
func release(why: String = "freed", elapsed_s: float = -1.0) -> void:
	if _released:
		return
	_released = true
	Engine.max_physics_steps_per_frame = _normal
	print("[Arrival] physics catch-up back to %d steps a frame (%s%s)" % [_normal, why,
			", after %.1f s" % elapsed_s if elapsed_s >= 0.0 else ""])


func _exit_tree() -> void:
	release()
