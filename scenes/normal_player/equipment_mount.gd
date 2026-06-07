class_name EquipmentMount
extends Node3D

## Generic hand mount for the player's currently held equipment (tool, weapon,
## carried hand object...). Attach one to the player body at the hand offset;
## any item parented under it inherits the body yaw (it is a child of the body)
## and gets the camera pitch applied here. Centralizing the aiming in one place
## means every present and future piece of equipment is oriented the same way,
## for the local player and -- once the camera pitch is replicated -- for remote
## players too, without touching the items themselves (open/closed principle).

## Node whose local X rotation (pitch) the held item must follow, typically the
## player's CameraPivot. Injected so the mount stays decoupled from the player.
@export var pitch_source: Node3D

## When set (a global Vector3 point), the mount aims the held item's forward at
## it (look_at) instead of pitching by pitch_source. Used to make a tool/weapon
## point EXACTLY where the player targets, so its action acts at that point.
var aim_target = null   # Variant: Vector3 or null
var aim_up: Vector3 = Vector3.UP
## Roll correction (deg) around the aim axis, to keep the held item upright in
## aim mode (compensates for the model's native orientation).
var aim_roll_deg: float = 0.0
## Aim-point smoothing speed (higher = snappier; smooths the depth jump when the
## crosshair moves from empty space to a near surface).
var aim_smooth: float = 18.0
## When false, the mount ignores pitch_source and keeps its rest orientation (a stowed
## item that must NOT follow the camera). Aim mode (aim_target) still overrides this.
var follow_pitch: bool = true
var _smoothed_aim: Vector3 = Vector3.ZERO
var _aim_init: bool = false

var _rest_basis: Basis = Basis.IDENTITY
var _item: Node3D = null

func _ready() -> void:
	# Rest orientation captured once; the camera pitch is applied on top of it.
	_rest_basis = transform.basis

## Attach (and own) an item under the mount, replacing any previous one.
func hold(item: Node3D) -> void:
	clear()
	_item = item
	add_child(item)

## The item currently held, or null.
func held_item() -> Node3D:
	return _item

## Remove and free the held item, if any.
func clear() -> void:
	if _item != null and is_instance_valid(_item):
		_item.queue_free()
	_item = null

func _process(delta: float) -> void:
	# Aim mode: point the held item's forward (its base rotation aligns its tip
	# with our -Z) at a world target, e.g. the point under the crosshair.
	if aim_target != null:
		# Smooth the aim point to avoid a snap when the target depth changes
		# (empty space -> near surface).
		if _aim_init:
			_smoothed_aim = _smoothed_aim.lerp(aim_target, clampf(aim_smooth * delta, 0.0, 1.0))
		else:
			_smoothed_aim = aim_target
			_aim_init = true
		if not global_position.is_equal_approx(_smoothed_aim):
			look_at(_smoothed_aim, aim_up)
			if aim_roll_deg != 0.0:
				rotate_object_local(Vector3(0, 0, 1), deg_to_rad(aim_roll_deg))
		return
	_aim_init = false
	if not follow_pitch:
		basis = _rest_basis   # stowed: fixed orientation, no camera influence (#124)
		return
	if pitch_source == null:
		return
	# Pitch the whole mount around the body's right axis so the held item aims
	# where the camera looks; yaw comes for free from the body (our parent).
	basis = Basis(Vector3(1, 0, 0), pitch_source.rotation.x) * _rest_basis
