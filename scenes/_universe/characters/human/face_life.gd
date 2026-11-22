class_name FaceLife
extends Node

## What makes a face alive when seen close up: it blinks, its eyes dart and settle, glance at whoever
## looks at it, its mouth moves when its voice is heard, and its brows and lips never quite stay still.
##
## Drives the blend shapes of the puppet's live head (HumanAppearance.face_life,
## HumanBuilder.LIFE_SHAPES). Does nothing -- and costs nothing -- while the head is not live: an avatar
## far away, or a dedicated server.
##
## Everything here is presentation, local to this machine and seeded per avatar: two players do not see
## the same blink, and need not.

## Shortest time between two blinks (s).
@export var blink_min_s: float = 1.8
## Longest time between two blinks (s). People blink every 3 to 4 s on average, less when they stare.
@export var blink_max_s: float = 6.5
## How far the eyes wander when they look at nothing in particular (deg, standard deviation): higher =
## shiftier eyes, 0 = a fixed stare.
@export var gaze_wander_deg: float = 6.0
## Up to this distance (m) the face may glance at the camera looking at it.
@export var glance_range_m: float = 5.0
## Strength of the idle expressions (brows, squint, the hint of a smile), 0..2: 0 = a still face, 1 = as
## tuned, higher = more animated.
@export_range(0.0, 2.0) var expression_strength: float = 1.0
## How wide the mouth opens for a voice, 0..2: 1 = as tuned, lower for a mumble.
@export_range(0.0, 2.0) var speech_gain: float = 1.0
## This face is our own player's: its mouth follows our microphone (VoiceMeter.own_level) instead of a
## speaker. Set by PlayerClient.
@export var own_voice: bool = false
## Time a held expression (a creator button) takes to come or go (s): lower = snappier.
@export var expression_ease_s: float = 0.25

## Gaze angle (deg) each look shape gives at full weight, measured on the base model's eyes.
const LOOK_LEFT_DEG: float = 18.0
const LOOK_RIGHT_DEG: float = 26.0
const LOOK_UP_DEG: float = 14.0
const LOOK_DOWN_DEG: float = 11.0
## A glance never turns the eyes further than this (deg): beyond, people turn their head.
const GLANCE_MAX_YAW_DEG: float = 38.0
const GLANCE_MAX_PITCH_DEG: float = 22.0
## Speed of a saccade (deg/s): the eyes jump, they do not pan.
const SACCADE_DEG_S: float = 420.0
## A blink: lids down, shut, up again (s).
const BLINK_CLOSE_S: float = 0.07
const BLINK_SHUT_S: float = 0.04
const BLINK_OPEN_S: float = 0.15
## From the head's joint to between the eyes, in the head's rest frame (m).
const EYES_FROM_HEAD := Vector3(0.0, 0.09, 0.08)
## How often the speaker carrying this avatar's voice is looked for (s).
const SPEAKER_SEARCH_S: float = 1.0
## Name prefix of the voice chat's speakers (livekit.gd).
const SPEAKER_PREFIX: String = "LKAudio_"
## The expressions a face can be asked to hold (the creator's buttons): life shape -> weight. A weight may
## pass 1: the base model's sadness and anger are faint at full weight. Blinks, glances and the voice go on
## over them; the idle temper steps aside.
const EXPRESSIONS: Dictionary = {
	&"neutral": {},
	&"smile": {&"smile": 0.7, &"happy": 0.5, &"squint": 0.35, &"cheeks_raised": 1.0},
	&"laugh": {&"happy": 1.0, &"lips_apart": 0.5, &"jaw_open": 0.2, &"squint": 0.5, &"cheeks_raised": 1.0},
	&"wink": {&"smile": 0.9, &"blink_left": 1.0, &"squint": 0.2},
	&"surprise": {&"brows_up": 1.0, &"eyes_wide": 1.0, &"jaw_open": 0.55, &"mouth_round": 0.4},
	&"sad": {&"sad": 2.0, &"mouth_corners_down": 0.8, &"brows_up": 0.3},
	&"angry": {&"angry": 2.0, &"brows_frown": 1.0, &"squint": 0.4, &"mouth_closed": 0.5},
	&"disgust": {&"disgusted": 0.8, &"brows_frown": 0.6, &"squint": 0.3},
	&"fear": {&"scared": 0.8, &"brows_up": 0.5, &"brows_frown": 0.35, &"eyes_wide": 1.0},
}
## The idle shapes the temper and the drift move (_express): an expression held quiets them.
const IDLE_SHAPES: Array[StringName] = [&"brows_up", &"brows_frown", &"squint", &"smile", &"happy", &"sad", &"angry"]
## A laugh shakes: the jaw drops and closes a little, in "ha"s (per second), by up to this weight.
const LAUGH_HA_PER_S: float = 4.5
const LAUGH_HA_WEIGHT: float = 0.18
## How deep a held expression folds the cheeks (face_motion, 0..1): fully, the fold caught the key light in a
## white streak on a dark cheek.
const EXPRESSION_FOLDS: float = 0.5
## Highest weight a life shape is given (an expression's may pass 1, see EXPRESSIONS).
const MAX_SHAPE_WEIGHT: float = 2.0

