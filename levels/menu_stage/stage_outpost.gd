class_name StageOutpost
extends Node3D
## The menu stage's set, as placed in menu_stage_world.tscn: a child of the planet (so its children's
## positions are planet-local), holding props, figures (Mannequin), driven trucks (StageDriver) and,
## under Stations, the viewpoints (StageStation). Everything here is moved in the editor.
##
## At run time it puts each piece back on the ground along the vertical, keeping where it was put
## and which way it faces: moved in the editor, nothing floats nor sinks. The ground under a far
## piece is only known once its terrain tiles have arrived, so the stage calls resnap() for a while.
## A piece that must stand above the ground (a stacked container) carries a `stage_lift` metadata.
## A vehicle stands on its wheels, not on its origin: it is lifted by its ground clearance.

## Put the pieces back on the ground at run time.
@export var snap_to_ground : bool = true
## The point the stage's clock and bearings are taken from: a marker where the stage was built, beside
## it under the planet (where a test teleporter cabin stood until the cabins became networked props).
@export var anchor_path : NodePath = ^"../StageAnchor"

var _ground : Callable
var _radius : float = 0.0


func anchor_local() -> Vector3:
	var anchor : Node3D = get_node_or_null(anchor_path)
	return anchor.position if anchor != null else Vector3.ZERO


## The viewpoints, in scene order.
func stations() -> Array[StageStation]:
	var out : Array[StageStation] = []
	for node in find_children("*", "StageStation", true, false):
		out.append(node)
	return out


func station(key: StringName) -> StageStation:
	for candidate in stations():
		if candidate.key == key:
			return candidate
	return null


## Dressed on entering the tree, before the first physics step: the client has no terrain
## collision, and a live body would start falling through the planet before the ground is known.
func _ready() -> void:
	for piece in _pieces():
		if not (piece is StageDriver or piece is Mannequin):
			ReplicaDress.prepare(piece, true)
		# A parked vehicle with its lights on (metadata: the lights are no exported property).
		if piece.get_meta(&"stage_headlights", false) and piece.has_method("set_headlights"):
			piece.set_headlights(true)


## The ground is known: start the trucks, snap everything down once.
func start(planet_radius: float, ground: Callable) -> void:
	_radius = planet_radius
	_ground = ground
	for piece in _pieces():
		if piece is StageDriver:
			(piece as StageDriver).start(planet_radius, ground)
	resnap()


## Back on the ground along the vertical; returns the largest move.
func resnap() -> float:
	if not snap_to_ground or not _ground.is_valid():
		return 0.0
	var largest : float = 0.0
	for piece in _pieces():
		var dir : Vector3 = piece.position.normalized()
		var lift : float = float(piece.get_meta(&"stage_lift", 0.0)) + ground_clearance(piece)
		var target : Vector3 = dir * (float(_ground.call(dir)) + lift)
		largest = maxf(largest, target.distance_to(piece.position))
		piece.position = target
	return largest


## How far a vehicle's origin stands above the ground on its wheels at rest: each wheel hangs its
## rest length below its mount and touches the ground one radius below that. 0 for anything else.
static func ground_clearance(node: Node) -> float:
	if not node is VehicleBody3D:
		return 0.0
	var clearance : float = 0.0
	for child in node.get_children():
		if child is VehicleWheel3D:
			var wheel := child as VehicleWheel3D
			clearance = maxf(clearance, wheel.wheel_rest_length + wheel.wheel_radius - wheel.position.y)
	return clearance


## What stands on the ground: every direct child but the viewpoints' folder.
func _pieces() -> Array[Node3D]:
	var out : Array[Node3D] = []
	for child in get_children():
		if child is Node3D and child.name != &"Stations":
			out.append(child)
	return out
