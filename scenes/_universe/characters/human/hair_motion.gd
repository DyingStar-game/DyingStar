class_name HairMotion
extends Node

## Hair that moves, client side: every avatar's head of hair (and long beard) past its fixed length, with the wind
## and its own motion. Nothing goes over the network: each client moves the hair it sees.
##
## The meshes stay shared per style (HairStrands); an avatar's hair moves in the strands shader (HairMotionBinding),
## by tiers, re-chosen four times a second by the camera's distance:
## - near (SIM_NEAR m, at most MAX_SIM avatars, nearest first): its strands simulated (HairMotionNative.Step, in C#),
##   their displacements written in its row of the global texture hair_motion_rows;
## - farther (SWING_FAR m): it swings as one, a damped spring per avatar (the instance uniform hair_motion's yzw);
##   so too without the C# twin;
## - beyond: still. A long beard always swings as one (hair_motion on the head's instance).
## Moving between tiers eases over FADE_S. One node per tree, made on first use (track()), never without a display
## (a server sees no hair).

const NODE_NAME := &"HairMotion"
## Texture rows: simulated avatars at once.
const ROWS: int = 8
const MAX_SIM: int = ROWS
## The simulated strands of an avatar's row: HairMotionBinding.SIM_GUIDES of SAMPLES texels.
const WIDTH: int = HairMotionBinding.SIM_GUIDES * HairMotionBinding.SAMPLES
## Tiers by the camera's distance to the head (m): simulated within SIM_NEAR (let go past SIM_FAR), swinging
## within SWING_FAR.
const SIM_NEAR: float = 10.0
const SIM_FAR: float = 12.0
const SWING_FAR: float = 25.0
## How often tiers are chosen and the wind is read (s), how long a change of tier eases (s).
const TIER_INTERVAL: float = 0.25
const WIND_INTERVAL: float = 0.5
const FADE_S: float = 0.3
## Earth's gravity (m/s²): the hair falls along the avatar's down.
const GRAVITY: float = 9.81
## How far a swing may go (m at 10 cm past the fixed length).
const MAX_SWING: float = 0.08
## The swing is a pendulum's 10 cm past its fixed length, its length about 30 cm: it moves a third as much as what
## pushes it, the head's acceleration and the air's speed past it (SWING_AIR of it).
const SWING_LEVER: float = 0.33
const SWING_AIR: float = 0.5
## Share of a frame's measured head acceleration taken in (the rest is the frames before).
const ACCEL_SMOOTHING: float = 0.3

enum Tier { STILL, SWING, SIM }

@export_group("Simulated strands (near)")
## Share of a strand point's speed kept per 60th of a second, 0..1: lower = the hair settles sooner, higher = it
## swings on longer.
@export_range(0.8, 1.0, 0.001) var damping: float = 0.96
## How fast the air brings the hair to its own speed (1/s): higher = the wind and the run carry the hair more,
## lower = it swings more freely.
@export_range(0.0, 20.0, 0.1) var drag: float = 3.0
## How hard the hair is pulled back to its cut just past its fixed length, 0..1 per frame: higher = stiffer roots.
@export_range(0.0, 1.0, 0.01) var shape_root: float = 0.3
## How hard the hair is pulled back to its cut at the tip, 0..1 per frame: higher = the ends keep the cut's shape,
## lower = they hang and fly free.
@export_range(0.0, 1.0, 0.005) var shape_tip: float = 0.03
## Share of the planet's pull the hair feels, 0..2: lower = floatier hair.
@export_range(0.0, 2.0, 0.01) var gravity_scale: float = 1.0
## How far the hair keeps off the head and the body's capsules (m).
@export_range(0.0, 0.02, 0.0005) var margin: float = 0.004
## Constraint passes per step: higher = stiffer, more exact, more CPU.
@export_range(1, 8) var iterations: int = 4
## How far from its root a loose hair stays put (m): the shaders' fixed_length too (CharacterMaterials).
@export_range(0.0, 0.3, 0.005) var fixed_length: float = HairMotionBinding.FIXED_LENGTH

@export_group("Swing as one (farther)")
## How stiff the swing's spring is (1/s²): higher = it springs back faster.
@export_range(1.0, 200.0, 1.0) var swing_stiffness: float = 40.0
## How fast the swing dies out (1/s).
@export_range(0.0, 20.0, 0.1) var swing_damping: float = 4.0

