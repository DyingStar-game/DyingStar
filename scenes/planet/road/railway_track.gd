@tool
class_name RailwayTrack
## Lays the rail modules (assets/_universe/structures/urban/railroad_01.glb)
## along a chunk's stretch of track, and the boxes that stand in for their
## collision.
##
## The GLB holds HALF a track — half a sleeper with one rail, 1.12 m long —
## so a track is two instances, the second turned 180° about the up axis
## (never a negative scale: that flips the winding and the culling). Modules
## are laid end to end on ABSOLUTE along-metres, so the two chunks sharing a
## border place their last and first module on the same pitch and nobody
## draws one twice ([method GradeGeom.module_range]).
##
## Rendering: one MultiMesh per RAIL_MMI_GROUP_M of track rather than one per
## chunk, because the importer's automatic mesh LOD is picked PER NODE from
## its distance — one node per 433 m chunk would draw every module of the
## chunk the player stands in at LOD 0.
##
## Collision: not the 36 000-triangle module, a box per track per straight
## run, the size of the module's outer bounds (sleeper width × rail-head
## height), see [method collision_boxes].

## Preloaded, not the autoload: this script is @tool and runs in the editor
## preview too, where autoloads are not registered (see BridgeSpawner).
const GlobalsDefs := preload("res://scenes/globals/globals.gd")

static var _meshes: Array[Mesh] = []
static var _meshes_loaded := false
static var _mesh_mutex: Mutex = Mutex.new()


## The module meshes by LOD tier (index 0 = finest). Loaded once.
##
## Nodes named `*lod0`, `*lod1`… are taken as tiers (the tree001.glb
## convention); a GLB with a single mesh yields one tier. When the mesh node
## carries a transform (the current GLB has an unapplied non-uniform scale)
## the arrays are rebuilt with it applied — which loses the importer's
## automatic LODs, hence the warning: apply the scale in Blender to keep them.
static func module_meshes() -> Array[Mesh]:
	if _meshes_loaded:
		return _meshes
	_mesh_mutex.lock()
	if not _meshes_loaded:
		_load_meshes()
		_meshes_loaded = true
	_mesh_mutex.unlock()
	return _meshes


static func _load_meshes() -> void:
	_meshes.clear()
	var scene := load(RailwaySettings.MODULE_PATH) as PackedScene
	if scene == null:
		push_warning("[RailwayTrack] rail module not found: %s" % RailwaySettings.MODULE_PATH)
		return
	var instance := scene.instantiate()
	var lod_nodes: Array[MeshInstance3D] = []
	for child in instance.find_children("*", "MeshInstance3D", true):
		var mi := child as MeshInstance3D
		if mi and mi.mesh and mi.name.to_lower().contains("lod"):
			lod_nodes.append(mi)
	lod_nodes.sort_custom(func(a, b): return a.name.naturalcasecmp_to(b.name) < 0)
	if lod_nodes.is_empty():
		for child in instance.find_children("*", "MeshInstance3D", true):
			var mi := child as MeshInstance3D
			if mi and mi.mesh:
				lod_nodes.append(mi)
				break
	for mi in lod_nodes:
		var xf: Transform3D = _transform_in_scene(mi, instance)
		var mesh: Mesh
		if xf.is_equal_approx(Transform3D.IDENTITY):
			mesh = mi.mesh
		else:
			push_warning("[RailwayTrack] '%s' carries an unapplied transform (scale %s): "
					% [mi.name, xf.basis.get_scale()]
					+ "rebuilding its arrays, which drops the imported mesh LODs. "
					+ "Apply the transform in Blender to keep them.")
			mesh = _baked_mesh(mi.mesh, xf)
		if mesh:
			_meshes.append(mesh)
	instance.free()
	if _meshes.is_empty():
		push_warning("[RailwayTrack] no mesh in %s" % RailwaySettings.MODULE_PATH)
		return
	var aabb := _meshes[0].get_aabb()
	var expect := AABB(Vector3(0.0, -RailwaySettings.MODULE_BELOW_M, -0.5 * RailwaySettings.MODULE_LEN_M),
			Vector3(RailwaySettings.MODULE_HALF_W_M, RailwaySettings.MODULE_H_M,
					RailwaySettings.MODULE_LEN_M))
	if aabb.position.distance_to(expect.position) > 0.05 \
			or aabb.size.distance_to(expect.size) > 0.05:
		push_warning("[RailwayTrack] rail module bounds %s differ from the expected %s — "
				% [aabb, expect]
				+ "RailwaySettings' module constants no longer describe the asset.")


