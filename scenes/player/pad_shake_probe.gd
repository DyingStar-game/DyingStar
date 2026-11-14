class_name PadShakeProbe
extends Node

## Diagnostic (client.ini debug_wrist_probe=true): what moves while the DataPad is read. "The DataPad
## shakes at the wheel" can be the view, the arm, the device on the arm, the body on its seat, or the
## picture on the screen -- told apart here, twice a second, as "[PadShake]" lines.
##
## Each frame the tablet is open, once the skeleton is posed, it takes every link of the chain from the
## vehicle to the screen and to the camera IN ITS PARENT'S FRAME (local transforms only, LocalFrame: the
## world is 4e10 m out and would add its own rounding), and prints how far each one moved over the
## window: µm and µrad, peak to peak. The first figure is the one the eye gets -- the screen in the
## camera's frame, also in pixels of the window -- the others say which link it comes from:
##   camera in body   the look or the camera's place is being written (seat, parallax, head camera);
##   device in arm    the device is being moved where it hangs (the forearm, or the body while read);
##   forearm, shoulder (skeleton's space)  the IK or the lean moves the arm;
##   puppet in body   the avatar is being moved under the player (seat pose);
##   body in vehicle  the player is being moved on the seat (_ride_seat, _steady_body);
##   picture          the tablet's own layout moves on its screen, or its size changes.
## "engine px" is the same screen point through the engine's own world transforms: larger than the
## first figure, the world's rounding is what shakes.

## Seconds between two lines.
const WINDOW_S: float = 0.5

var _pad: WristDatapad = null
var _player = null  # the Player facade (untyped, as in WristDatapad)
var _camera: Camera3D = null
var _model: WristDatapadModel = null
var _terminal = null
var _skeleton: Skeleton3D = null
var _shoulder: int = -1
var _forearm: int = -1
var _spans: Dictionary = {}  # name -> Span
var _names: PackedStringArray = []
var _frames: int = 0
var _t: float = 0.0
var _last_usec: int = 0


## How far a transform strayed over a window: the box its origin stayed in, and the widest angle from
## the first basis seen.
class Span:
	var lo: Vector3 = Vector3.INF
	var hi: Vector3 = -Vector3.INF
	var first: Basis = Basis.IDENTITY
	var angle: float = 0.0
	var seen: bool = false

	func add(xf: Transform3D) -> void:
		lo = lo.min(xf.origin)
		hi = hi.max(xf.origin)
		var b: Basis = xf.basis.orthonormalized()
		if not seen:
			first = b
			seen = true
		angle = maxf(angle, (b * first.inverse()).get_rotation_quaternion().get_angle())

	## Peak to peak of the origin (m).
	func moved() -> float:
		return (hi - lo).length() if seen else 0.0


static func enabled() -> bool:
	return ClientConfig.get_bool("debug_wrist_probe", false)


func setup(pad: WristDatapad, player, camera: Camera3D, model: WristDatapadModel, terminal) -> void:
	_pad = pad
	_player = player
	_camera = camera
	_model = model
	_terminal = terminal


func _process(_delta: float) -> void:
	if _skeleton == null:
		_find_skeleton()
		if _skeleton == null:
			_sample()  # no skeleton to wait for: read at the end of the frame's scripts


## Whatever is true of the links, in one line. Static and pure, for the tests.
static func line(spans: Dictionary, names: PackedStringArray, frames: int, px_per_m: float, extra: String) -> String:
	var parts: PackedStringArray = []
	for key: String in names:
		var span: Span = spans.get(key)
		if span == null:
			continue
		var text: String = "%s %.1f um %.1f urad" % [key, span.moved() * 1e6, span.angle * 1e6]
		if key == "screen in camera":
			text += " = %.2f px" % (span.moved() * px_per_m)
		parts.append(text)
	return "[PadShake] %d frames | %s | %s" % [frames, " | ".join(parts), extra]


