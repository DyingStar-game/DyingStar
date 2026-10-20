class_name HumanoidHand
extends RefCounted

## A humanoid rig's hand, by the humanoid profile's bone names (LeftIndexProximal...): its fingers'
## chains, and closing them from straight. Shared by the rigs that pose a hand: HandsOnWheel (round the
## rim), ScreenPoke (the index out, the rest in a fist). Also the markers such a rig aims its IK with.

## The four fingers' chains, from the index. The thumb is left as the clip has it.
const FINGERS: Array[String] = ["Index", "Middle", "Ring", "Little"]
## Each finger's joints, knuckle out.
const JOINTS: Array[String] = ["Proximal", "Intermediate", "Distal"]


## The fingers of the [param side] hand ("Left" / "Right"): one Array[int] per finger of FINGERS, its
## joints knuckle out, -1 where the rig has none.
static func finger_chains(skeleton: Skeleton3D, side: String) -> Array:
	var chains: Array = []
	for finger: String in FINGERS:
		var chain: Array[int] = []
		for joint: String in JOINTS:
			chain.append(skeleton.find_bone(side + finger + joint))
		chains.append(chain)
	return chains


## Close each finger of [param chains] by [param degrees] (one Array of angles per finger, a joint each,
## counted from the finger held STRAIGHT -- the rig's rest -- not from the clip) about [param axis], the
## hand's bone being posed at [param hand] (skeleton's space).
static func curl(skeleton: Skeleton3D, hand: Transform3D, chains: Array, degrees: Array, axis: Vector3) -> void:
	for f: int in chains.size():
		var chain: Array = chains[f]
		var angles: Array = degrees[f]
		var parent: Transform3D = hand
		for j in chain.size():
			var bone: int = chain[j]
			if bone == -1:
				break
			var joint: Transform3D = parent * skeleton.get_bone_rest(bone)
			joint.basis = Basis(axis, deg_to_rad(angles[j])) * joint.basis
			skeleton.set_bone_pose_rotation(bone, (parent.basis.inverse() * joint.basis).get_rotation_quaternion())
			parent = joint


## A marker under [param skeleton] (an IK's target or pole): its position is in the skeleton's space.
static func marker(skeleton: Skeleton3D, marker_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = marker_name
	skeleton.add_child(node)
	return node