@export_group("Wind")
## The air around avatars that stand on no planet (m/s, world frame): the character creator's breeze.
@export var breeze := Vector3.ZERO
## How much a breeze gusts, 0..1: 0 = steady.
@export_range(0.0, 1.0, 0.01) var gust: float = 0.4

## One avatar whose hair may move.
class Entry:
	var look: WeakRef  # HumanAppearance
	var hair: MeshInstance3D
	var head: MeshInstance3D
	var skeleton: Skeleton3D
	var head_bone: int = -1
	var binding: HairMotionBinding
	var colliders: Array = []  # [bone index, a, b, radius]
	var beard_length: float = 0.0
	var tier: int = Tier.STILL
	var want: int = Tier.STILL
	var row: int = -1
	var amount: float = 0.0
	var reset: bool = true
	var swing := Vector3.ZERO  # frame space
	var swing_speed := Vector3.ZERO
	var last := Vector3.ZERO  # the head, frame space
	var speed := Vector3.ZERO
	var accel := Vector3.ZERO  # smoothed: a frame's jitter in the head's position is not a jolt
	var has_last: bool = false
	var hair_value := Vector4(-1.0, 0.0, 0.0, 0.0)  # the hair_motion last set on the hair (set again only when it changes)
	var wind := Vector3.ZERO  # frame space
	var frame: Node3D = null  # its planet (Planet.of), found when its tier is chosen
	var still_set: bool = false  # still, and its hair and beard told so
	var id: int = 0  # its number in HairMotionNative
	var dirty: bool = true  # to be (re)registered with HairMotionNative

var _entries: Array[Entry] = []
var _native: Object = null
var _image: Image
var _texture: ImageTexture
var _rows_free: Array[int] = []
var _tier_clock: float = 0.0
var _wind_clock: float = 0.0
var _time: float = 0.0
var _next_id: int = 1


static var _made: HairMotion = null


## The tree's HairMotion, made on first call (added to the root at the end of the frame); null without a display.
static func of(node: Node) -> HairMotion:
	if node == null or not node.is_inside_tree() or DisplayServer.get_name() == "headless":
		return null
	if is_instance_valid(_made) and not _made.is_queued_for_deletion():
		return _made
	var root: Window = node.get_tree().root
	_made = root.get_node_or_null(NodePath(NODE_NAME)) as HairMotion
	if _made == null:
		_made = HairMotion.new()
		_made.name = NODE_NAME
		root.add_child.call_deferred(_made)
	return _made


## Follow [param look]'s hair (again: a new body, a new cut); its hair stops moving when it leaves the tree.
func track(look: HumanAppearance) -> void:
	var entry: Entry = null
	for e in _entries:
		if e.look.get_ref() == look:
			entry = e
	if entry == null:
		entry = Entry.new()
		entry.look = weakref(look)
		entry.id = _next_id
		_next_id += 1
		_entries.append(entry)
	entry.dirty = true
	_release(entry)
	entry.tier = Tier.STILL
	entry.amount = 0.0
	entry.hair = look.hair_mesh()
	entry.head = look.head_mesh()
	entry.skeleton = look.skeleton()
	entry.head_bone = entry.skeleton.find_bone("Head") if entry.skeleton != null else -1
	var asset: HumanAssetData = look.hair_asset()
	entry.binding = HairStrands.motion_of(asset) if asset != null else null
	entry.colliders.clear()
	for c: Array in look.hair_colliders():
		var bone: int = entry.skeleton.find_bone(c[0]) if entry.skeleton != null else -1
		if bone != -1:
			entry.colliders.append([bone, c[1], c[2], c[3]])
	entry.beard_length = look.beard_length()
	entry.reset = true
	entry.still_set = false
	entry.frame = Planet.of(entry.skeleton) if entry.skeleton != null else null
	entry.has_last = false
	entry.accel = Vector3.ZERO
	entry.hair_value = Vector4(-1.0, 0.0, 0.0, 0.0)
	entry.swing = Vector3.ZERO
	entry.swing_speed = Vector3.ZERO
	_tier_clock = TIER_INTERVAL  # choose at once


func _ready() -> void:
	_native = HairMotionBinding.native_instance()
	if _native != null:
		var head: HairHead = HairHead.shared()
		_native.call("Configure", head.sdf, head.sdf_origin, head.sdf_cell, head.sdf_size, head.centre.y - 0.1)
	_image = Image.create(WIDTH, ROWS, false, Image.FORMAT_RGBAF)
	_texture = ImageTexture.create_from_image(_image)
	RenderingServer.global_shader_parameter_set(&"hair_motion_rows", _texture)
	if _native != null:
		_native.call("Setup", _image, _texture, ROWS, WIDTH,
				PackedFloat64Array([FADE_S, MAX_SWING, SWING_LEVER, SWING_AIR, ACCEL_SMOOTHING, GRAVITY]))
	for r in ROWS:
		_rows_free.append(r)


