class_name LayoutFences
extends RefCounted
## The fences drawn inside a village or city layout (VillageFence), read from the scene without adding
## it to the tree and remembered per scene (LayoutData), as LayoutRoads reads the roads; the pure
## geometry of one fence (panels between posts, the posts, the collision faces); and the node that
## carries a village's fences once PlanetTerrain has sampled their feet on the village's ground — the
## same on the server and on every client.

## Half the width of a post's square section (m).
const POST_HALF_M := 0.05
## Size of one tile of the panel's texture (m), along and up: the cargo depot's triplanar wire mesh
## repeats once a metre, so the fences match it.
const TILE_M := 1.0
## Thickness of a panel's collision box (m): thin, but a volume — a single face let bodies through.
const PANEL_THICKNESS_M := 0.1

## [{points: PackedVector2Array (x, z in the layout, one per post), height, panel_material,
## post_material}] of the layout [param scene_path] (res:// or not); [] when it draws no fence.
static func of(scene_path: String) -> Array:
	return LayoutData.of(scene_path)["fences"]


## The fences of an instantiated [param layout] (not in the tree), as [method of] returns them.
static func of_layout(layout: Node) -> Array:
	var out: Array = []
	for n: Node in layout.find_children("*", "VillageFence", true, false):
		var fence := n as VillageFence
		var pts := fence.polyline_in(layout, fence.post_spacing_m)
		if pts.size() >= 2:
			out.append({"points": pts, "height": fence.height_m,
					"panel_material": on_panel_uv(fence.panel_material), "post_material": fence.post_material})
	return out


## Material → its non-triplanar copy ([method on_panel_uv]), made once per material.
static var _panel_uv_copies: Dictionary = {}


## [param mat] as the panels need it: mapped on their own UVs. A triplanar material (the cargo
## depot's wire mesh) projects along the axes of the node it is drawn by — a fence's frame is the
## planet's, tilted however the globe turns there — and drew the mesh diagonally whatever the UVs
## said; such a material is given a copy that is not triplanar (one per material).
static func on_panel_uv(mat: Material) -> Material:
	var base := mat as BaseMaterial3D
	if base == null or not base.uv1_triplanar:
		return mat
	if not _panel_uv_copies.has(base):
		var copy := base.duplicate() as BaseMaterial3D
		copy.uv1_triplanar = false
		copy.uv1_world_triplanar = false
		copy.uv1_offset = Vector3.ZERO
		_panel_uv_copies[base] = copy
	return _panel_uv_copies[base]


