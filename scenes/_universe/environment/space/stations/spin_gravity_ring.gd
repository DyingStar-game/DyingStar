class_name SpinGravityRing
extends Node3D
## A station ring turning the way a real one must to give its floor gravity.
##
## Nothing is tuned: the rate comes from the physics. Standing on the inside of a rim of radius r turning at
## ω, the floor pushes you toward the axis with a = ω²·r — that push IS the gravity — so for g it takes
## ω = √(g / r). The test station's rims (98.9 m) turn once every 20 s, 3 rpm: slow to the eye for a wheel that
## size, and the real figure.
##
## The angle is a pure function of the shared clock (Globals.sim_time), like every orbit: the server and every
## client turn the same ring to the same angle without a byte on the wire, its collision included.
##
## Put it on a node OUTSIDE the station's own CSG tree (a CSGCombiner3D of its own, say): a CSG child that
## moves makes its root rebuild the whole combined mesh every frame, where a root that moves just moves.

const STANDARD_G := 9.80665

## The gravity felt on the rim's floor, in g.
@export var gravity_g: float = 1.0
## Radius of the floor, in metres — where people would stand, the rim's outer edge. 0 reads it off the widest
## CSGCylinder3D inside this ring, so the figure is not written twice.
@export var floor_radius_m: float = 0.0
## The axis it turns about, in this node's own frame (a CSGCylinder3D's axis is its local Y).
@export var axis: Vector3 = Vector3.UP

var _rest: Basis = Basis.IDENTITY
## angular_rate(), worked out once: the rim does not change size, and reading it walks the ring's subtree.
var _rate: float = -1.0


func _ready() -> void:
	_rest = basis
	if Engine.is_editor_hint():
		set_process(false)


func _process(_delta: float) -> void:
	basis = _rest * Basis(axis.normalized(), angle_at(Globals.sim_time()))


## The ring's turn at time [param t], radians in [0, TAU).
func angle_at(t: float) -> float:
	if _rate < 0.0:
		_rate = angular_rate()
	return fposmod(t * _rate, TAU)


## ω = √(g / r), rad/s. 0 when no floor radius can be found.
func angular_rate() -> float:
	var r: float = floor_radius()
	if r <= 0.0:
		return 0.0
	return sqrt(gravity_g * STANDARD_G / r)


## The floor's radius: floor_radius_m when set, else the widest CSGCylinder3D in this ring.
func floor_radius() -> float:
	if floor_radius_m > 0.0:
		return floor_radius_m
	var widest: float = 0.0
	for node: Node in find_children("*", "CSGCylinder3D", true, false):
		var cylinder := node as CSGCylinder3D
		if cylinder.operation != CSGShape3D.OPERATION_SUBTRACTION:
			widest = maxf(widest, cylinder.radius)
	return widest
