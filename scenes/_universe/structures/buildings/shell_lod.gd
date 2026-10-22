class_name ShellLod
extends Node3D
## The far stand-in of a habitat container's fixed shell (frame, roof, walls, floor, serial plate): ONE mesh
## of 6 899 triangles (habitat_container_lod1.glb), cut down in Blender from the model's 34 498 -- its
## outside and its inside each on its own (cut together, the 2 cm sheets collapsed onto each other), the
## inside kept for what an open door shows. The detailed parts end where it begins (DETAIL_END_M); the
## doors and their handles, which move, keep their own meshes at every distance.
##
## Its glb carries only the names of its materials (no texture): each takes here what the detailed part
## of the same material is drawn with (the same resource), the model's import script having swapped the
## glb's grey materials for the project's. A name compares without Blender's ".001" suffix.

## Where the detailed fixed parts end and this stand-in begins (m), and the band (m) both keep beyond it
## so that a camera standing on the line does not make them flicker.
const DETAIL_END_M := 25.0
const MARGIN_M := 2.0
## The fixed parts of the model it stands in for, from the glb's root.
const DETAILED := ["frame", "frame/roof", "frame/left_wall", "frame/right_wall", "frame/bottom_wall", "frame/ID"]

## The base name of the ID plate's own material, in the model and in this stand-in alike: the plate
## ApartmentPlates lights red or green (paint_plate).
const PLATE_MATERIAL := "noir"

## Material base name -> the model's material, shared by every container (one glb, one set).
static var _materials: Dictionary = {}


func _ready() -> void:
	var model: Node = get_parent()
	for path: String in DETAILED:
		var part := model.get_node_or_null(path) as GeometryInstance3D
		if part != null:
			part.visibility_range_end = DETAIL_END_M
			part.visibility_range_end_margin = MARGIN_M
	for mesh: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		mesh.visibility_range_begin = DETAIL_END_M
		mesh.visibility_range_begin_margin = MARGIN_M
		for i in mesh.mesh.get_surface_count():
			var own := mesh.mesh.surface_get_material(i)
			var model_material := _material(model, own.resource_name if own != null else "")
			if model_material != null:
				mesh.set_surface_override_material(i, model_material)


## The model's material named [param name] (without its ".NNN" suffix), or null.
static func _material(model: Node, name: String) -> Material:
	var key := base_name(name)
	if _materials.is_empty():
		for path: String in DETAILED:
			var part := model.get_node_or_null(path) as MeshInstance3D
			if part == null or part.mesh == null:
				continue
			for i in part.mesh.get_surface_count():
				# The material it is drawn with: the model's import script swaps its grey ones for the
				# project's (mat_metal_yellow_hauling.tres...) as surface overrides, by name.
				var own := part.mesh.surface_get_material(i)
				var material := part.get_active_material(i)
				if own != null and material != null and not _materials.has(base_name(own.resource_name)):
					_materials[base_name(own.resource_name)] = material
	return _materials.get(key)


## The stand-in's ID plate in [room] painted with [param material], as ApartmentPlates paints the
## detailed one: past DETAIL_END_M only the stand-in's is drawn, and in the model's plain black the
## plate lost its colour there (playtest 2026-10-22).
static func paint_plate(room: Node, material: Material) -> void:
	var lod := room.find_child("ShellLod", true, false)
	if lod == null:
		return
	for mesh: MeshInstance3D in lod.find_children("*", "MeshInstance3D", true, false):
		for i in mesh.mesh.get_surface_count():
			var own := mesh.mesh.surface_get_material(i)
			if own != null and base_name(own.resource_name) == PLATE_MATERIAL:
				mesh.set_surface_override_material(i, material)


## [param name] without a Blender ".NNN" suffix: "Material.001" -> "Material".
static func base_name(name: String) -> String:
	var dot := name.rfind(".")
	if dot > 0 and name.substr(dot + 1).is_valid_int():
		return name.substr(0, dot)
	return name
