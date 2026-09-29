class_name StageDriver
extends Node
## Drives a vehicle of the menu stage around a big loop: position and heading set every frame on the
## real ground (the client has no terrain collision, so the vehicle stays frozen and is carried).
## A loop around a centre point, radius and speed from StageLayout.DRIVERS.

var _vehicle : Node3D
var _loop : SurfaceFrame
var _radius : float
var _speed_ms : float
var _angle : float
var _clockwise : bool


## `loop` is anchored at the loop's centre; `start_deg` is where on the loop the vehicle starts.
func _init(vehicle: Node3D, loop: SurfaceFrame, radius: float, speed_kmh: float, start_deg: float,
		clockwise: bool) -> void:
	name = "StageDriver"
	_vehicle = vehicle
	_loop = loop
	_radius = radius
	_speed_ms = speed_kmh / 3.6
	_angle = start_deg
	_clockwise = clockwise


func _process(delta: float) -> void:
	if not is_instance_valid(_vehicle):
		return
	_angle = fposmod(_angle + rad_to_deg(_speed_ms / _radius * delta) * (1.0 if _clockwise else -1.0), 360.0)
	place()


## On the loop at the current angle, facing along it.
func place() -> void:
	var dir : Vector3 = _loop.dir_at(_radius, _angle)
	# Clockwise seen from above, the way on is 90° further round; the other way, 90° back.
	var heading : float = _angle + (90.0 if _clockwise else -90.0)
	var basis : Basis = _loop.basis_at(dir, heading)
	# A vehicle's nose is its -Z, which is what basis_at faces: nothing to turn.
	_vehicle.transform = Transform3D(basis, _loop.point(_radius, _angle))
