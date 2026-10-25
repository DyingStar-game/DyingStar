class_name InteriorProbe
extends ReflectionProbe

## An apartment's reflection probe (no sky nor sun in its metal doors) is drawn only while the camera is
## inside its box. The renderer holds 64 probes on screen at most and Godot 4.7 crashes past that (atlas
## index -1, FATAL in Vector::operator[]); a village streams in every interior within 40 m, so one probe
## per home on at once went far over it. Inside, only the home around the camera can be seen anyway.

## Margin (m) around the box within which the probe is already on: it is drawn before the camera steps in.
const MARGIN_M := 1.0
## Seconds between two looks at the camera: at a run, under MARGIN_M is covered meanwhile.
const CHECK_S := 0.1

var _wait: float = 0.0


func _ready() -> void:
	visible = false
	if not InteriorStreamer.wanted():  # headless: nothing is drawn
		set_process(false)
		return
	_wait = randf() * CHECK_S  # the homes of a village do not all look in the same frame


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = CHECK_S
	var camera := get_viewport().get_camera_3d()
	refresh(camera.global_position if camera != null else Vector3.INF)


## Show the probe while a camera at [param eye] (global) is inside its box.
func refresh(eye: Vector3) -> void:
	var on := eye.is_finite() and holds(global_transform.affine_inverse() * eye, size, MARGIN_M)
	if on != visible:
		visible = on


## Whether [param local], in the probe's frame, lies in a box of [param box_size] centred on it grown
## by [param margin_m] on every side. Pure.
static func holds(local: Vector3, box_size: Vector3, margin_m: float) -> bool:
	var half := box_size * 0.5 + Vector3.ONE * margin_m
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z
