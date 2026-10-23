extends Node
## Merge box.glb's two meshes — the box and its decal strip — into ONE mesh with two surfaces, for
## hauling_box.tscn: one render instance per crate instead of two.
##
## Why: a depot stocked by the admin fill holds 2 400 crates. Every render instance is sorted and
## culled for the view and for each shadow pass, and re-placed whenever the planet turns; looking
## down an aisle, 20 000-30 000 objects cost the client 13-17 ms of render CPU against 5-6 ms facing a
## wall (2026-10-23). The two surfaces still draw separately, but the crate is half the instances.
##
## The materials are the ones hauling_box.tscn used to put on the two nodes (yellow painted metal, the
## ARES decal), baked as the surfaces' own. LODs are generated as the importer would; no shadow mesh
## (ImporterMesh.create_shadow_mesh never returned on this mesh, 4.7): shadows use the mesh itself.
## Run it again whenever box.glb changes:
##   godot --headless --path . res://tools/merge_hauling_box_mesh.tscn

const SOURCE := "res://assets/_universe/props/containers/box.glb"
const OUTPUT := "res://assets/_universe/props/containers/box_merged.res"
## Source node -> the material its surface gets.
const SURFACES := {
	"box": "res://assets/_universe/_shared/materials/mat_metal_smart_painted/mat_metal_smart_painted_yellow.tres",
	"box_decals": "res://assets/_universe/_shared/materials/mat_metal_ares_misc_decal/mat_metal_ares_misc_decal.tres",
}
## ImporterMesh.generate_lods angles (degrees), the importer's defaults.
const LOD_NORMAL_MERGE_ANGLE := 25.0
const LOD_NORMAL_SPLIT_ANGLE := 60.0


func _ready() -> void:
	var root := (load(SOURCE) as PackedScene).instantiate() as Node3D
	var merged := ImporterMesh.new()
	for node_name: String in SURFACES:
		var mi := root.get_node(node_name) as MeshInstance3D
		var arrays: Array = mi.mesh.surface_get_arrays(0)
		_bake_transform(arrays, mi.transform)
		merged.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, load(SURFACES[node_name]), node_name)
	root.free()
	merged.generate_lods(LOD_NORMAL_MERGE_ANGLE, LOD_NORMAL_SPLIT_ANGLE, [])
	var mesh: ArrayMesh = merged.get_mesh()
	var err := ResourceSaver.save(mesh, OUTPUT)
	print("[merge_hauling_box_mesh] %s: %d surfaces -> %s (%s)" % [
			SOURCE, mesh.get_surface_count(), OUTPUT, error_string(err)])
	get_tree().quit(0 if err == OK else 1)


## Move a surface's vertices, normals and tangents by [param xform] (the node's transform in the
## glTF scene), so the merged mesh needs none. A mirroring transform also flips the winding.
static func _bake_transform(arrays: Array, xform: Transform3D) -> void:
	var normal_basis: Basis = xform.basis.inverse().transposed()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		vertices[i] = xform * vertices[i]
	arrays[Mesh.ARRAY_VERTEX] = vertices
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in normals.size():
			normals[i] = (normal_basis * normals[i]).normalized()
		arrays[Mesh.ARRAY_NORMAL] = normals
	var mirrored: bool = xform.basis.determinant() < 0.0
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in range(0, tangents.size(), 4):
			var t: Vector3 = (xform.basis * Vector3(tangents[i], tangents[i + 1], tangents[i + 2])).normalized()
			tangents[i] = t.x
			tangents[i + 1] = t.y
			tangents[i + 2] = t.z
			if mirrored:
				tangents[i + 3] = -tangents[i + 3]
		arrays[Mesh.ARRAY_TANGENT] = tangents
	if mirrored and arrays[Mesh.ARRAY_INDEX] != null:
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0, indices.size(), 3):
			var swap: int = indices[i + 1]
			indices[i + 1] = indices[i + 2]
			indices[i + 2] = swap
		arrays[Mesh.ARRAY_INDEX] = indices
