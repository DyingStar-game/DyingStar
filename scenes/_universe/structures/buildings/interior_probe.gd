class_name InteriorProbe
extends ReflectionProbe

## A building's reflection probe, drawn only while the camera is in its box or within margin_m of it. EVERY
## ReflectionProbe of the game is one of these (test_reflection_probes_gated): the renderer holds
## `reflection_count` probes on screen at most and Godot 4.7 crashes past that (atlas index -1, FATAL in
## Vector::operator[]); a village streams in every interior within 40 m, so one probe per home on at once went
## far over it. That is what lets project.godot keep the atlas at 16 probes: its 64 by default took 500 MiB of
## video memory from the first probe drawn (7.8 MiB a probe at 256 px, used or not; 2026-11-27).
##
## An apartment's (no sky nor sun in its metal doors) is on from 1 m around its box: inside, only the home
## around the camera can be seen. A crusher's or a refinery's lights their metal seen from OUTSIDE: without it a
## shiny surface facing down mirrors the sky's radiance under the horizon, which is black (the conveyor belts
## went black at 1 m, 2026-11-27), so theirs reach tens of metres. A mining village lines up 4 crushers 21 m
## apart: keep margin_m small enough that the probes on at once stay well under reflection_count.

## Default of margin_m: an apartment's, on just before the camera steps in.
const MARGIN_M := 1.0
## Seconds between two looks at the camera: at a run, under MARGIN_M is covered meanwhile.
const CHECK_S := 0.1

## Distance (m) around the probe's box within which it is on. Raise it for a building whose metal is seen from
## outside (tens of metres for a crusher); keep it small where probes sit side by side (1 m for homes): every
## probe on at once takes one of the atlas' `reflection_count` places, and Godot crashes past them.
@export var margin_m: float = MARGIN_M
## Extra distance (m) past margin_m before a probe that is on turns off again. Each time it comes back on it is
## drawn again (the scene rendered 6 times, a hitch): 0 for homes side by side, a few metres where someone may
## walk back and forth across the edge.
@export var release_m: float = 0.0

var _wait: float = 0.0
## client.ini debug_probes_log: a line each time a probe turns on or off, with the camera's distance.
static var _log: bool = ClientConfig.get_bool("debug_probes_log", false)


func _ready() -> void:
	# client.ini debug_probes_always_on: every probe on for good, as before 2026-11-27 (an A/B on its looks; the
	# atlas may overflow in a village).
	if ClientConfig.get_bool("debug_probes_always_on", false):
		set_process(false)
		return
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


## Show the probe while a camera at [param eye] (global) is within margin_m of its box (margin_m + release_m once
## on).
func refresh(eye: Vector3) -> void:
	var reach := margin_m + (release_m if visible else 0.0)
	var on := eye.is_finite() and holds(global_transform.affine_inverse() * eye, size, reach)
	if on != visible:
		visible = on
		if _log:
			print("[Probe] %s %s | camera %.1f m from its centre, reach %.0f m around a %s box" % [
				"ON " if on else "off", get_path(), global_position.distance_to(eye), reach, size])


## Whether [param local], in the probe's frame, lies in a box of [param box_size] centred on it grown
## by [param margin_m] on every side. Pure.
static func holds(local: Vector3, box_size: Vector3, margin_m: float) -> bool:
	var half := box_size * 0.5 + Vector3.ONE * margin_m
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z
