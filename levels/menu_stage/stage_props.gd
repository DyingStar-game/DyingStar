class_name StageProps
extends Node3D
## The stage's props and figures, placed from StageLayout on the planet's real surface.
##
## A child of the planet with an identity transform, so its children's positions ARE planet-local.
## The ground under a far prop is only known once its terrain tiles have arrived, which can be after
## the first placement: resnap() puts everything back on the ground, and the stage calls it for a
## while after loading.

var _frame : SurfaceFrame
var _line_deg : float = 0.0
## [node, entry] for everything placed, props and mannequins alike.
var _placed : Array = []


func _init() -> void:
	name = "StageProps"


func populate(frame: SurfaceFrame, line_deg: float) -> void:
	_frame = frame
	_line_deg = line_deg
	for entry in StageLayout.PROPS:
		var scene : PackedScene = load(entry["scene"])
		if scene == null:
			push_warning("StageProps: cannot load %s" % entry["scene"])
			continue
		var node : Node3D = scene.instantiate()
		# Before entering the tree, so the truck lights up silently (no switch sound on the menu).
		if entry.get("headlights", false) and node.has_method("set_headlights"):
			node.set_headlights(true)
		ReplicaDress.prepare(node, true)
		_add(node, entry)
	for entry in StageLayout.MANNEQUINS:
		_add(Mannequin.new(entry["clip"], float(entry.get("walk_radius", 0.0))), entry)
	for entry in StageLayout.DRIVERS:
		_add_driver(entry)


## Put everything back on the ground; returns the largest move, so the caller knows when it settled.
func resnap() -> float:
	var largest : float = 0.0
	for pair in _placed:
		var node : Node3D = pair[0]
		if not is_instance_valid(node):
			continue
		var before : Vector3 = node.position
		_place(node, pair[1])
		largest = maxf(largest, before.distance_to(node.position))
	return largest


## A truck on its loop. The loop's own frame is anchored at its centre, on the real ground.
func _add_driver(entry: Dictionary) -> void:
	var vehicle : Node3D = (load(entry["scene"]) as PackedScene).instantiate()
	if vehicle.has_method("set_headlights"):
		vehicle.set_headlights(true)
	ReplicaDress.prepare(vehicle, true)
	var centre : Vector3 = _frame.point(float(entry["centre"][0]), _line_deg + float(entry["centre"][1]))
	var loop := SurfaceFrame.new(centre, _frame.radius, _frame.ground)
	var driver := StageDriver.new(vehicle, loop, float(entry["radius"]), float(entry["speed_kmh"]),
		_line_deg + float(entry["start"]), bool(entry["clockwise"]))
	driver.place()
	add_child(vehicle)
	add_child(driver)


func _add(node: Node3D, entry: Dictionary) -> void:
	_place(node, entry)
	add_child(node)
	_placed.append([node, entry])


func _place(node: Node3D, entry: Dictionary) -> void:
	var bearing : float = _line_deg + float(entry["bearing"])
	var dir : Vector3 = _frame.dir_at(float(entry["distance"]), bearing)
	node.transform = Transform3D(_frame.basis_at(dir, _line_deg + float(entry["facing"])),
		_frame.point(float(entry["distance"]), bearing, float(entry.get("lift", 0.0))))