static func _transform_in_scene(node: Node3D, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## [param mesh] with [param xf] baked into its vertices, normals (inverse
## transpose) and tangents; surfaces and materials kept as they are.
static func _baked_mesh(mesh: Mesh, xf: Transform3D) -> ArrayMesh:
	var out := ArrayMesh.new()
	var nrm_basis := xf.basis.inverse().transposed()
	for si in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(si)
		if arrays.is_empty():
			continue
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i] = xf * v[i]
		arrays[Mesh.ARRAY_VERTEX] = v
		if arrays[Mesh.ARRAY_NORMAL] != null:
			var nn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for i in nn.size():
				nn[i] = (nrm_basis * nn[i]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = nn
		if arrays[Mesh.ARRAY_TANGENT] != null:
			var tg: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
			var i := 0
			while i + 3 < tg.size():
				var t := (xf.basis * Vector3(tg[i], tg[i + 1], tg[i + 2])).normalized()
				tg[i] = t.x; tg[i + 1] = t.y; tg[i + 2] = t.z
				i += 4
			arrays[Mesh.ARRAY_TANGENT] = tg
		out.add_surface_from_arrays(mesh.surface_get_primitive_type(si), arrays)
		var mat := mesh.surface_get_material(si)
		if mat:
			out.surface_set_material(out.get_surface_count() - 1, mat)
	return out


## Railway pieces of chunk (nside, ipix) that have a profile, as
## [[record, profile], …].
static func _pieces_with_profile(planet_data: PlanetData, nside: int, ipix: int) -> Array:
	var out: Array = []
	if not planet_data.has_railways():
		return out
	# Rails only on railways: a graded road shares the bed builders, not these.
	for r in planet_data.get_roads_for_chunk(nside, ipix):
		if not RailwaySettings.is_railway(r):
			continue
		var prof: Dictionary = planet_data.get_grade_profile(int(r.get("feature_id", -1)))
		if not prof.is_empty():
			out.append([r, prof])
	return out


## Every module half of the chunk, as {xform (relative to [param chunk_center]),
## along, track}. Deterministic: the same on the client and on the server.
static func module_transforms(planet_data: PlanetData, nside: int, ipix: int,
		chunk_center: Vector3) -> Array:
	var out: Array = []
	for pair in _pieces_with_profile(planet_data, nside, ipix):
		out.append_array(piece_module_transforms(pair[0], pair[1],
				planet_data.radius, chunk_center))
	return out


## [method module_transforms] for one piece [param r] of a railway with
## [param prof].
static func piece_module_transforms(r: Dictionary, prof: Dictionary, radius: float,
		chunk_center: Vector3) -> Array:
	var out: Array = []
	var L := RailwaySettings.MODULE_LEN_M
	var cl: PackedVector2Array = r.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = r.get("_cum_lengths", PackedFloat64Array())
	if cl.size() < 2 or cum.size() != cl.size():
		return out
	var tracks := maxi(int(prof.get("tracks", 1)), 1)
	var z_at := func(along: float) -> float:
		return GradeProfile.z_track_at(prof, along)
	var rng := GradeGeom.module_range(cum[0], cum[cum.size() - 1], L)
	for i in range(rng.x, rng.y):
		var s := (float(i) + 0.5) * L
		var f := GradeGeom.frame_at(cl, cum, s, z_at, radius)
		var up: Vector3 = f["up"]
		var t: Vector3 = f["t"]
		var n: Vector3 = f["n"]
		var p: Vector3 = (f["pos"] as Vector3) + up * RoadTerrain.SURFACE_OFFSET - chunk_center
		for k in tracks:
			var c: float = (float(k) - 0.5 * float(tracks - 1)) * RailwaySettings.TRACK_PITCH_M
			var centre := p + n * c
			# Half A: module +X to the left (+n), +Z backwards (-t).
			out.append({"xform": Transform3D(Basis(n, up, -t), centre),
					"along": s, "track": k})
			# Half B: the same module turned 180° about up.
			out.append({"xform": Transform3D(Basis(-n, up, t), centre),
					"along": s, "track": k})
	return out


## One MultiMesh per RAIL_MMI_GROUP_M of track, on the mesh of LOD tier
## [param lod]: [{mm: MultiMesh, center: Vector3 (relative to chunk_center)}].
## Instance transforms are relative to the group's own centre so the node's
## distance — what the mesh LOD is picked from — is the group's.
static func build_multimeshes(transforms: Array, lod: int) -> Array:
	var meshes := module_meshes()
	if meshes.is_empty() or transforms.is_empty():
		return []
	var mesh: Mesh = meshes[clampi(lod, 0, meshes.size() - 1)]
	var groups := {}
	for m in transforms:
		var g := int(floor(float(m["along"]) / RailwaySettings.RAIL_MMI_GROUP_M))
		if not groups.has(g):
			groups[g] = []
		(groups[g] as Array).append(m)
	var out: Array = []
	for g in groups:
		var members: Array = groups[g]
		var centre := Vector3.ZERO
		for m in members:
			centre += (m["xform"] as Transform3D).origin
		centre /= float(members.size())
		centre = PlanetChunk.snap_to_f32(centre)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = members.size()
		for i in members.size():
			var xf: Transform3D = members[i]["xform"]
			mm.set_instance_transform(i, Transform3D(xf.basis, xf.origin - centre))
		out.append({"mm": mm, "center": centre})
	return out


## The collision boxes of the chunk's track: one per track per straight run,
## as [{xform (relative to chunk_center), size}]. A run is a centerline
## segment intersected with a profile knot interval, so the box is exactly
## straight and exactly on grade; the box section is the module's outer
## bounds (TRACK_W_M × MODULE_H_M), its bottom at the sleeper's underside.
static func collision_boxes(planet_data: PlanetData, nside: int, ipix: int,
		chunk_center: Vector3) -> Array:
	var out: Array = []
	for pair in _pieces_with_profile(planet_data, nside, ipix):
		out.append_array(piece_collision_boxes(pair[0], pair[1],
				planet_data.radius, chunk_center))
	return out


## [method collision_boxes] for one piece [param r] of a railway with
## [param prof].
static func piece_collision_boxes(r: Dictionary, prof: Dictionary, radius: float,
		chunk_center: Vector3) -> Array:
	var out: Array = []
	var L := RailwaySettings.MODULE_LEN_M
	var h := RailwaySettings.MODULE_H_M
	var w := RailwaySettings.TRACK_W_M
	var cl: PackedVector2Array = r.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = r.get("_cum_lengths", PackedFloat64Array())
	if cl.size() < 2 or cum.size() != cl.size():
		return out
	var tracks := maxi(int(prof.get("tracks", 1)), 1)
	var z_at := func(along: float) -> float:
		return GradeProfile.z_track_at(prof, along)
	var knots: PackedFloat64Array = prof["knots_along"]
	for i in cl.size() - 1:
		var a0: float = cum[i]
		var a1: float = cum[i + 1]
		if a1 - a0 <= 1e-6:
			continue
		# Split the segment at the knots inside it.
		var cuts := PackedFloat64Array([a0])
		for k in knots:
			if k > a0 + 1e-6 and k < a1 - 1e-6:
				cuts.append(k)
		cuts.append(a1)
		for j in cuts.size() - 1:
			var lo: float = cuts[j]
			var hi: float = cuts[j + 1]
			var mid := 0.5 * (lo + hi)
			var f := GradeGeom.frame_at(cl, cum, mid, z_at, radius,
					0.5 * maxf(hi - lo, L))
			var up: Vector3 = f["up"]
			var t: Vector3 = f["t"]
			var n: Vector3 = f["n"]
			var len_m := maxf(hi - lo, L)
			var base: Vector3 = (f["pos"] as Vector3) - chunk_center \
					+ up * (RoadTerrain.SURFACE_OFFSET - RailwaySettings.MODULE_BELOW_M + 0.5 * h)
			for k in tracks:
				var c: float = (float(k) - 0.5 * float(tracks - 1)) * RailwaySettings.TRACK_PITCH_M
				out.append({"xform": Transform3D(Basis(n, up, -t), base + n * c),
						"size": Vector3(w, h, len_m), "along_lo": lo, "along_hi": hi,
						"track": k})
	return out


## A StaticBody3D holding the boxes of [method collision_boxes], positioned
## at [param chunk_center]; null when the chunk has no track.
static func make_collision_body(planet_data: PlanetData, nside: int, ipix: int,
		chunk_center: Vector3, key: String) -> StaticBody3D:
	var boxes := collision_boxes(planet_data, nside, ipix, chunk_center)
	if boxes.is_empty():
		return null
	var body := StaticBody3D.new()
	body.name = key + "_rails_col"
	body.position = chunk_center
	body.collision_layer = GlobalsDefs.LAYER_WORLD
	body.set_collision_layer_value(GlobalsDefs.LAYER_WORLD, true)
	body.collision_mask = GlobalsDefs.MASK_SOLID
	# Read back by the vehicles, which never look at a PhysicsMaterial.
	body.set_meta("grip_slip", 3.0)
	var pm := PhysicsMaterial.new()
	pm.friction = 1.0
	pm.rough = true
	body.physics_material_override = pm
	for b in boxes:
		var shape := BoxShape3D.new()
		shape.size = b["size"]
		var col := CollisionShape3D.new()
		col.shape = shape
		col.transform = b["xform"]
		body.add_child(col)
	return body
