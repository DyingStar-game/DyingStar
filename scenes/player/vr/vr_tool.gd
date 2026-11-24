class_name VrTool
extends Node
## The mining tool in the hand, in VR. On the flat screen the perforator hangs at a fixed place on the
## body and tilts with the camera; in a headset it is held by the hand that aims (Settings > General >
## VR comfort): it goes where the hand goes, and it mines where the hand points (VrPointer aims the
## tool's rock ray like the interaction ray). Stowed on the belt, or while the runtime does not see the
## hand, the tool keeps the game's own pose.
##
## The others see it as before: the server knows the body and the head, not the hands (phase 6).
##
## Built by VrRig.hold_tool for the owner's player, in VR only.

## Where the tool's grip sits from the hand's aim pose (m, the aim pose's frame: the aim pose is at the
## front of the controller, the palm a little behind and under it).
const GRIP_FROM_AIM := Vector3(0.0, -0.02, 0.08)

var _tool: MiningTool = null
var _pointer: VrPointer = null


## Hold [param tool] in the hand [param pointer] aims with.
func setup(tool: MiningTool, pointer: VrPointer) -> void:
	_tool = tool
	_pointer = pointer
	pointer.follow(tool.rock_ray())
	# After the tool and its mount have placed themselves this frame: the hand has the last word.
	process_priority = 100


func _process(_delta: float) -> void:
	if not is_instance_valid(_tool) or not is_instance_valid(_pointer) or not _tool.in_hand():
		return
	var hand: XRController3D = _pointer.aiming_hand()
	var mount: Node3D = _tool.equipment_mount()
	if hand == null or mount == null:
		return
	mount.global_transform = held_at(hand.global_transform)


## The mount's place for a hand whose aim pose is [param aim].
static func held_at(aim: Transform3D) -> Transform3D:
	return aim * Transform3D(Basis(), GRIP_FROM_AIM)