## Voice level 0..1 fed from outside (a test, a scripted line); the larger of this and the metered voice
## moves the mouth.
var voice_level: float = 0.0
## Where to look instead of the camera, in world space (a scripted scene); used while has_gaze_point.
var gaze_point := Vector3.ZERO
var has_gaze_point: bool = false
## The expression held (an EXPRESSIONS key): the face eases into it and keeps it until told otherwise.
var expression: StringName = &"neutral"

var _looks: HumanAppearance
var _rng := RandomNumberGenerator.new()
var _values: Dictionary = {}  # life shape -> weight of this frame
var _shown_head: int = 0  # instance id of the live mesh the indices below are for
var _indices: Dictionary = {}  # life shape -> blend shape index
var _head_bone: int = -1
var _time: float = 0.0
var _blink_in: float = 2.0
var _blink_t: float = -1.0
var _gaze_in: float = 0.0
var _glancing: bool = false
var _wander := Vector2.ZERO
var _jitter := Vector2.ZERO
var _jitter_in: float = 0.0
var _eyes := Vector2.ZERO  # yaw (to the character's left), pitch (up), deg
var _voice: float = 0.0
var _speaker: Node = null
var _speaker_in: float = 0.0
var _mood := Vector3.ZERO  # happy, sad, angry: the face's resting temper
var _held: Dictionary = {}  # life shape -> weight of the held expression, eased
var _holding: float = 0.0  # 0..1: how far into a held expression (not neutral) the face is


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)
		return
	_looks = get_parent().get_node_or_null(^"HumanAppearance") as HumanAppearance
	_rng.seed = hash(get_path())
	_time = _rng.randf() * 100.0
	if _looks == null:
		set_process(false)
		return
	_looks.appearance_applied.connect(_on_appearance_applied)
	_on_appearance_applied()


func _exit_tree() -> void:
	_stop_listening()


## A temper per person, the same for everyone who meets them: most faces rest neutral, some a little
## cheerful, a few stern.
func _on_appearance_applied() -> void:
	if _looks.appearance == null:
		return
	var temper := RandomNumberGenerator.new()
	temper.seed = _looks.appearance.shape_hash()
	var kind: float = temper.randf()
	_mood = Vector3.ZERO
	if kind < 0.35:
		_mood.x = temper.randf_range(0.05, 0.22)
	elif kind < 0.5:
		_mood.y = temper.randf_range(0.05, 0.18)
	elif kind < 0.62:
		_mood.z = temper.randf_range(0.05, 0.15)


