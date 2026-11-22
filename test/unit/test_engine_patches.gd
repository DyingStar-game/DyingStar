extends GutTest
## The game runs on its own engine build (DyingStar-game/godotandaddons, patches/): these check the patches that
## can be seen from a script are in the engine running the tests. A failure here = a stock Godot, or a release
## built without that patch.

## How far from the origin (m): a planet's distance to its star, where PR #512 measured the lamps' shadows.
const FAR_M := 8.5e10
## How far the instance moves (m): a step of the planet is ~137 km, far below the old relative 1e-5 (850 km here).
const MOVE_M := 1000.0


## godotandaddons patch 0003: DynamicBVH::update compares exactly. With the stock relative tolerance, the
## rendering tree kept an instance where it was until it had moved by more than 1e-5 of its coordinate, and an
## omni or spot light found no shadow caster where it now stood.
func test_the_render_tree_follows_a_small_move_far_from_the_origin() -> void:
	var rs := RenderingServer
	var scenario: RID = rs.scenario_create()
	var mesh: RID = rs.mesh_create()
	var instance: RID = rs.instance_create2(mesh, scenario)
	var marker := RefCounted.new()  # instances_cull_aabb answers the object ids attached to the instances
	rs.instance_attach_object_instance_id(instance, marker.get_instance_id())
	rs.instance_set_custom_aabb(instance, AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2)))
	var start := Vector3(FAR_M, 0.0, 0.0)
	rs.instance_set_transform(instance, Transform3D(Basis.IDENTITY, start))
	assert_true(_found(marker, start, scenario), "indexed where it was placed")

	var moved := start + Vector3(MOVE_M, 0.0, 0.0)
	rs.instance_set_transform(instance, Transform3D(Basis.IDENTITY, moved))
	assert_true(_found(marker, moved, scenario),
			"found where it moved: without godotandaddons patch 0003 the tree keeps it %d m behind" % MOVE_M)
	assert_false(_found(marker, start, scenario), "no longer where it was")

	rs.free_rid(instance)
	rs.free_rid(mesh)
	rs.free_rid(scenario)


## Does the rendering tree of [param scenario] hold the instance of [param marker] within 10 m of [param at]?
func _found(marker: Object, at: Vector3, scenario: RID) -> bool:
	var box := AABB(at - Vector3.ONE * 10.0, Vector3.ONE * 20.0)
	return RenderingServer.instances_cull_aabb(box, scenario).has(marker.get_instance_id())
