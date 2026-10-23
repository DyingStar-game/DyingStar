class_name HatchNumbers
extends RefCounted
## The number of each component bay, painted on the hatch that guards it: the same number the dashboard
## shows beside the bay's box (VehicleDashboard), the n-th bay of VehicleComponentBays.all() -- so a part
## goes where it is read. A Label3D child of the hatch's mesh, so it swings with the hatch; on its outer
## face, upright, its size undone from the mesh's own (non-uniform) scale.

## The label's node name under the hatch's mesh.
const NAME := "HatchNumber"
## Height of the figures (m).
const HEIGHT_M := 0.11
## Font size the label is drawn at; its pixel size scales it to HEIGHT_M.
const FONT_SIZE := 64
## Stencilled in the colour of the truck's own plate.
const COLOUR := Color(0.08, 0.08, 0.1, 1.0)
## How far (m) off the hatch's face the figures float, so they never sink into it.
const LIFT_M := 0.003


## Paint each bay's number ([param slots], VehicleComponentSlot, in bay order) on the mesh of the hatch
## that guards it, found by [param mesh_of] (door_id -> its MeshInstance3D, or null) on [param vehicle].
## A bay with no hatch, or a hatch already numbered, is left alone.
static func paint(vehicle: Node3D, slots: Array, mesh_of: Callable) -> void:
	for i in slots.size():
		var door_id: String = str(slots[i].door_id)
		if door_id == "":
			continue
		var hatch := mesh_of.call(door_id) as MeshInstance3D
		if hatch == null or hatch.mesh == null or hatch.has_node(NAME):
			continue
		var label := Label3D.new()
		label.name = NAME
		label.text = str(i + 1)
		label.font_size = FONT_SIZE
		label.pixel_size = HEIGHT_M / FONT_SIZE
		label.modulate = COLOUR
		label.outline_size = 0
		label.double_sided = false
		label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		label.transform = placement(LocalFrame.of(hatch, vehicle), hatch.mesh.get_aabb())
		hatch.add_child(label)


## Where a hatch's number goes, in the hatch mesh's own frame, the mesh being at [param in_vehicle] in
## the vehicle's frame and [param aabb] its own box: in the middle of its outer face -- the face of its
## thinnest side that looks away from the vehicle's middle -- facing out, upright (the vehicle's up), at
## unit scale whatever the mesh's. Pure, for the tests.
static func placement(in_vehicle: Transform3D, aabb: AABB) -> Transform3D:
	var scale: Vector3 = in_vehicle.basis.get_scale()
	var sized: Vector3 = aabb.size * scale
	var thin: int = 0
	for k in 3:
		if sized[k] < sized[thin]:
			thin = k
	var axes: Array[Vector3] = [in_vehicle.basis.x, in_vehicle.basis.y, in_vehicle.basis.z]
	var axis: Vector3 = axes[thin].normalized()
	var centre: Vector3 = in_vehicle * aabb.get_center()
	var away: float = 1.0 if axis.dot(Vector3(centre.x, 0.0, centre.z)) >= 0.0 else -1.0
	var at: Vector3 = aabb.get_center()
	at[thin] = (aabb.end[thin] if away > 0.0 else aabb.position[thin]) + away * LIFT_M / scale[thin]
	# A Label3D reads from its +Z: +Z out of the face, +Y the vehicle's up.
	var out: Vector3 = axis * away
	var right: Vector3 = Vector3.UP.cross(out).normalized()
	var facing := Basis(right, out.cross(right), out)
	return Transform3D(in_vehicle.basis.inverse() * facing, at)
