extends GutTest
## Every FIXED object a village or city layout spawns levels its own ground: it carries a TerrainPad.
## Without one it keeps the altitude it was stored at and never meets the ground the village bed and
## its neighbours' pads actually build — the bollard rows of the mining village floated in the air.
## Movable props (a RigidBody3D: crates, carts) are exempt, and so are the props a layout places
## UNDER another item (the containers of a storage area): they ride their parent's platform.
## Read from the files: some buildings pull in materials that raise engine errors when a whole
## layout is instanced.

const LAYOUTS := [
	"res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn",
	"res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn",
]


func test_every_fixed_item_of_a_layout_has_a_terrain_pad() -> void:
	var seen := {}
	for layout: String in LAYOUTS:
		for scene: String in LayoutFile.root_scenes(layout):
			if seen.has(scene):
				continue
			seen[scene] = true
			var packed := load(scene) as PackedScene
			assert_not_null(packed, "%s: %s loads" % [layout.get_file(), scene])
			if packed == null:
				continue
			var root := packed.instantiate()
			if root is RigidBody3D or PropSync.of(root) == null:
				root.free()
				continue  # movable, or not a networked prop at all
			var pads := root.find_children("*", "TerrainPad", true, false)
			assert_gt(pads.size(), 0, "%s: %s is fixed and must level its ground (TerrainPad)"
					% [layout.get_file(), scene.get_file()])
			root.free()
	assert_gt(seen.size(), 10, "the layouts were read")
	KnownEngineErrors.forgive_floor_material(self)  # the layouts' buildings load the floor material

