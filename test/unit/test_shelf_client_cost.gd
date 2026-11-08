extends GutTest
## What a shelf costs the client: a depot has 193 of them. No fringe of ground on the floor of a hall, and
## a draw distance of its own.

const SCENE := "res://scenes/_universe/props/furniture/metal_shelf.tscn"


func test_a_shelf_wears_no_fringe() -> void:
	var shelf: Node = autofree((load(SCENE) as PackedScene).instantiate())
	assert_true(shelf is Shelf)
	assert_false(TerrainBlend.wants_fringe(shelf))


func test_a_shelf_is_drawn_up_to_its_distance() -> void:
	var shelf: Shelf = autofree((load(SCENE) as PackedScene).instantiate())
	shelf.limit_draw_distance()
	var meshes := shelf.find_children("*", "MeshInstance3D", true, false)
	assert_gt(meshes.size(), 0, "the shelf's model")
	for mesh: MeshInstance3D in meshes:
		assert_almost_eq(mesh.visibility_range_end, Shelf.DRAW_END_M * DrawRange.multiplier(StructureDrawRange.OPTION), 0.01)
