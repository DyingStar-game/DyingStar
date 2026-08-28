@tool
class_name SharedMaterialResolver
extends RefCounted

## Replaces materials coming from a glTF with the project's shared resources.
##
## Single responsibility: walk a scene, resolve material names against the
## shared material folder, and assign overrides. Knows nothing about the import
## pipeline, so the editor plugin can reuse it for a manual pass on scenes that
## were imported before this script existed.
##
## The link is the material name: an artist applies "mat_corindon_pure" in
## Blender, the glTF carries that name, and this resolver loads the resource
## that resource_path() points at. Names are used rather than surface indices
## because an index encodes a position in the Blender slot list, which silently
## shifts when a slot is added, removed or reordered.

## Where shared materials live. Single place to change if the layout moves.
const MATERIALS_DIR := "res://assets/_universe/_shared/materials"

## Only materials carrying this prefix are considered part of the library.
## Model-specific materials keep whatever the glTF provided.
const SHARED_PREFIX := "mat_"

const RESOURCE_EXTENSION := ".tres"


## Where a material's Godot resource lives, given its name.
##
## The single definition of that rule: this resolver reads through it and the
## library generator writes through it, so the two cannot drift apart. Each
## material keeps its resource inside its own folder, beside the manifest and
## the maps it was built from.
static func resource_path(material_name: String) -> String:
	return MATERIALS_DIR.path_join(material_name).path_join(
		material_name + RESOURCE_EXTENSION
	)


## Outcome of a resolve pass, so callers can report without parsing logs.
class Report extends RefCounted:
	## Distinct materials that were found, and the number of surfaces they were
	## assigned to. One material commonly covers several surfaces, so counting
	## assignments alone reads as though the library held more entries than it
	## does.
	var applied: PackedStringArray = []
	var resolved: int = 0
	var missing: PackedStringArray = []
	var embedded_textures: PackedStringArray = []

	func has_problems() -> bool:
		return not missing.is_empty() or not embedded_textures.is_empty()

	func to_string_summary() -> String:
		return "%d shared material(s) on %d surface(s), %d missing, %d with embedded textures" % [
			applied.size(), resolved, missing.size(), embedded_textures.size()
		]


## Applies shared materials to every mesh in the scene and returns a report.
func resolve(scene: Node) -> Report:
	var report := Report.new()
	for mesh_instance in _collect_mesh_instances(scene):
		_apply_to_mesh_instance(mesh_instance, report)
	return report


func _collect_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		found.append(node)
	for child in node.get_children():
		found.append_array(_collect_mesh_instances(child))
	return found


func _apply_to_mesh_instance(mesh_instance: MeshInstance3D, report: Report) -> void:
	var mesh := mesh_instance.mesh
	if mesh == null:
		return

	for surface_index in mesh.get_surface_count():
		var source_material := mesh.surface_get_material(surface_index)
		if source_material == null:
			continue

		var material_name := source_material.resource_name.strip_edges()
		if not material_name.begins_with(SHARED_PREFIX):
			continue

		_warn_if_textures_embedded(source_material, material_name, report)

		var shared_material := _load_shared_material(material_name)
		if shared_material == null:
			if not report.missing.has(material_name):
				report.missing.append(material_name)
			continue

		mesh_instance.set_surface_override_material(surface_index, shared_material)
		report.resolved += 1
		if not report.applied.has(material_name):
			report.applied.append(material_name)


## A shared material arriving with its textures means the glTF was exported with
## the wrong settings (Images must be set to None). Left unreported, this
## duplicates every texture in every model that uses the material.
func _warn_if_textures_embedded(
	material: Material, material_name: String, report: Report
) -> void:
	if not material is BaseMaterial3D:
		return
	if material.albedo_texture == null:
		return
	if not report.embedded_textures.has(material_name):
		report.embedded_textures.append(material_name)


func _load_shared_material(material_name: String) -> Material:
	var path := resource_path(material_name)
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Material