func _process(delta: float) -> void:
	if not _looks.is_live():
		if _shown_head != 0:
			_shown_head = 0
			_stop_listening()
		return
	var head: MeshInstance3D = _looks.head_mesh()
	if head.mesh.get_instance_id() != _shown_head:
		_shown_head = head.mesh.get_instance_id()
		_indices.clear()
		for shape: Array in HumanBuilder.LIFE_SHAPES:
			_indices[shape[0]] = _looks.face_shape_index(shape[0])
		var skeleton := head.get_parent() as Skeleton3D
		_head_bone = skeleton.find_bone("Head") if skeleton != null else -1
	_time += delta
	_values.clear()
	_blink(delta)
	_gaze(delta, head)
	_speak(delta)
	_express()
	var folds: float = maxf(_values.get(&"smile", 0.0), _values.get(&"happy", 0.0))
	_hold_expression(delta)
	folds = maxf(folds, EXPRESSION_FOLDS * maxf(_held.get(&"smile", 0.0), _held.get(&"happy", 0.0)))
	for shape: StringName in _indices:
		var index: int = _indices[shape]
		if index != -1:
			head.set_blend_shape_value(index, clampf(_values.get(shape, 0.0), 0.0, MAX_SHAPE_WEIGHT))
	_looks.set_smile(clampf(folds, 0.0, 1.0))


## The weights this frame gave each shape (tests, the creator's debug view).
func shape_values() -> Dictionary:
	return _values


## Blink now (a scripted reaction; a large glance also asks for one).
func blink() -> void:
	if _blink_t < 0.0:
		_blink_t = 0.0


func _blink(delta: float) -> void:
	_blink_in -= delta
	if _blink_in <= 0.0 and _blink_t < 0.0:
		_blink_t = 0.0
	if _blink_t < 0.0:
		return
	_blink_t += delta
	var w: float = blink_weight(_blink_t)
	if _blink_t >= BLINK_CLOSE_S + BLINK_SHUT_S + BLINK_OPEN_S:
		_blink_t = -1.0
		# One blink in eight is followed by another at once.
		_blink_in = 0.22 if _rng.randf() < 0.125 else _rng.randf_range(blink_min_s, maxf(blink_min_s, blink_max_s))
	_values[&"blink_left"] = w
	_values[&"blink_right"] = w


## Lid closure 0..1 at [param t] seconds into a blink: down fast, shut, up slower.
static func blink_weight(t: float) -> float:
	if t < 0.0:
		return 0.0
	if t < BLINK_CLOSE_S:
		return smoothstep(0.0, 1.0, t / BLINK_CLOSE_S)
	if t < BLINK_CLOSE_S + BLINK_SHUT_S:
		return 1.0
	return 1.0 - smoothstep(0.0, 1.0, clampf((t - BLINK_CLOSE_S - BLINK_SHUT_S) / BLINK_OPEN_S, 0.0, 1.0))


func _gaze(delta: float, head: MeshInstance3D) -> void:
	var seen: Vector2 = _angles_to_viewer(head)
	var can_glance: bool = seen.x != INF
	_gaze_in -= delta
	if _gaze_in <= 0.0 or (_glancing and not can_glance):
		var before: Vector2 = _wander
		# Someone talking, or standing right there, is looked at more often than a passer-by.
		var chance: float = 0.8 if (_voice > 0.1 or has_gaze_point) else 0.45
		_glancing = can_glance and _rng.randf() < chance
		if _glancing:
			_gaze_in = _rng.randf_range(1.2, 3.5)
		else:
			_wander = Vector2(_rng.randfn(0.0, gaze_wander_deg), _rng.randfn(0.0, gaze_wander_deg * 0.5))
			_gaze_in = _rng.randf_range(0.6, 2.6)
			if before.distance_to(_wander) > gaze_wander_deg * 1.5 and _rng.randf() < 0.5:
				blink()  # the eyes often blink as they jump
	# Eyes that look at a face do not rest on a point: they hop between its eyes and its mouth.
	_jitter_in -= delta
	if _jitter_in <= 0.0:
		_jitter_in = _rng.randf_range(0.25, 0.9)
		_jitter = Vector2(_rng.randfn(0.0, 1.2), _rng.randfn(0.0, 0.9))
	var wanted: Vector2 = (seen if _glancing and can_glance else _wander) + _jitter
	_eyes = _eyes.move_toward(wanted, SACCADE_DEG_S * delta)
	var weights: Dictionary = gaze_weights(_eyes)
	for shape: StringName in weights:
		_values[shape] = weights[shape]


