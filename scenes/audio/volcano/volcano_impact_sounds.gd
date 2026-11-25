extends Node3D
## CLIENT: the sound of the volcano's stones striking the ground near the listener. Driven by the stone
## field's `impacted` signal (only rocks within its promotion radius land as rocks), so it costs nothing
## between impacts. A few voices at most (impact_voices); a take per impact drawn from the rock's own
## identity, so the same stone sounds the same for everyone. Level and low-pass with distance come from
## Godot's 3D attenuation (1/d past impact_full_m, its distance filter).
##
## No class_name: VolcanoSound preloads it by path.

const SoundSet := preload("res://scenes/audio/volcano/volcano_sound_set.gd")

var sounds: SoundSet
## The stone field's frame: contacts arrive in it.
var frame: Node3D
var _playing: Array[AudioStreamPlayer3D] = []


## Small (0), medium (1) or large (2) for a stone of [param radius] m. Pure.
static func size_class(radius: float, small_max_m: float, large_min_m: float) -> int:
	if radius <= small_max_m:
		return 0
	return 2 if radius >= large_min_m else 1


## Level (dB) an impact adds to its class level for its [param speed] (m/s) into the ground: 0 from
## [param full_speed], quieter as the square root of the speed ratio below. Pure.
static func speed_db(speed: float, full_speed: float) -> float:
	return linear_to_db(sqrt(clampf(speed / maxf(full_speed, 0.01), 0.001, 1.0)))


## The take of an impact among [param takes], from the rock's birth time and size: the same on every
## client. Pure.
static func pick(takes: Array, born: float, radius: float, rebound: bool) -> AudioStream:
	if takes.is_empty():
		return null
	var key: int = int(born * 20.0) * 31 + int(radius * 1000.0) + (7 if rebound else 0)
	var at: int = mini(int(VolcanoRandom.hash01(key, 831) * takes.size()), takes.size() - 1)
	return takes[at] as AudioStream


func on_impact(contact: Vector3, radius: float, speed: float, rebound: bool, born: float) -> void:
	if sounds == null or not is_instance_valid(frame) or (rebound and speed < sounds.impact_min_speed):
		return
	var at: Vector3 = frame.to_global(contact)
	var viewport := get_viewport()
	var cam: Camera3D = viewport.get_camera_3d() if viewport != null else null
	if cam == null or cam.global_position.distance_to(at) >= sounds.impact_range_m:
		return
	_playing = _playing.filter(func(p: AudioStreamPlayer3D) -> bool: return is_instance_valid(p))
	if _playing.size() >= sounds.impact_voices:
		return
	var kind := size_class(radius, sounds.impact_small_max_m, sounds.impact_large_min_m)
	var takes: Array = [sounds.impacts_small, sounds.impacts_medium, sounds.impacts_large][kind]
	var take := pick(takes, born, radius, rebound)
	if take == null:
		return
	var db: float = [sounds.impact_small_db, sounds.impact_medium_db, sounds.impact_large_db][kind]
	db += speed_db(speed, sounds.impact_full_speed)
	var player := AudioStreamPlayer3D.new()
	Sfx3D.configure(player, take, db, sounds.impact_full_m, sounds.impact_range_m, Sfx3D.Attenuation.REALISTIC)
	player.attenuation_filter_cutoff_hz = sounds.impact_far_hz
	player.finished.connect(player.queue_free)
	add_child(player)
	player.global_position = at
	player.play()
	_playing.append(player)
