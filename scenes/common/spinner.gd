class_name Spinner
extends Node3D
## Turns this node for ever about one of its local axes: a wind turbine's rotor, a fan, a radar dish.
##
## Pure decoration: the dedicated server leaves it still, and nothing is replicated. Two spinners never
## turn in step: each draws its phase and its speed (within [member speed_spread]) from where it
## stands, so a field of them looks alive, and every client sees the same field. Not a tool script:
## the editor shows (and saves) the authored pose.

## Turns per minute at the average speed.
@export_range(0.0, 600.0, 0.1) var rpm: float = 15.0
## The axis it turns about, in its own frame.
@export var axis: Vector3 = Vector3.FORWARD
## How far one spinner's speed strays from [member rpm], as a fraction of it (0.2 = ±20 %).
@export_range(0.0, 1.0, 0.01) var speed_spread: float = 0.2

var _speed := 0.0  # rad/s


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)
		return
	var dice := RandomNumberGenerator.new()
	dice.seed = hash(global_position.snappedf(0.1))
	_speed = rpm / 60.0 * TAU * (1.0 + dice.randf_range(-speed_spread, speed_spread))
	rotate_object_local(axis.normalized(), dice.randf() * TAU)


func _process(delta: float) -> void:
	rotate_object_local(axis.normalized(), _speed * delta)