## Look shape weights for a gaze of [param angles] (deg): x to the character's left, y up.
static func gaze_weights(angles: Vector2) -> Dictionary:
	return {
		&"look_left": clampf(angles.x / LOOK_LEFT_DEG, 0.0, 1.0),
		&"look_right": clampf(-angles.x / LOOK_RIGHT_DEG, 0.0, 1.0),
		&"look_up": clampf(angles.y / LOOK_UP_DEG, 0.0, 1.0),
		&"look_down": clampf(-angles.y / LOOK_DOWN_DEG, 0.0, 1.0),
	}


## Yaw and pitch (deg) from this face to what it may glance at -- gaze_point, else the camera -- in the
## head's own frame; Vector2(INF, INF) when it is out of range or out of the eyes' reach.
func _angles_to_viewer(head: MeshInstance3D) -> Vector2:
	var nothing := Vector2(INF, INF)
	var skeleton := head.get_parent() as Skeleton3D
	if skeleton == null or _head_bone == -1:
		return nothing
	var target: Vector3 = gaze_point
	if not has_gaze_point:
		var camera: Camera3D = get_viewport().get_camera_3d()
		if camera == null:
			return nothing
		target = camera.global_position
	var pose: Transform3D = skeleton.get_bone_global_pose(_head_bone)
	if absf(pose.basis.determinant()) < 1e-4:
		return nothing  # our own head, collapsed in first person
	# The head's turn from its rest, in the skeleton's frame: there the face looks along +Z, +X is its left.
	var turn: Basis = pose.basis.orthonormalized() * skeleton.get_bone_global_rest(_head_bone).basis.orthonormalized().inverse()
	var eyes: Vector3 = pose.origin + turn * EYES_FROM_HEAD
	var to: Vector3 = turn.inverse() * (skeleton.global_transform.affine_inverse() * target - eyes)
	var distance: float = to.length()
	if distance < 0.3 or (distance > glance_range_m and not has_gaze_point):
		return nothing
	var angles := Vector2(rad_to_deg(atan2(to.x, to.z)), rad_to_deg(asin(clampf(to.y / distance, -1.0, 1.0))))
	if absf(angles.x) > GLANCE_MAX_YAW_DEG or absf(angles.y) > GLANCE_MAX_PITCH_DEG:
		return nothing
	return angles


func _speak(delta: float) -> void:
	var heard: float = maxf(voice_level, _heard(delta))
	# Up at once, down in ~0.15 s: a mouth lags a voice a little, it does not flutter with it.
	_voice = heard if heard > _voice else lerpf(_voice, heard, 1.0 - exp(-delta * 7.0))
	if _voice < 0.02:
		return
	var mouth: Dictionary = speech_weights(_voice * speech_gain, _time)
	for shape: StringName in mouth:
		_values[shape] = mouth[shape]


## Mouth shape weights for a voice of [param level] (0..1) at time [param t] (s). No phoneme is known,
## only loudness: the jaw follows it in syllables (~5 a second), the lips wander between round and wide.
static func speech_weights(level: float, t: float) -> Dictionary:
	var syllable: float = absf(sin(t * 16.5)) * (0.65 + 0.35 * sin(t * 7.3 + 1.7))
	return {
		&"jaw_open": clampf(level * (0.2 + 0.6 * syllable), 0.0, 0.85),
		&"mouth_round": clampf(level * 0.5 * maxf(0.0, sin(t * 3.1 + 0.5)), 0.0, 0.6),
		&"mouth_wide": clampf(level * 0.4 * maxf(0.0, sin(t * 2.3 + 2.6)), 0.0, 0.5),
	}


