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

func _process(_delta: float) -> void:
	if pitch_source == null:
		return
	# Pitch the whole mount around the body's right axis so the held item aims
	# where the camera looks; yaw comes for free from the body (our parent).
	basis = Basis(Vector3(1, 0, 0), pitch_source.rotation.x) * _rest_basis
