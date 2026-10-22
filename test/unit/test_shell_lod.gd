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