## The voice this avatar is heard with right now, 0..1.
func _heard(delta: float) -> float:
	if own_voice:
		return clampf(VoiceMeter.own_level * 4.0, 0.0, 1.0)
	_speaker_in -= delta
	if _speaker_in <= 0.0:
		_speaker_in = SPEAKER_SEARCH_S
		var found: Node = _find_speaker()
		if found != _speaker:
			_stop_listening()
			_speaker = found
	return VoiceMeter.level(_speaker) if is_instance_valid(_speaker) else 0.0


## The voice chat hangs a player's speaker on the player's own node: one of ours ancestors.
func _find_speaker() -> Node:
	var node: Node = get_parent()
	for _level in 4:
		if node == null:
			return null
		for child in node.get_children():
			if (child is AudioStreamPlayer3D or child is AudioStreamPlayer) and String(child.name).begins_with(SPEAKER_PREFIX):
				return child
		node = node.get_parent()
	return null


func _stop_listening() -> void:
	if is_instance_valid(_speaker):
		VoiceMeter.release(_speaker)
	elif _speaker != null:
		VoiceMeter.sweep()  # freed with the player's voice: its bus goes too
	_speaker = null
	_speaker_in = 0.0


## The face at rest is never still: brows and lids drift, the temper shows a little, more when talking.
func _express() -> void:
	var k: float = expression_strength
	var slow: float = sin(_time * 0.37) * 0.5 + sin(_time * 0.83 + 1.3) * 0.5  # -1..1, never periodic to the eye
	var slower: float = sin(_time * 0.21 + 2.1)
	_values[&"brows_up"] = k * (maxf(0.0, slow) * 0.12 + _voice * 0.18 * maxf(0.0, sin(_time * 1.9)))
	_values[&"brows_frown"] = k * (maxf(0.0, -slow) * 0.08 + _mood.z * 0.6)
	_values[&"squint"] = k * maxf(0.0, slower) * 0.1
	_values[&"smile"] = k * (_mood.x * 0.5 + maxf(0.0, -slower) * 0.06)
	_values[&"happy"] = k * _mood.x
	_values[&"sad"] = k * _mood.y
	_values[&"angry"] = k * _mood.z


## Ease towards the expression held and lay it over this frame's weights: each shape takes the larger of
## the two, so a blink still closes the eyes of a smile, and a wink's eye stays shut through a blink.
func _hold_expression(delta: float) -> void:
	var wanted: Dictionary = EXPRESSIONS.get(expression, {})
	var step: float = delta / maxf(expression_ease_s, 0.001)
	_holding = move_toward(_holding, 0.0 if wanted.is_empty() else 1.0, step)
	for shape: StringName in wanted:
		if not _held.has(shape):
			_held[shape] = 0.0
	for shape: StringName in _held.keys():
		var target: float = wanted.get(shape, 0.0)
		_held[shape] = move_toward(_held[shape], target, step * maxf(1.0, target))
		if _held[shape] == 0.0 and target == 0.0:
			_held.erase(shape)
	var quiet: float = 1.0 - _holding
	for shape: StringName in IDLE_SHAPES:
		if _values.has(shape):
			_values[shape] *= quiet
	for shape: StringName in _held:
		_values[shape] = maxf(_values.get(shape, 0.0), _held[shape])
	if expression == &"laugh":
		var ha: float = LAUGH_HA_WEIGHT * _holding * absf(sin(_time * PI * LAUGH_HA_PER_S))
		_values[&"jaw_open"] = _values.get(&"jaw_open", 0.0) + ha
		_values[&"lips_apart"] = _values.get(&"lips_apart", 0.0) + ha
