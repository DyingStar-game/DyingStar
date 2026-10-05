extends GutTest
## The shipping containers are fixed networked props that stand in a storage area (PadStorageArea): the
## area levels the ground, the containers are its children in the layout, so the server spawns them in
## its frame and they follow it onto its ground. A StaticBody3D: the server's culler thaws a RigidBody3D
## when a player comes near, and a thawed 9 t container falls over. The yellow hauling paint.

const DIR := "res://scenes/_universe/props/containers/"
const KINDS: Array[String] = ["benne", "liquid", "standard_a", "standard_b"]
## Every container model is 12 x 2.5 x 2.4 m, its floor at y = 0: a container on another stands 2.5 m up.
const HEIGHT := 2.5
const YELLOW := "res://assets/_universe/_shared/materials/mat_metal_yellow_hauling/mat_metal_yellow_hauling.tres"
const AREA := "res://scenes/_universe/structures/industrial/storage/pad_storage_area.tscn"
## The layouts that place containers.
const LAYOUTS: Array[String] = [
	"res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn",
	"res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn",
]


func test_a_container_is_a_fixed_networked_prop_with_no_ground_of_its_own() -> void:
	for kind: String in KINDS:
		var c: Node = load(_path(kind)).instantiate()
		assert_true(c is StaticBody3D, "%s: static, nothing to thaw" % kind)
		var sync := PropSync.of(c)
		assert_not_null(sync)
		if sync != null:
			assert_eq(sync.type_name, "simple_building", kind)
			assert_false(sync.enable_carry, kind)
		assert_null(c.get_node_or_null("TerrainPad"), "%s: its storage area levels the ground, not itself" % kind)
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


## Read from the files: the layouts pull in buildings whose materials raise engine errors on load. A
## container beside an area would keep the layout's height while the ground under it settles elsewhere.
func test_every_container_of_a_layout_stands_in_a_storage_area() -> void:
	for layout: String in LAYOUTS:
		var text := FileAccess.get_file_as_string(layout).replace("\r\n", "\n")
		var containers := {}  # ext id of a container scene
		var area_id := ""
		for ext in RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"([^\"]+)\" id=\"([^\"]+)\"\\]").search_all(text):
			if ext.get_string(1).begins_with(DIR + "container_"):
				containers[ext.get_string(2)] = true
			elif ext.get_string(1) == AREA:
				area_id = ext.get_string(2)
		var areas := {}
		var placed := 0
		var node := RegEx.create_from_string("\\[node name=\"([^\"]+)\" parent=\"([^\"]+)\"[^\\]]*instance=ExtResource\\(\"([^\"]+)\"\\)\\]")
		for m in node.search_all(text):
			if m.get_string(3) == area_id and m.get_string(2) == ".":
				areas[m.get_string(1)] = true
		for m in node.search_all(text):
			if containers.has(m.get_string(3)):
				placed += 1
				assert_true(areas.has(m.get_string(2)), "%s: %s is a child of a storage area" % [layout.get_file(), m.get_string(1)])
		assert_gt(placed, 0, "%s places containers" % layout.get_file())


func _path(kind: String) -> String:
	return DIR + "container_%s_1200x240x240.tscn" % kind
