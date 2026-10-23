extends GutTest
## ShellLod: the habitat container's far stand-in wears what the detailed parts are drawn with, and takes
## over exactly where they end.

const APARTMENT := "res://scenes/_universe/structures/buildings/container_apartment.tscn"


func test_the_stand_in_wears_the_parts_materials_and_takes_over_where_they_end() -> void:
	var apt: Node3D = (load(APARTMENT) as PackedScene).instantiate()
	add_child_autofree(apt)
	var lod: ShellLod = apt.find_child("ShellLod", true, false)
	assert_not_null(lod)
	var roof: MeshInstance3D = apt.find_child("roof", true, false)
	assert_eq(roof.visibility_range_end, ShellLod.DETAIL_END_M)
	var meshes := lod.find_children("*", "MeshInstance3D", true, false)
	assert_gt(meshes.size(), 0)
	for mesh: MeshInstance3D in meshes:
		assert_eq(mesh.visibility_range_begin, ShellLod.DETAIL_END_M)
		for i in mesh.mesh.get_surface_count():
			assert_not_null(mesh.get_surface_override_material(i), "surface %d dressed" % i)
	assert_same(meshes[0].get_surface_override_material(0), roof.get_active_material(0), "the yellow paint itself")


func test_a_blender_suffix_is_left_out_of_a_name() -> void:
	assert_eq(ShellLod.base_name("Material.001"), "Material")
	assert_eq(ShellLod.base_name("noir.001"), "noir")
	assert_eq(ShellLod.base_name("mat_metal_yellow_hauling"), "mat_metal_yellow_hauling")


## A room with a detailed plate (frame/ID) drawn with [param plate_name] and a stand-in of two surfaces,
## [param surfaces] by name: what paint_plate paints.
func _room(plate_name: String, surfaces: Array) -> Node3D:
	var room := Node3D.new()
	add_child_autofree(room)
	var plate := MeshInstance3D.new()
	plate.name = "ID"
	var plate_mesh := ArrayMesh.new()
	plate_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _triangle())
	var own := StandardMaterial3D.new()
	own.resource_name = plate_name
	plate_mesh.surface_set_material(0, own)
	plate.mesh = plate_mesh
	room.add_child(plate)
	var lod := Node3D.new()
	lod.name = "ShellLod"
	room.add_child(lod)
	var stand_in := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	for i in surfaces.size():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _triangle())
		var mat := StandardMaterial3D.new()
		mat.resource_name = surfaces[i]
		mesh.surface_set_material(i, mat)
	stand_in.mesh = mesh
	lod.add_child(stand_in)
	return room


func _triangle() -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	return arrays


func test_the_far_plate_is_found_by_the_detailed_plate_s_material_whatever_its_name() -> void:
	# Renamed in Blender, the plate's material still finds its stand-in surface ("Material.001" style
	# suffixes ignored); the stand-in's other surfaces are left alone.
	var room := _room("plaque.002", ["walls", "plaque"])
	var lit := StandardMaterial3D.new()
	ShellLod.paint_plate(room, lit)
	var stand_in := room.get_node("ShellLod").get_child(0) as MeshInstance3D
	assert_eq(stand_in.get_surface_override_material(1), lit, "the plate's surface")
	assert_null(stand_in.get_surface_override_material(0), "not the walls")


func test_the_building_a_node_stands_in_is_found_up_the_tree() -> void:
	var building := SpawnBuilding.new()
	var room := Node3D.new()
	var part := Node3D.new()
	building.add_child(room)
	room.add_child(part)
	assert_eq(SpawnBuilding.containing(part), building, "with no uuid: no network needed")
	assert_null(SpawnBuilding.containing(building), "a building is not in itself")
	assert_null(SpawnBuilding.containing(null))
	building.free()