func _process(delta: float) -> void:
	step(delta)


## One frame of [param delta] s for every avatar followed (the hair bench calls it with a fixed step).
func step(delta: float) -> void:
	var token: int = ClientPerf.scope_begin()
	if _native != null:
		_step_native(delta)
		ClientPerf.scope_end("hair_motion", token)
		return
	_time += delta
	_drop_gone()
	_tier_clock += delta
	if _tier_clock >= TIER_INTERVAL:
		_tier_clock = 0.0
		_choose_tiers()
	_wind_clock += delta
	var read_wind: bool = _wind_clock >= WIND_INTERVAL
	if read_wind:
		_wind_clock = 0.0
	var inputs := PackedFloat64Array()
	for e in _entries:
		_move(e, delta, read_wind, inputs)
	if _native != null and not inputs.is_empty():
		_native.call("Tune", PackedFloat64Array([damping, drag, shape_root, shape_tip, gravity_scale, margin, iterations]))
		var bytes: PackedByteArray = _native.call("Step", delta, inputs, ROWS, WIDTH)
		_image.set_data(WIDTH, ROWS, false, Image.FORMAT_RGBAF, bytes)
		_texture.update(_image)
	ClientPerf.scope_end("hair_motion", token)


## The frame with the C# twin: each frame's work is HairMotionNative.Frame's; here, four times a second, the tiers,
## the wind and the mirror doubles it is steered by, and the avatars (re)registered.
func _step_native(delta: float) -> void:
	_time += delta
	for e in _entries:
		if e.dirty:
			_register(e)
	_tier_clock += delta
	_wind_clock += delta
	if _tier_clock >= TIER_INTERVAL:
		_tier_clock = 0.0
		_drop_gone()
		_choose_tiers()
		var read_wind: bool = _wind_clock >= WIND_INTERVAL
		if read_wind:
			_wind_clock = 0.0
		for e in _entries:
			if e.skeleton == null or e.head_bone == -1:
				continue
			var frame: Node3D = e.frame if is_instance_valid(e.frame) else null
			if read_wind or e.reset:
				var to_frame: Transform3D = frame.global_transform.affine_inverse() if frame != null else Transform3D.IDENTITY
				e.wind = _wind(e, frame, to_frame, _head_world(e).origin)
				e.reset = false
			_native.call("Steer", e.id, e.want, frame, e.wind, _double_hair(e))
			e.tier = e.want  # what it is heading for: the tiers' hysteresis reads it (the native side eases there)
	_native.call("Tune", PackedFloat64Array([damping, drag, shape_root, shape_tip, gravity_scale, margin, iterations]))
	_native.call("TuneSwing", swing_stiffness, swing_damping, fixed_length)
	_native.call("Frame", delta)


## Hand avatar [param e] to HairMotionNative: its skeleton, meshes, capsules, beard and simulated strands.
func _register(e: Entry) -> void:
	e.dirty = false
	var bones := PackedInt32Array()
	var a := PackedVector3Array()
	var b := PackedVector3Array()
	var r := PackedFloat32Array()
	for c: Array in e.colliders:
		bones.append(c[0])
		a.append(c[1])
		b.append(c[2])
		r.append(c[3])
	var m: HairMotionBinding = e.binding
	_native.call("Track", e.id, e.skeleton, e.hair, e.head, e.head_bone, bones, a, b, r, e.beard_length,
			m.sim_rest if m != null else PackedVector3Array(), m.sim_free if m != null else PackedFloat32Array(),
			m.sim_length if m != null else PackedFloat32Array())
	_tier_clock = TIER_INTERVAL  # steer it at once


## The texture rows in use (the hair bench reads them back).
func rows() -> Array[int]:
	var out: Array[int] = []
	for e in _entries:
		var row: int = _native.call("RowOf", e.id) if _native != null else e.row
		if row != -1:
			out.append(row)
	return out


func _drop_gone() -> void:
	for i in range(_entries.size() - 1, -1, -1):
		var e: Entry = _entries[i]
		var look: Object = e.look.get_ref()
		if look == null or not (look as Node).is_inside_tree() or not is_instance_valid(e.hair) and not is_instance_valid(e.head):
			_release(e)
			if _native != null:
				_native.call("Untrack", e.id)
			_entries.remove_at(i)


