class_name SpaceshipSound
extends Node3D
## The ship's thrusters as a listener hears them, client side (the server is silent: Vehicle._sfx_muted): the
## main thrust loop, louder and higher with the thrust asked (Vehicle.get_power_share, replicated as "power"),
## and a short puff of the manoeuvring thrusters each time a translation starts or the hull starts to turn.
## The engine's own start, stop and idle are Vehicle's (sfx_engine_*), set on the ship's scene.

## The main thrust loop (a looping sample; made looping if it is not).
@export var thrust_loop: AudioStream
## Loudness (dB) of the thrust loop at full thrust; it fades to silence with no thrust.
@export_range(-40.0, 12.0, 0.5) var thrust_db: float = 0.0
## Playback speed of the thrust loop at full thrust (1 = as recorded): the roar rises with the thrust.
@export_range(1.0, 2.0, 0.05) var thrust_pitch: float = 1.2
## How fast (per second) the loop follows the thrust: low = a heavy, lazy engine.
@export_range(0.5, 20.0, 0.5) var thrust_response: float = 4.0
## Reference distance (m) at which the thrusters have their nominal volume; past it, they fade.
@export_range(0.5, 200.0, 0.5) var thrust_falloff: float = 15.0
## Distance (m) past which the thrusters are no longer heard at all.
@export_range(1.0, 1000.0, 1.0) var thrust_distance: float = 150.0
## The manoeuvring thrusters' puffs, one picked at random each time.
@export var puffs: Array[AudioStream] = []
## Loudness (dB) of a puff.
@export_range(-40.0, 12.0, 0.5) var puff_db: float = -9.0
## A puff fires when the thrust share rises past this (0..1) from under PUFF_REARM of it.
@export_range(0.05, 1.0, 0.05) var puff_thrust_share: float = 0.3
## A puff fires when the hull's turn rate rises past this (degrees per second) from rest.
@export_range(1.0, 90.0, 1.0) var puff_turn_deg_s: float = 8.0
## Shortest time (s) between two puffs: a stick held at the edge of a threshold does not machine-gun.
@export_range(0.05, 2.0, 0.05) var puff_min_gap_s: float = 0.25

## Under this share of the trigger (thrust or turn), the puff is armed again.
const PUFF_REARM: float = 0.4
## The thrust loop's floor (dB) under which it is stopped instead of playing inaudibly.
const SILENT_DB: float = -60.0

var _ship: Vehicle = null
var _loop: AudioStreamPlayer3D = null
var _level: float = 0.0
var _thrust_armed: bool = true
var _turn_armed: bool = true
var _since_puff: float = INF
var _last_basis: Basis = Basis.IDENTITY
var _has_basis: bool = false


func _ready() -> void:
	_ship = get_parent() as Vehicle
	set_process(_ship != null)


func _process(delta: float) -> void:
	if _ship == null or _ship._sfx_muted():
		_stop_loop()
		return
	var on: bool = _ship.is_engine_on()
	var share: float = _ship.get_power_share() if on else 0.0
	_level = move_toward(_level, share, thrust_response * delta)
	_update_loop()
	_since_puff += delta
	var turn: float = _turn_rate_deg(delta)
	if not on:
		_thrust_armed = true
		_turn_armed = true
		return
	if puff_edge(share, puff_thrust_share, _thrust_armed):
		_puff()
	_thrust_armed = rearmed(share, puff_thrust_share, _thrust_armed)
	if puff_edge(turn, puff_turn_deg_s, _turn_armed):
		_puff()
	_turn_armed = rearmed(turn, puff_turn_deg_s, _turn_armed)


## Does a value crossing [param threshold] upward, while [param armed], fire a puff? Pure.
static func puff_edge(value: float, threshold: float, armed: bool) -> bool:
	return armed and value >= threshold


## Is the trigger armed after [param value]: disarmed once past [param threshold], armed again only under
## PUFF_REARM of it (a hysteresis, so a value hovering at the threshold fires once). Pure.
static func rearmed(value: float, threshold: float, armed: bool) -> bool:
	if value >= threshold:
		return false
	return armed or value < threshold * PUFF_REARM


## The thrust loop's loudness (dB) and playback speed at [param level] (0..1 of full thrust). Pure.
static func loop_mix(level: float, full_db: float, full_pitch: float) -> Vector2:
	var l: float = clampf(level, 0.0, 1.0)
	var db: float = full_db + linear_to_db(maxf(l, 0.001))
	return Vector2(maxf(db, SILENT_DB), lerpf(1.0, full_pitch, l))


## How fast (degrees per second) the hull turns, from its orientation one frame to the next: a replica's
## physics does not run, its transform is the server's, interpolated.
func _turn_rate_deg(delta: float) -> float:
	var b: Basis = _ship.global_basis.orthonormalized()
	if not _has_basis or delta <= 0.0:
		_last_basis = b
		_has_basis = true
		return 0.0
	var turned: float = (_last_basis.inverse() * b).get_rotation_quaternion().get_angle()
	_last_basis = b
	return rad_to_deg(turned) / delta


func _update_loop() -> void:
	if thrust_loop == null:
		return
	var mix: Vector2 = loop_mix(_level, thrust_db, thrust_pitch)
	if mix.x <= SILENT_DB:
		_stop_loop()
		return
	if _loop == null:
		_loop = AudioStreamPlayer3D.new()
		add_child(_loop)
		Sfx3D.configure(_loop, Sfx3D.as_looping(thrust_loop), thrust_db, thrust_falloff, thrust_distance,
				Sfx3D.Attenuation.REALISTIC)
	if not _loop.playing:
		_loop.play()
	_loop.volume_db = mix.x
	_loop.pitch_scale = mix.y


func _stop_loop() -> void:
	if _loop != null and _loop.playing:
		_loop.stop()


func _puff() -> void:
	if puffs.is_empty() or _since_puff < puff_min_gap_s:
		return
	_since_puff = 0.0
	Sfx3D.play(self, puffs[randi() % puffs.size()], puff_db, thrust_falloff * 0.5, thrust_distance * 0.5,
			Sfx3D.Attenuation.REALISTIC)