func _find_skeleton() -> void:
	# From the avatar, not from the device: read, the device hangs on the body (WristDatapad._pin_device).
	var puppet: Node = _player.puppet if _player != null else null
	var found: Array = puppet.find_children("*", "Skeleton3D", true, false) if puppet != null else []
	if found.is_empty():
		return
	_skeleton = found[0] as Skeleton3D
	_shoulder = _skeleton.find_bone("LeftUpperArm")
	_forearm = _skeleton.find_bone("LeftLowerArm")
	_skeleton.skeleton_updated.connect(_sample)


func _span(key: String) -> Span:
	if not _spans.has(key):
		_spans[key] = Span.new()
		_names.append(key)
	return _spans[key]


## One frame's reading (the skeleton is posed), and the line when the window is over.
func _sample() -> void:
	var now: int = Time.get_ticks_usec()
	var delta: float = (now - _last_usec) * 1e-6 if _last_usec != 0 else 0.0
	_last_usec = now
	if _pad == null or _pad.phase != WristDatapad.Phase.OPEN or not is_instance_valid(_model):
		if _frames > 0:
			_reset()
		return
	var body: Node3D = _player.camera_pivot.get_parent() as Node3D
	var camera_in_body: Transform3D = _player.camera_pivot.transform * _camera.transform
	var screen_in_body: Transform3D = LocalFrame.of(_model.screen, body)
	_span("screen in camera").add(camera_in_body.affine_inverse() * screen_in_body)
	_span("camera in body").add(camera_in_body)
	_span("device in arm").add(_model.transform)
	if _skeleton != null:
		if _forearm != -1:
			_span("forearm").add(_skeleton.get_bone_global_pose(_forearm))
		if _shoulder != -1:
			_span("shoulder").add(_skeleton.get_bone_global_pose(_shoulder))
	if _player.puppet != null:
		_span("puppet in body").add(LocalFrame.of(_player.puppet, body))
	_span("body in vehicle").add(body.transform)
	# The picture: where the tablet's layout stands in its viewport, and the viewport's size.
	var rect := Rect2()
	if _terminal is Control:
		rect = (_terminal as Control).get_global_rect()
	_span("picture").add(Transform3D(Basis.IDENTITY, Vector3(rect.position.x, rect.position.y, rect.size.x)))
	_span("viewport").add(Transform3D(Basis.IDENTITY, Vector3(_model.viewport.size.x, _model.viewport.size.y, _camera.fov)))
	_span("engine px").add(Transform3D(Basis.IDENTITY,
			Vector3(_camera.unproject_position(_model.screen.global_position).x,
					_camera.unproject_position(_model.screen.global_position).y, 0.0)))
	_frames += 1
	_t += delta
	if _t < WINDOW_S:
		return
	var depth: float = absf((camera_in_body.affine_inverse() * screen_in_body).origin.z)
	var height_px: float = _camera.get_viewport().get_visible_rect().size.y
	var px_per_m: float = height_px * 0.5 / maxf(tan(deg_to_rad(_camera.fov) * 0.5) * depth, 1e-6)
	var s: Dictionary = _player.locomotion_sample
	var extra: String = "picture %.2f px, viewport+fov %.4f, engine %.2f px | seated=%s driver=%s fov %.2f depth %.3f m" % [
			(_spans["picture"] as Span).moved(), (_spans["viewport"] as Span).moved(),
			(_spans["engine px"] as Span).moved(), str(bool(s.get("seated", false))),
			str(bool(s.get("driver", false))), _camera.fov, depth]
	var shown: PackedStringArray = []
	for key: String in _names:
		if key != "picture" and key != "viewport" and key != "engine px":
			shown.append(key)
	print(line(_spans, shown, _frames, px_per_m, extra))
	_reset()


func _reset() -> void:
	_spans.clear()
	_names.clear()
	_frames = 0
	_t = 0.0
