class_name StageDriver
extends Node3D
## Drives the vehicle placed as its child around a big loop centred on this node, on the real
## ground: position and heading are set every frame (the client has no terrain collision, so the
## vehicle stays frozen and is carried). Placed in menu_stage_world.tscn: move this node to move the
## loop's centre, set the loop in the inspector.

@export var radius : float = 140.0
@export var speed_kmh : float = 30.0
## Where on the loop the vehicle starts, in degrees from the local north.
@export var start_deg : float = 0.0
@export var clockwise : bool = true

var _vehicle : Node3D = null
var _loop : SurfaceFrame = null
var _angle : float = 0.0


## Frozen on entering the tree, before the first physics step (no terrain collision on a client).
func _ready() -> void:
	for child in get_children():
		if child is Node3D:
			_vehicle = child
			break
	if _vehicle == null:
		push_warning("StageDriver %s: no vehicle under it" % name)
		return
	ReplicaDress.prepare(_vehicle, true)
	if _vehicle.has_method("set_headlights"):
		_vehicle.set_headlights(true)
	# The vehicle is placed in the PLANET's frame: keep this node's own transform out of its way.
	_vehicle.top_level = true


## Called by the stage once the planet's ground is known (`ground`: direction -> surface distance).
func start(planet_radius: float, ground: Callable) -> void:
	if _vehicle == null:
		return
	_loop = SurfaceFrame.new(position, planet_radius, ground)
	_angle = start_deg
	place()


func _process(delta: float) -> void:
	if _loop == null or not is_instance_valid(_vehicle):
		return
	_angle = fposmod(_angle + rad_to_deg(speed_kmh / 3.6 / radius * delta) * (1.0 if clockwise else -1.0), 360.0)
	place()


## On the loop at the current angle, facing along it (a vehicle's nose is its -Z).
func place() -> void:
	var dir : Vector3 = _loop.dir_at(radius, _angle)
	var heading : float = _angle + (90.0 if clockwise else -90.0)
	var planet : Node3D = Planet.of(self)
	var local := Transform3D(_loop.basis_at(dir, heading), _loop.point(radius, _angle))
	_vehicle.global_transform = planet.global_transform * local
