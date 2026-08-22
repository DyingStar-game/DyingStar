@tool
extends SceneTree
## Proves the claim RockMining._rebuild_fracture_all now rests on: adding N CSG subtraction boxes
## and baking ONCE gives the same geometry as adding them one per frame with a bake between each.
## Same box maths as RockMining._make_cut_box. Run:
##   godot --headless --script res://tools/perf/csg_batch_check.gd

const MESH_PATH := "res://assets/_universe/environment/terrain/rocks/rock_mining_001.mesh"


func _init() -> void:
	await process_frame
	var mesh: Mesh = load(MESH_PATH)
	var uncut: Dictionary = await _run(mesh, [], false)
	print("uncut : aabb=%s verts=%d" % [uncut.aabb.size, uncut.verts])

	# Swept over the cut count: successive halvings shrink the piece fast, and a replay that carves
	# the rock away entirely would compare "equal" while proving nothing. Only the depths that leave
	# real geometry are asserted on; the sweep shows where that stops.
	var checked := 0
	var all_same := true
	for n in range(1, 7):
		var fracs: Array = _fake_fractures(n, mesh.get_aabb())
		var per_frame: Dictionary = await _run(mesh, fracs, true)
		var batched: Dictionary = await _run(mesh, fracs, false)
		var carved: bool = batched.verts > 0
		var same: bool = per_frame.aabb.size.is_equal_approx(batched.aabb.size) \
				and per_frame.verts == batched.verts
		print("cuts=%d | per-frame %6.1f ms/%d frames verts=%-5d | batched %6.1f ms/%d frame verts=%-5d | %s" % [
			n, per_frame.ms, per_frame.frames, per_frame.verts,
			batched.ms, batched.frames, batched.verts,
			("same" if same else "DIFFERENT") if carved else "(empty - not asserted)"])
		if carved:
			checked += 1
			all_same = all_same and same
	print("IDENTICAL GEOMETRY: %s (%d cut depths asserted)" % [all_same and checked > 0, checked])
	quit(0 if (all_same and checked > 0) else 1)


## One replay. `per_frame` true reproduces the old behaviour (a bake between every box).
func _run(mesh: Mesh, fracs: Array, per_frame: bool) -> Dictionary:
	var holder := Node3D.new()
	root.add_child(holder)
	var csg := CSGMesh3D.new()
	csg.mesh = mesh
	holder.add_child(csg)
	await process_frame

	var t0 := Time.get_ticks_usec()
	var frames := 0
	for frac in fracs:
		csg.add_child(_make_cut_box(frac, mesh.get_aabb()))
		if per_frame:
			await process_frame
			frames += 1
	await process_frame
	frames += 1
	var ms := (Time.get_ticks_usec() - t0) / 1000.0

	var verts := 0
	var baked: Array = csg.get_meshes()
	if baked.size() > 1 and baked[1] is Mesh:
		for i in (baked[1] as Mesh).get_surface_count():
			verts += (baked[1] as Mesh).surface_get_arrays(i)[Mesh.ARRAY_VERTEX].size()
	var out := {"aabb": csg.get_aabb(), "verts": verts, "ms": ms, "frames": frames}
	holder.queue_free()
	await process_frame
	return out


## Verbatim copy of RockMining._make_cut_box, so the check exercises the real box placement.
func _make_cut_box(frac: Dictionary, aabbBox: AABB) -> CSGBox3D:
	var box := CSGBox3D.new()
	box.size = Vector3(2.0 * aabbBox.size.x, 2.0 * aabbBox.size.y, 2.0 * aabbBox.size.z)
	box.rotation = Vector3(
		deg_to_rad(frac["rotation_x"]), deg_to_rad(frac["rotation_y"]), deg_to_rad(frac["rotation_z"]))
	var offset: float = frac["plane_offset"]
	var box_x: float = (offset - aabbBox.size.x) if int(frac["keep_side"]) == 1 else (offset + aabbBox.size.x)
	box.translate_object_local(Vector3(box_x, 0.0, 0.0))
	box.operation = CSGShape3D.OPERATION_SUBTRACTION
	return box


## Planes shaped like the ones _compute_fracture_plane emits: each one perpendicular to the longest
## axis of what is LEFT of the piece, cutting through its centre, keeping the +normal half. Axis
## aligned so the shrinking box can be tracked exactly — the point of the check is commutativity,
## not plane variety, and planes that consume the whole rock make the comparison vacuous.
func _fake_fractures(n: int, box: AABB) -> Array:
	# rotation -> the normal Basis.from_euler(rot) * X produces: +X, +Y, +Z.
	var axis_rot: Array[Vector3] = [Vector3.ZERO, Vector3(0, 0, 90), Vector3(0, -90, 0)]
	var out: Array = []
	var remaining: AABB = box
	for _i in n:
		var size: Vector3 = remaining.size
		var axis: int = 0
		if size.y > size.x and size.y >= size.z:
			axis = 1
		elif size.z > size.x and size.z > size.y:
			axis = 2
		var offset: float = remaining.position[axis] + size[axis] * 0.5
		var rot: Vector3 = axis_rot[axis]
		out.append({
			"rotation_x": rot.x, "rotation_y": rot.y, "rotation_z": rot.z,
			"plane_offset": offset,
			"keep_side": 1,
		})
		# keep_side 1 keeps the +normal half, so the piece starts at the plane from now on.
		remaining.position[axis] = offset
		remaining.size[axis] = size[axis] * 0.5
	return out
