extends GutTest
## The shipping containers are fixed networked props that stand in a storage area (PadStorageArea): the
## area levels the ground, the containers are its children in the layout, so the server spawns them in
## its frame and they follow it onto its ground. A StaticBody3D: the server's culler thaws a RigidBody3D
## when a player comes near, and a thawed 9 t container falls over. Painted yellow, and stacked each on
## the one below.

const DIR := "res://scenes/_universe/props/containers/"
const KINDS: Array[String] = ["benne", "liquid", "standard_a", "standard_b"]
const YELLOW := "res://assets/_universe/_shared/materials/mat_metal_yellow_hauling/mat_metal_yellow_hauling.tres"
## The reworked standard_a (12.2 x 2.6 x 2.6 m, three levels of detail) wears the smart painted metal, whose
## vertex colours' alpha is its light mask: 0 on its every vertex, or it is drawn black.
const SMART_YELLOW := "res://assets/_universe/_shared/materials/mat_metal_smart_painted/mat_metal_smart_painted_yellow.tres"
## Each model: its levels of detail, its paint, its height (m, floor at y = 0: what a container on it
## stands up by).
const MODELS := {
	"standard_a": {"lods": 3, "paint": SMART_YELLOW, "height": 2.6},
}
const OTHER_MODEL := {"lods": 4, "paint": YELLOW, "height": 2.5}
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
		assert_eq(meshes.size(), _model(kind)["lods"], "%s: its levels of detail" % kind)
		for mesh: MeshInstance3D in meshes:
			for i in mesh.mesh.get_surface_count():
				var mat := mesh.get_surface_override_material(i)
				assert_eq(mat.resource_path if mat != null else "", _model(kind)["paint"], "%s %s" % [kind, mesh.name])
		c.free()


## The smart painted metal reads the alpha of the vertex colours as where the paint glows: 1 drew the
## reworked container black (2026-10-21). None of its levels of detail may carry it.
func test_a_smart_painted_container_does_not_glow() -> void:
	for kind: String in KINDS:
		if _model(kind)["paint"] != SMART_YELLOW:
			continue
		var c: Node = load(_path(kind)).instantiate()
		for mesh: MeshInstance3D in c.find_children("*", "MeshInstance3D", true, false):
			if mesh.mesh == null:
				continue
			for i in mesh.mesh.get_surface_count():
				var colours: Variant = mesh.mesh.surface_get_arrays(i)[Mesh.ARRAY_COLOR]
				assert_not_null(colours, "%s %s: the masks are vertex colours" % [kind, mesh.name])
				var brightest := 0.0
				for colour: Color in (colours if colours != null else PackedColorArray()):
					brightest = maxf(brightest, colour.a)
				assert_lt(brightest, 0.1, "%s %s: no vertex lit" % [kind, mesh.name])
		c.free()


func test_the_collision_is_as_tall_as_the_model() -> void:
	for kind: String in KINDS:
		var c: Node = load(_path(kind)).instantiate()
		var shape := (c.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
		assert_almost_eq(shape.size.y, _model(kind)["height"], 0.001, kind)
		var lod0: MeshInstance3D = null
		for mesh: MeshInstance3D in c.find_children("*_LOD0", "MeshInstance3D", true, false):
			lod0 = mesh
		assert_almost_eq(lod0.mesh.get_aabb().size.y, _model(kind)["height"], 0.01, "%s: the stacking height" % kind)
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


## A container of a layout rests on the one below it in its stack (same area, same spot): each model has
## its own height, and a stack of different ones is not a multiple of one.
func test_a_stacked_container_rests_on_the_one_below() -> void:
	var place := RegEx.create_from_string("transform = Transform3D\\(([^)]*)\\)")
	for layout: String in LAYOUTS:
		var text := FileAccess.get_file_as_string(layout).replace("\r\n", "\n")
		var kinds := {}  # ext id -> container kind
		for ext in RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"" + DIR
				+ "container_(\\w+?)_1200x240x240\\.tscn\" id=\"([^\"]+)\"\\]").search_all(text):
			kinds[ext.get_string(2)] = ext.get_string(1)
		var stacks := {}  # "area x z" -> [[y, kind]]
		for block in text.split("\n[node "):
			var head := RegEx.create_from_string("^name=\"[^\"]+\" parent=\"([^\"]+)\"[^\\]]*instance=ExtResource\\(\"([^\"]+)\"\\)").search(block)
			if head == null or not kinds.has(head.get_string(2)):
				continue
			var at := PackedFloat64Array([0, 0, 0])
			var t := place.search(block)
			if t != null:
				var v := t.get_string(1).split(",")
				at = PackedFloat64Array([float(v[9]), float(v[10]), float(v[11])])
			var key := "%s %.1f %.1f" % [head.get_string(1), at[0], at[2]]
			stacks[key] = stacks.get(key, []) + [[at[1], kinds[head.get_string(2)]]]
		for key: String in stacks:
			var stack: Array = stacks[key]
			stack.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
			var y := 0.0
			for item: Array in stack:
				assert_almost_eq(float(item[0]), y, 0.01, "%s %s: %s on the one below" % [layout.get_file(), key, item[1]])
				y += float(_model(item[1])["height"])


func _model(kind: String) -> Dictionary:
	return MODELS.get(kind, OTHER_MODEL)


func _path(kind: String) -> String:
	return DIR + "container_%s_1200x240x240.tscn" % kind