## Each avatar's tier by its distance to its camera: the nearest simulated, up to MAX_SIM (C# only).
func _choose_tiers() -> void:
	var near: Array = []  # [distance, entry]
	for e in _entries:
		e.want = Tier.STILL
		e.frame = Planet.of(e.skeleton) if e.skeleton != null else null
		var at: Vector3 = _head_world(e).origin
		var camera: Camera3D = e.skeleton.get_viewport().get_camera_3d() if e.skeleton != null else null
		if camera == null or _collapsed(e):
			continue
		var d: float = camera.global_position.distance_to(at)
		if d < SWING_FAR:
			e.want = Tier.SWING
		var limit: float = SIM_FAR if e.tier == Tier.SIM else SIM_NEAR
		if d < limit and e.binding != null and _native != null and is_instance_valid(e.hair):
			near.append([d, e])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in mini(near.size(), MAX_SIM):
		(near[i][1] as Entry).want = Tier.SIM


func _move(e: Entry, delta: float, read_wind: bool, inputs: PackedFloat64Array) -> void:
	if e.skeleton == null or e.head_bone == -1:
		return
	# Still and settled (far, or out of sight): nothing to do until its tier changes.
	if e.tier == Tier.STILL and e.want == Tier.STILL:
		if not e.still_set:
			if is_instance_valid(e.head) and e.beard_length > 0.0:
				e.head.set_instance_shader_parameter(&"hair_motion", Vector4.ZERO)
			if is_instance_valid(e.hair) and e.binding != null:
				_set_hair_motion(e, Vector4.ZERO)
			e.still_set = true
		e.has_last = false
		return
	e.still_set = false
	var frame: Node3D = e.frame if is_instance_valid(e.frame) else null
	var to_frame: Transform3D = frame.global_transform.affine_inverse() if frame != null else Transform3D.IDENTITY
	var head_world: Transform3D = _head_world(e)
	var head: Transform3D = to_frame * head_world
	if read_wind or e.reset:
		e.wind = _wind(e, frame, to_frame, head_world.origin)
	# The head's speed and acceleration, in the frame (a planet's spin is not the head's motion).
	var accel := Vector3.ZERO
	if e.has_last and delta > 0.0:
		var speed: Vector3 = (head.origin - e.last) / delta
		if (head.origin - e.last).length() > 1.0:  # a jump: a teleport, a reparent
			speed = Vector3.ZERO
			e.reset = true
		e.accel = e.accel.lerp((speed - e.speed) / delta, ACCEL_SMOOTHING)
		accel = e.accel
		e.speed = speed
	e.last = head.origin
	e.has_last = true
	# Easing between tiers: out of the one left, then into the one wanted.
	var step: float = delta / FADE_S
	if e.want != e.tier:
		e.amount = maxf(e.amount - step, 0.0)
		if e.amount <= 0.0:
			_release(e)
			e.tier = e.want
			if e.tier == Tier.SIM and not _rows_free.is_empty():
				e.row = _rows_free.pop_front()
				_native.call("SetAvatar", e.row, e.binding.sim_rest, e.binding.sim_free, e.binding.sim_length, fixed_length)
				e.reset = true
			elif e.tier == Tier.SIM:
				e.tier = Tier.SWING
	else:
		e.amount = minf(e.amount + step, 1.0)
	var down: Vector3 = to_frame.basis * (-e.skeleton.global_basis.y.normalized()) * GRAVITY
	# The swing as one (the beard always; the hair when not simulated): a damped spring the head drags along.
	var force: Vector3 = (-accel + (e.wind - e.speed) * SWING_AIR) * SWING_LEVER
	e.swing_speed += (force - e.swing * swing_stiffness - e.swing_speed * swing_damping) * delta
	e.swing += e.swing_speed * delta
	if e.swing.length() > MAX_SWING:
		e.swing = e.swing.limit_length(MAX_SWING)
		e.swing_speed *= 0.5
	if e.reset and e.tier != Tier.SIM:
		e.swing = Vector3.ZERO
		e.swing_speed = Vector3.ZERO
	var shown: Vector3 = e.swing * (e.amount if e.tier != Tier.STILL else 0.0)
	if is_instance_valid(e.head) and e.beard_length > 0.0:
		var beard: Vector3 = e.head.global_basis.inverse() * (_frame_basis(frame) * shown)
		e.head.set_instance_shader_parameter(&"hair_motion", Vector4(beard.x, beard.y, beard.z, e.beard_length))
	if not is_instance_valid(e.hair) or e.binding == null:
		e.reset = false
		return
	if e.tier == Tier.SIM:
		_set_hair_motion(e, Vector4(e.row + 1, 0.0, 0.0, 0.0))
		_inputs(e, inputs, to_frame, down, head_world)
	elif e.tier == Tier.SWING:
		var mesh: Vector3 = (to_frame * head_world * e.hair.transform).basis.inverse() * shown
		_set_hair_motion(e, Vector4(0.0, mesh.x, mesh.y, mesh.z))
	else:
		_set_hair_motion(e, Vector4.ZERO)
	e.reset = false


