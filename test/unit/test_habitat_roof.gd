extends GutTest
## The habitat container's roof is a lighter model of the same sheet (habitat_container_roof.res, 3 036
## triangles instead of the model's 20 356): it must stay where the model's roof is, the same size.

const APARTMENT := "res://scenes/_universe/structures/buildings/container_apartment.tscn"
const MODEL := "res://assets/_universe/structures/buildings/habitat_container.glb"


func test_the_light_roof_fills_the_models_roof() -> void:
	var model: Node = (load(MODEL) as PackedScene).instantiate()
	var original: AABB = (model.find_child("roof", true, false) as MeshInstance3D).mesh.get_aabb()
	model.free()
	var apt: Node3D = (load(APARTMENT) as PackedScene).instantiate()
	var roof: MeshInstance3D = apt.find_child("roof", true, false)
	assert_lt(roof.mesh.get_faces().size() / 3, 4000, "the light one")
	var light: AABB = roof.mesh.get_aabb()
	for axis in 3:
		assert_almost_eq(light.position[axis], original.position[axis], 0.003, "its corner, axis %d" % axis)
		assert_almost_eq(light.end[axis], original.end[axis], 0.003, "its far corner, axis %d" % axis)
	apt.free()
