class_name StageRig
extends CharacterBody3D
## The menu stage's point of view: a camera that glides from station to station.
##
## A CharacterBody3D standing under the planet, because it is what ClientSky's sun and atmosphere
## observe — exactly as they observe the player: its up_direction must be radial, it exposes `camera`.
## It has no collision and never moves by physics.

const GLIDE_S : float = 1.4

var camera : Camera3D
## Turn the view this much to the left of its target, so the subject stands right of a panel covering
## the left of the screen (the tuning scene's). 0 in the menu.
var yaw_offset_deg : float = 0.0
var _tween : Tween = null


func _init() -> void:
	name = "StageRig"
	collision_layer = 0
	collision_mask = 0
	camera = Camera3D.new()
	camera.near = 0.05
	camera.far = 1e13  # the player camera's: planets and the star stay in view
	add_child(camera)


func _ready() -> void:
	camera.fov = SettingsManager.get_fov()
	SettingsManager.fov_changed.connect(_on_fov_changed)
	camera.make_current()


func _process(_delta: float) -> void:
	# World-space radial up, which the sun reads to settle its day/night.
	up_direction = (global_position - get_parent().global_position).normalized()
	# A vehicle's mirror camera can take the view when it enters the tree: take it back.
	if not camera.current:
		camera.make_current()


## Stand at `eye` looking at `look` (planet-local points) — at once.
func frame(eye: Vector3, look: Vector3) -> void:
	if _tween != null:
		_tween.kill()
	transform = view(eye, look, yaw_offset_deg)


## Glide there, easing in and out.
func glide_to(eye: Vector3, look: Vector3, seconds: float = GLIDE_S) -> void:
	if _tween != null:
		_tween.kill()
	var from : Transform3D = transform
	var to : Transform3D = view(eye, look, yaw_offset_deg)
	_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(func(t: float) -> void: transform = from.interpolate_with(to, t), 0.0, 1.0, seconds)


## Glide to a viewpoint given as a transform (a StageStation's), turned by yaw_offset_deg.
func glide_to_view(view_xform: Transform3D, seconds: float = GLIDE_S) -> void:
	glide_to(view_xform.origin, view_xform.origin - view_xform.basis.z, seconds)


## Stand at a viewpoint given as a transform, at once.
func frame_view(view_xform: Transform3D) -> void:
	frame(view_xform.origin, view_xform.origin - view_xform.basis.z)


## Standing at `eye`, looking at `look` (turned `yaw_deg` to its left), the head up along the radius.
static func view(eye: Vector3, look: Vector3, yaw_deg: float = 0.0) -> Transform3D:
	var up : Vector3 = eye.normalized()
	return Transform3D(Basis(up, deg_to_rad(yaw_deg)) * Basis.looking_at(look - eye, up), eye)


func _on_fov_changed(fov: float) -> void:
	camera.fov = fov