## The simulated avatar's line of Step's inputs (HairMotionNative.Step).
func _inputs(e: Entry, inputs: PackedFloat64Array, to_frame: Transform3D, down: Vector3, head_world: Transform3D) -> void:
	var to_parent: Transform3D = to_frame * head_world * e.hair.transform
	inputs.append_array([e.row, 1.0 if e.reset else 0.0, e.amount])
	for axis in [to_parent.basis.x, to_parent.basis.y, to_parent.basis.z, to_parent.origin]:
		inputs.append_array([axis.x, axis.y, axis.z])
	inputs.append_array([down.x, down.y, down.z, e.wind.x, e.wind.y, e.wind.z, float(e.colliders.size())])
	var skeleton_to_frame: Transform3D = to_frame * e.skeleton.global_transform
	for c: Array in e.colliders:
		var pose: Transform3D = skeleton_to_frame * e.skeleton.get_bone_global_pose(c[0])
		var a: Vector3 = pose * (c[1] as Vector3)
		var b: Vector3 = pose * (c[2] as Vector3)
		inputs.append_array([a.x, a.y, a.z, b.x, b.y, b.z, c[3]])


## The air going past the avatar (frame space): its planet's wind, none in a seat (a cab) or on no planet but the
## breeze (gusting).
func _wind(e: Entry, frame: Node3D, to_frame: Transform3D, at: Vector3) -> Vector3:
	var node: Node = e.skeleton
	while node != null:
		if "seated_role" in node and String(node.get("seated_role")) != "":
			return Vector3.ZERO
		node = node.get_parent()
	if frame is Planet:
		return to_frame.basis * (frame as Planet).wind_world_at(at)
	var g: float = 1.0 + gust * (0.6 * sin(_time * 1.3) + 0.4 * sin(_time * 3.7 + 1.0))
	return to_frame.basis * breeze * maxf(g, 0.0)


## The Head bone's world transform without its scale (first person shrinks the head to hide it: the hair's motion is
## its true size's -- a mirror's double shows it).
func _head_world(e: Entry) -> Transform3D:
	var pose: Transform3D = e.skeleton.get_bone_global_pose(e.head_bone)
	pose.basis = pose.basis.orthonormalized()
	return e.skeleton.global_transform * pose


func _frame_basis(frame: Node3D) -> Basis:
	return frame.global_basis if frame != null else Basis.IDENTITY


## Whether the avatar's head is shrunk (first person) and no mirror shows it.
func _collapsed(e: Entry) -> bool:
	var scaled: bool = e.skeleton.get_bone_global_pose(e.head_bone).basis.get_scale().x < 0.01
	return scaled and _double_hair(e) == null


## The local player's mirror double's copy of the hair, if any (MirrorDouble).
func _double_hair(e: Entry) -> MeshInstance3D:
	var double: Node = e.skeleton.get_parent().get_node_or_null(NodePath(MirrorDouble.NODE_NAME)) if e.skeleton != null else null
	if double == null:
		return null
	return double.get_node_or_null(NodePath("%s/%s" % [HumanAppearance.HAIR_ATTACHMENT_NAME, HumanAppearance.HAIR_NODE_NAME]))


## The avatar's hair_motion on its hair, and on its mirror double's copy.
func _set_hair_motion(e: Entry, value: Vector4) -> void:
	if value == e.hair_value:
		return
	e.hair_value = value
	e.hair.set_instance_shader_parameter(&"hair_motion", value)
	var double: MeshInstance3D = _double_hair(e)
	if double != null:
		double.set_instance_shader_parameter(&"hair_motion", value)


## Give back the avatar's texture row (it leaves the simulated tier).
func _release(e: Entry) -> void:
	if e.row != -1:
		if _native != null:
			_native.call("RemoveAvatar", e.row)
		_rows_free.append(e.row)
		e.row = -1
