extends GutTest
## The shipping containers are fixed networked buildings that level their ground, so a village layout
## can place them and stack them. A StaticBody3D: the server's culler thaws a RigidBody3D when a player
## comes near, and a thawed 9 t container falls over. The simple_building type, which replicates the
## flattener's measures (terrain_settled). The yellow hauling paint.
##
## A container meant to stand on N-1 others is its _tierN variant: its flattener's Ground box sits N-1
## container heights down, so it levels the same ground as the one below and seats this one on top.

const DIR := "res://scenes/_universe/props/containers/"
const KINDS: Array[String] = ["benne", "liquid", "standard_a", "standard_b"]
const STACKABLE: Array[String] = ["liquid", "standard_a", "standard_b"]
## Every container model is 12 x 2.5 x 2.4 m, its floor at y = 0.
const HEIGHT := 2.5
const YELLOW := "res://assets/_universe/_shared/materials/mat_metal_yellow_hauling/mat_metal_yellow_hauling.tres"
## The layouts that stack containers.
const LAYOUTS: Array[String] = [
	"res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn",
]


func test_a_container_is_a_fixed_networked_building_that_levels_its_ground() -> void:
	for kind: String in KINDS:
		var c: Node = load(_path(kind)).instantiate()
		assert_true(c is StaticBody3D, "%s: static, nothing to thaw" % kind)
		var sync := PropSync.of(c)
		assert_not_null(sync)
		if sync != null:
			assert_eq(sync.type_name, "simple_building", kind)
			assert_false(sync.enable_carry, kind)
		var ground := c.get_node_or_null("TerrainPad/Ground") as CSGBox3D
		assert_not_null(ground, "%s levels its ground" % kind)
		if ground != null:
			assert_almost_eq(_top(ground), 0.0, 0.001, "%s: the levelled ground meets its floor" % kind)
			assert_true(ground.size.x >= 12.0 and ground.size.z >= 2.4, "%s: the whole footprint" % kind)
		c.free()


func test_every_level_of_detail_wears_the_yellow_paint() -> void:
	for kind: String in KINDS:
		var c: Node = load(_path(kind)).instantiate()
		# The tank's model root is itself an empty MeshInstance3D: only the ones that draw count.
		var meshes := c.find_children("*", "MeshInstance3D", true, false).filter(
				func(m: Node) -> bool: return (m as MeshInstance3D).mesh != null)
		assert_eq(meshes.size(), 4, "%s: four levels of detail" % kind)
		for mesh: MeshInstance3D in meshes:
			for i in mesh.mesh.get_surface_count():
				var mat := mesh.get_surface_override_material(i)
				assert_eq(mat.resource_path if mat != null else "", YELLOW, "%s %s" % [kind, mesh.name])
		c.free()


func test_the_collision_is_as_tall_as_the_model() -> void:
	for kind: String in KINDS:
		var c: Node = load(_path(kind)).instantiate()
		var shape := (c.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
		assert_almost_eq(shape.size.y, HEIGHT, 0.001, kind)
		var lod0: MeshInstance3D = null
		for mesh: MeshInstance3D in c.find_children("*_LOD0", "MeshInstance3D", true, false):
			lod0 = mesh
		assert_almost_eq(lod0.mesh.get_aabb().size.y, HEIGHT, 0.01, "%s: the stacking height" % kind)
		c.free()


func test_a_tier_seats_itself_on_the_ones_below() -> void:
	for kind: String in STACKABLE:
		for level: int in [2, 3]:
			var c: Node = load(_tier_path(kind, level)).instantiate()
			var ground := c.get_node("TerrainPad/Ground") as CSGBox3D
			assert_almost_eq(_top(ground), -HEIGHT * (level - 1), 0.001, "%s tier %d" % [kind, level])
			assert_eq(PropSync.of(c).type_name, "simple_building")
			c.free()


## Read from the files: the layouts pull in buildings whose materials raise engine errors on load.
func test_every_stacked_container_has_the_ones_below_it() -> void:
	var tier := RegEx.create_from_string("container_\\w+_1200x240x240(?:_tier(\\d))?\\.tscn")
	for layout: String in LAYOUTS:
		var text := FileAccess.get_file_as_string(layout).replace("\r\n", "\n")
		var level_of := {}  # ext_resource id -> tier (1 for a base container)
		for ext in RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"([^\"]+)\" id=\"([^\"]+)\"\\]") \
				.search_all(text):
			var t := tier.search(ext.get_string(1))
			if t != null:
				level_of[ext.get_string(2)] = int(t.get_string(1)) if t.get_string(1) != "" else 1
		var placed: Array = []  # [level, Transform3D, name]
		var node := RegEx.create_from_string("\\[node name=\"([^\"]+)\" parent=\"\\.\"[^\\]]*instance=" \
				+ "ExtResource\\(\"([^\"]+)\"\\)\\]\\ntransform = (Transform3D\\([^)]*\\))")
		for m in node.search_all(text):
			if level_of.has(m.get_string(2)):
				placed.append([level_of[m.get_string(2)], str_to_var(m.get_string(3)), m.get_string(1)])
		assert_gt(placed.size(), 0, "%s places containers" % layout)
		for p: Array in placed:
			if p[0] == 1:
				continue
			var below := false
			for q: Array in placed:
				var dx: Transform3D = q[1]
				var px: Transform3D = p[1]
				if q[0] == p[0] - 1 and Vector2(dx.origin.x - px.origin.x, dx.origin.z - px.origin.z).length() < 0.01 \
						and dx.basis.x.is_equal_approx(px.basis.x) and is_equal_approx(px.origin.y - dx.origin.y, HEIGHT):
					below = true
			assert_true(below, "%s: %s (tier %d) stands on a tier %d" % [layout.get_file(), p[2], p[0], p[0] - 1])


func _path(kind: String) -> String:
	return DIR + "container_%s_1200x240x240.tscn" % kind


func _tier_path(kind: String, level: int) -> String:
	return DIR + "container_%s_1200x240x240_tier%d.tscn" % [kind, level]


## Height of the box's top face in the container's frame.
func _top(box: CSGBox3D) -> float:
	var xf := (box.get_parent() as Node3D).transform * box.transform
	return xf.origin.y + box.size.y * 0.5