## The geometry of one fence whose posts stand at [param feet] (their feet, in the frame the fence is
## built in) with their local up [param ups]; panel k runs from post k to post k + 1 and is left out
## where [param open] is true (a road crosses there). [param height] in metres.
## Returns {panels: Array (Mesh.ARRAY_MAX arrays), posts: Array, boxes: Array of [Transform3D, Vector3
## size] (one collision box per panel)}; a set of arrays is empty (`[]`) when it has nothing to draw.
static func build(feet: PackedVector3Array, ups: PackedVector3Array, open: Array, height: float) -> Dictionary:
	var pv := PackedVector3Array()
	var pn := PackedVector3Array()
	var puv := PackedVector2Array()
	var pi := PackedInt32Array()
	var pt := PackedFloat32Array()
	var boxes: Array = []
	# The texture hangs plumb: U runs along the HORIZONTAL distance and V down from a level line, so
	# its bars stay level and its posts upright while the panel follows a sloping ground (its sloping
	# edges just cut the pattern). Taken along the panel's own edges, the wire mesh leaned with the slope.
	var along := 0.0  # horizontal metres from the first post
	var rise := 0.0  # height of post k's foot above the first one's (m)
	for k in feet.size() - 1:
		var a := feet[k]
		var b := feet[k + 1]
		var seg := a.distance_to(b)
		var up := (ups[k] + ups[k + 1]).normalized()
		var step_up := (b - a).dot(up)
		var flat := ((b - a) - up * step_up).length()
		if not bool(open[k]) and seg > 0.01:
			var ta := a + ups[k] * height
			var tb := b + ups[k + 1] * height
			var x_dir := (b - a) / seg
			var h_dir := ((b - a) - up * step_up).normalized() if flat > 1e-6 else x_dir
			var n := h_dir.cross(up).normalized()
			var base := pv.size()
			pv.append_array(PackedVector3Array([a, b, tb, ta]))
			pn.append_array(PackedVector3Array([n, n, n, n]))
			var u0 := along / TILE_M
			var u1 := (along + flat) / TILE_M
			var z_a := rise
			var z_b := rise + step_up
			puv.append_array(PackedVector2Array([Vector2(u0, -z_a / TILE_M), Vector2(u1, -z_b / TILE_M),
					Vector2(u1, -(z_b + height) / TILE_M), Vector2(u0, -(z_a + height) / TILE_M)]))
			pi.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
			for _v in 4:
				# Tangent along U (horizontal); binormal = normal x tangent * w points up, V grows down: w = -1.
				pt.append_array(PackedFloat32Array([h_dir.x, h_dir.y, h_dir.z, -1.0]))
			var y_dir := (up - x_dir * up.dot(x_dir)).normalized()
			var basis := Basis(x_dir, y_dir, x_dir.cross(y_dir).normalized())
			boxes.append([Transform3D(basis, (a + b) * 0.5 + y_dir * height * 0.5),
					Vector3(seg, height, PANEL_THICKNESS_M)])
		along += flat
		rise += step_up
	var qv := PackedVector3Array()
	var qn := PackedVector3Array()
	var qi := PackedInt32Array()
	var qt := PackedFloat32Array()
	for k in feet.size():
		# A post stands where a panel does, at either end of it.
		var used := (k > 0 and not bool(open[k - 1])) or (k < feet.size() - 1 and not bool(open[k]))
		if not used:
			continue
		var dir := (feet[mini(k + 1, feet.size() - 1)] - feet[maxi(k - 1, 0)])
		dir = (dir - ups[k] * dir.dot(ups[k])).normalized()
		var side := ups[k].cross(dir).normalized()
		var corners: Array[Vector3] = [dir + side, -dir + side, -dir - side, dir - side]
		for c in 4:
			var c0: Vector3 = corners[c] * POST_HALF_M
			var c1: Vector3 = corners[(c + 1) % 4] * POST_HALF_M
			var normal := (c0 + c1).normalized()
			var base := qv.size()
			qv.append_array(PackedVector3Array([feet[k] + c0, feet[k] + c1,
					feet[k] + c1 + ups[k] * height, feet[k] + c0 + ups[k] * height]))
			qn.append_array(PackedVector3Array([normal, normal, normal, normal]))
			qi.append_array(PackedInt32Array([base, base + 2, base + 1, base, base + 3, base + 2]))
			var tangent := (c1 - c0).normalized()
			for _v in 4:
				qt.append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, 1.0]))
	return {"panels": _arrays(pv, pn, puv, pi, pt), "posts": _arrays(qv, qn, PackedVector2Array(), qi, qt),
			"boxes": boxes}


## The panels (or posts) of [param geo] ([method build]) as one ArrayMesh, each part with its
## material: [param panel_material] (already mapped on the panels' UVs, [method on_panel_uv]) and
## [param post_material]. A part with nothing to draw adds no surface.
static func mesh_of(geo: Dictionary, panel_material: Material, post_material: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not (geo["panels"] as Array).is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, geo["panels"])
		mesh.surface_set_material(mesh.get_surface_count() - 1, panel_material)
	if not (geo["posts"] as Array).is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, geo["posts"])
		mesh.surface_set_material(mesh.get_surface_count() - 1, post_material)
	return mesh


## The node carrying the fences [param laid], placed at [param origin]: one MeshInstance3D a fence and
## one StaticBody3D with a box a panel (it collides, it does not detect: mask 0). [param laid] is
## [{fence: an entry of [method of], feet: PackedVector3Array (the posts' feet, in the frame
## [param origin] is given in), ups: PackedVector3Array (their local up), open: Array (bool a panel,
## see [method build])}]: the caller samples the ground, this builds what stands on it.
static func build_node(node_name: String, origin: Vector3, laid: Array) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	node.position = origin
	var body := StaticBody3D.new()
	body.collision_mask = 0
	for entry: Dictionary in laid:
		var f: Dictionary = entry["fence"]
		var local := PackedVector3Array()
		for foot: Vector3 in (entry["feet"] as PackedVector3Array):
			local.append(foot - origin)
		var geo := build(local, entry["ups"], entry["open"], float(f["height"]))
		var mesh := mesh_of(geo, f["panel_material"], f["post_material"])
		if mesh.get_surface_count() > 0:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			node.add_child(mi)
		for box: Array in geo["boxes"]:
			var shape := BoxShape3D.new()
			shape.size = box[1]
			var cs := CollisionShape3D.new()
			cs.shape = shape
			cs.transform = box[0]
			body.add_child(cs)
	if body.get_child_count() > 0:
		node.add_child(body)
	else:
		body.free()
	return node


## One surface's arrays (Mesh.ARRAY_MAX) from its vertices, normals, UVs (left out when empty),
## indices and tangents; [] when it has no vertex.
static func _arrays(v: PackedVector3Array, n: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array,
		tangents: PackedFloat32Array) -> Array:
	if v.is_empty():
		return []
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TANGENT] = tangents
	if not uv.is_empty():
		arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	return arr
