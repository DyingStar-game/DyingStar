class_name CaveAmbience
extends AudioStreamPlayer

## CLIENT, own player only: the air of a cave, a low loop that rises as the player goes in and dies away as
## they come out. PlaceWatcher tells how far inside they are (hear), every time it looks.
##
## Not positional: a cave is all around. The level follows the distance to the nearest way out -- nothing at
## the mouth, full FULL_DEPTH_M inside -- and moves slowly (FADE_S), so a step across the porch is no switch.

const STREAM: AudioStream = preload("res://assets/_universe/audio/sfx/environment/cave-ambience.ogg")
## How far (m) from the nearest opening the ambience is at its full level.
const FULL_DEPTH_M := 30.0
## Its full level (dB): a presence under the footsteps, never a music.
const FULL_DB := -24.0
## Seconds from silence to full, and back.
const FADE_S := 4.0
## Under this share of the full level it is stopped.
const SILENT := 0.001

## Where the level is going, and where it is, 0..1.
var _goal: float = 0.0
var _level: float = 0.0


## The distance (m) from [param point] to the nearest of [param openings] (their origins, same frame): how
## deep a player stands in a cave. -1 with no opening. Pure.
static func depth_from(openings: PackedVector3Array, point: Vector3) -> float:
	var nearest: float = -1.0
	for opening: Vector3 in openings:
		var d: float = opening.distance_to(point)
		if nearest < 0.0 or d < nearest:
			nearest = d
	return nearest


## The share of the full level heard [param depth_m] inside (negative: outside): none at the mouth, all of
## it from FULL_DEPTH_M, eased between. Pure.
static func level_at(depth_m: float) -> float:
	return smoothstep(0.0, FULL_DEPTH_M, depth_m) if depth_m > 0.0 else 0.0


func _init() -> void:
	stream = STREAM
	bus = Sfx3D.SFX_BUS
	volume_db = -80.0
	set_process(false)


## The player stands [param depth_m] inside a cave (negative: in none).
func hear(depth_m: float) -> void:
	_goal = level_at(depth_m)
	if not is_equal_approx(_goal, _level):
		set_process(true)


func _process(delta: float) -> void:
	_level = move_toward(_level, _goal, delta / FADE_S)
	if _level <= SILENT:
		stop()
	else:
		volume_db = FULL_DB + linear_to_db(_level)
		if not playing:
			play(randf() * stream.get_length())
	if is_equal_approx(_level, _goal):
		set_process(false)
