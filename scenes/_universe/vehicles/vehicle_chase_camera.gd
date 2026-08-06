extends Camera3D

## Orbit camera for the vehicle test bench: follows a target's position and lets you orbit
## around it with the RIGHT mouse button (drag) and zoom with the mouse wheel. It only
## tracks the target's position (not its rotation), so the view stays stable while driving.
## Not networked — bench/dev tool only.

## The node to follow (the vehicle). Set in the bench scene.
@export var target_path: NodePath
## Distance from the target.
@export var distance: float = 9.0
## Starting pitch above the target, in degrees.
@export var pitch_deg: float = 25.0
## Mouse drag sensitivity (radians per pixel).
@export var orbit_sensitivity: float = 0.01
## Mouse-wheel zoom step (meters per notch).
@export var zoom_step: float = 1.0
## Min / max zoom distance.
@export var zoom_min: float = 3.0
@export var zoom_max: float = 30.0
## Position follow smoothing (higher = snappier).
@export var follow_speed: float = 8.0

var _target: Node3D = null
var _yaw: float = 0.0
var _pitch: float = 0.0
var _distance: float = 0.0
var _orbiting: bool = false

func _ready() -> void:
	add_to_group("chase_cam")  # so a vehicle can grab it to switch its target while driving
	if target_path != NodePath():
		_target = get_node_or_null(target_path)
	_pitch = deg_to_rad(pitch_deg)
	_distance = distance

## Switch what the camera follows (pilot on foot, vehicle while driving).
func set_target(node: Node3D) -> void:
	_target = node

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				_distance = clampf(_distance - zoom_step, zoom_min, zoom_max)
			MOUSE_BUTTON_WHEEL_DOWN:
				_distance = clampf(_distance + zoom_step, zoom_min, zoom_max)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * orbit_sensitivity
		_pitch = clampf(_pitch - event.relative.y * orbit_sensitivity, deg_to_rad(-5.0), deg_to_rad(85.0))

func _physics_process(delta: float) -> void:
	if _target == null:
		return
	# Orbit offset: start behind (+Z), raise by pitch, then turn by yaw around the target.
	var dir := Vector3(0.0, 0.0, 1.0)
	dir = dir.rotated(Vector3.RIGHT, -_pitch)
	dir = dir.rotated(Vector3.UP, _yaw)
	var desired: Vector3 = _target.global_position + dir * _distance
	global_position = global_position.lerp(desired, clampf(follow_speed * delta, 0.0, 1.0))
	look_at(_target.global_position + Vector3.UP, Vector3.UP)
