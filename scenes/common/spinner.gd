class_name Spinner
extends Node3D
## Turns this node for ever about one of its local axes: a wind turbine's rotor, a fan, a radar dish.
##
## Pure decoration: the dedicated server leaves it still, and nothing is replicated. Two spinners never
## turn in step: each draws its phase and its speed (within [member speed_spread]) from where it
## stands on its planet, so a field of them looks alive. Every client sees the same field: the seed is
## the planet-local position (the planet's orbit moves the global one), and the angle starts from the
## clock the clients share with the server (Globals.reference_time), so a late joiner finds each rotor
## where the others see it — within the clock's sync and the frames' rounding. Not a tool script: the
## editor shows (and saves) the authored pose.

## Turns per minute at the average speed.
@export_range(0.0, 600.0, 0.1) var rpm: float = 15.0
## The axis it turns about, in its own frame.
@export var axis: Vector3 = Vector3.FORWARD
## How far one spinner's speed strays from [member rpm], as a fraction of it (0.2 = ±20 %).
@export_range(0.0, 1.0, 0.01) var speed_spread: float = 0.2

var _speed := 0.0  # rad/s
var _phase := 0.0  # rad, the angle at 0 s of the shared clock


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)
		return
	var dice := RandomNumberGenerator.new()
	dice.seed = hash(_stand_position().snappedf(0.1))
	_speed = rpm / 60.0 * TAU * (1.0 + dice.randf_range(-speed_spread, speed_spread))
	_phase = dice.randf() * TAU
	rotate_object_local(axis.normalized(), angle_at(Globals.reference_time()))


func _process(delta: float) -> void:
	rotate_object_local(axis.normalized(), _speed * delta)


## The angle (rad) this spinner has turned from its authored pose at [param seconds] of the shared
## clock: a pure function of time, so two machines reading the same clock agree.
func angle_at(seconds: float) -> float:
	return fposmod(_phase + _speed * seconds, TAU)


## Where it stands in its planet's frame — the same on every client whatever the orbit has moved the
## planet to; its global position away from any planet (a test scene, deep space).
func _stand_position() -> Vector3:
	var planet := SurfaceProbe.planet_of(self)
	if planet == null:
		return global_position
	return planet.global_transform.affine_inverse() * global_position
