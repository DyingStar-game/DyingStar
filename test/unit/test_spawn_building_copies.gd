extends GutTest
## SpawnBuilding makes its apartments from its template packed once and instanced (copy_by_scene) instead of
## copying the template for each: the apartments must be the very nodes a copy gives — their paths, classes,
## scripts, scene files, transforms, groups, metadata, connections and every stored property — with the
## interiors streamed (a client) or not (the server).

## A name the engine gave a node (@Class@123), or the one a copy turned it into (_Class_123).
const AUTO_NAME := "(^|/)[@_]([A-Za-z0-9]+)[@_]\\d+(?=/|$)"
const BUILDING := preload("res://scenes/_universe/structures/buildings/spawn_building.tscn")

var _was := true


func before_each() -> void:
	_was = SpawnBuilding.copy_by_scene


func after_each() -> void:
	SpawnBuilding.copy_by_scene = _was


func _building(by_scene: bool, stream: bool) -> Node:
	SpawnBuilding.copy_by_scene = by_scene
	var b := BUILDING.instantiate()
	b.set("rows", 2)
	b.set("cols", 2)
	b.set("floors", 2)
	b.set("stream_interiors", stream)
	ReplicaDress.prepare(b)
	add_child_autofree(b)
	b.call("_create_apartments")
	return b


func test_apartments_by_scene_are_the_copies() -> void:
	for stream: bool in [true, false]:
		var copied := _building(false, stream)
		var packed := _building(true, stream)
		var a := _signature(copied.get_node("MultiMeshInstance3D"))
		var b := _signature(packed.get_node("MultiMeshInstance3D"))
		assert_gt(a.size(), 50, "apartments were made (stream %s)" % stream)
		assert_eq(b.size(), a.size(), "as many lines (stream %s)" % stream)
		var first_diff := ""
		for k in mini(a.size(), b.size()):
			if a[k] != b[k]:
				first_diff = "copy %s | by scene %s" % [a[k], b[k]]
				break
		assert_eq(first_diff, "", "the same apartments (stream %s)" % stream)


## Every node under [param root], and every stored property of it, as lines; a node a property points to by
## its class and name, not its id (each apartment points to its own nodes), a resource by its file, or its class
## alone when it was made at run time (the mirror's quad: shared by the copies, the scene's own by the
## instances). A node the engine named itself (AUTO_NAME) by its class alone: the number is a counter.
func _signature(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var counter := RegEx.create_from_string(AUTO_NAME)
	for node: Node in root.find_children("*", "", true, false):
		var path := counter.sub(str(root.get_path_to(node)), "$1@$2@#", true)
		var groups: Array = node.get_groups().filter(func(g: StringName) -> bool: return not str(g).begins_with("_"))
		var conns := 0
		for sig: Dictionary in node.get_signal_list():
			conns += node.get_signal_connection_list(sig.name).size()
		var metas := PackedStringArray()
		for m: StringName in node.get_meta_list():
			metas.append("%s=%s" % [m, _value(node.get_meta(m))])
		out.append("%s %s %s groups=%s metas=%s conns=%d" % [path, node.get_class(), node.scene_file_path, str(groups),
				str(metas), conns])
		for prop: Dictionary in node.get_property_list():
			if int(prop.usage) & PROPERTY_USAGE_STORAGE and str(prop.name) != "owner":
				out.append("  %s.%s = %s" % [path, prop.name, _value(node.get(prop.name))])
	return out


func _value(v: Variant) -> String:
	if v is Node:
		return "<%s %s>" % [(v as Node).get_class(), RegEx.create_from_string(AUTO_NAME).sub(str((v as Node).name),
				"$1@$2@#", true)]
	if v is Resource:
		var r := v as Resource
		return "<%s %s>" % [r.get_class(), r.resource_path]
	return str(v)
