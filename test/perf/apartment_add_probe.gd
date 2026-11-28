extends Node3D
## Why a spawn building's apartments and walkways cost more under the building than under a bare node,
## headless. Each case on a fresh building (interiors streamed, as a client): the 23 apartment copies added
## under the building's MultiMeshInstance3D, under a bare node at the root, under the building with each
## script or with the shapes left out; and BuildingWalkways.build under the building against a bare node.
##   <godot> --headless --path . res://test/perf/apartment_add_probe.tscn [-- rows=2 cols=6 floors=2 wait]
## `wait`: a few frames between the building entering the tree and the timing.

const BUILDING := "res://scenes/_universe/structures/buildings/spawn_building.tscn"
const TRIALS := 3

var _rows := 2
var _cols := 6
var _floors := 2
var _wait := false
## What _fresh dresses the building with: all (ReplicaDress.prepare, as client.gd), none, draw, blend.
var _prepare := "all"


func _ready() -> void:
	var args := {}
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	_rows = int(args.get("rows", "2"))
	_cols = int(args.get("cols", "6"))
	_floors = int(args.get("floors", "2"))
	_wait = args.has("wait")
	_prepare = str(args.get("prepare", "all"))
	var bscene := load(BUILDING) as PackedScene
	var out := PackedStringArray()
	# Warm every cache (scenes, meshes, materials, walkway shapes) with a whole building first.
	var warm := await _fresh(bscene)
	warm.call("_create_apartments")
	warm.free()
	for where: String in ["mmi", "root", "building", "mmi:map_marker.gd", "mmi:shell_lod.gd", "mmi:noscripts",
			"mmi:noshapes", "mmi:nolabels", "mmi:nobodies"]:
		var times := PackedFloat64Array()
		for trial in TRIALS:
			times.append(await _add_case(bscene, where))
		out.append("23 apartments under %-20s %s ms" % [where, _list(times)])
	for where: String in ["building", "building child", "root"]:
		var times := PackedFloat64Array()
		for trial in TRIALS:
			times.append(await _walkways_case(bscene, where))
		out.append("walkways under %-20s %s ms" % [where, _list(times)])
	# The game's own path (server/client.gd create_generic_object): instantiate, dress, the data applied out
	# of the tree (the apartments made there, plates, furniture), then entering the tree.
	for trial in TRIALS:
		var t0 := Time.get_ticks_usec()
		var g := bscene.instantiate()
		g.set("stream_interiors", true)  # as a client with a window: headless copies the interiors too
		var t1 := Time.get_ticks_usec()
		ReplicaDress.prepare(g)
		var t2 := Time.get_ticks_usec()
		var apts: Array = []
		for k in 3:
			apts.append({"row": 0, "col": k, "floor": 0, "player_name": "p%d" % k, "player_uuid": "u%d" % k})
		g.call("apply_prop_data", {"rows": _rows, "cols": _cols, "floors": _floors, "apartments": apts})
		var t3 := Time.get_ticks_usec()
		var holder := Node3D.new()
		add_child(holder)
		var t4 := Time.get_ticks_usec()
		holder.add_child(g)
		var t5 := Time.get_ticks_usec()
		out.append("game path: instantiate %.1f, prepare %.1f, apply_prop_data %.1f, enter %.1f ms (%d nodes)" % [
				(t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0, (t5 - t4) / 1000.0,
				g.find_children("*", "", true, false).size()])
		holder.free()
	# What tracking one mesh costs, piece by piece (1000 times each).
	var meshes: Array[MeshInstance3D] = []
	for k in 1000:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		meshes.append(mi)
	var t := Time.get_ticks_usec()
	for k in 1000:
		DrawRange.multiplier(StructureDrawRange.OPTION)
	out.append("DrawRange.multiplier: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	for mi in meshes:
		StructureDrawRange.part_end_m(mi)
	out.append("StructureDrawRange.part_end_m: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	for k in 1000:
		OS.has_feature("dedicated_server")
	out.append("OS.has_feature: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	for k in 1000:
		DrawRange.group(StructureDrawRange.OPTION)
	out.append("DrawRange.group: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	var other: Array[MeshInstance3D] = []
	for k in 1000:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		other.append(mi)
	t = Time.get_ticks_usec()
	for mi in other:
		DrawRange.track(mi, StructureDrawRange.OPTION, 0.0, 100.0, false)
	out.append("DrawRange.track: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	for mi in other:
		mi.free()
	other.clear()
	for k in 1000:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		other.append(mi)
	t = Time.get_ticks_usec()
	for mi in other:
		mi.set_meta(&"draw_range_band", Vector2(0.0, 100.0))
	out.append("  set_meta new: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	for mi in other:
		mi.remove_meta(&"draw_range_fixed_begin")
	out.append("  remove_meta absent: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	var gname := DrawRange.group(StructureDrawRange.OPTION)
	t = Time.get_ticks_usec()
	for mi in other:
		mi.add_to_group(gname)
	out.append("  add_to_group: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	for mi in other:
		DrawRange.rescale(mi, 1.0)
	out.append("  rescale: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	for mi in other:
		mi.visibility_range_end = 50.0
	out.append("  visibility_range_end =: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	for mi in other:
		mi.free()
	var counted := [0, 0]
	var walk := func(node: Node, self_ref: Callable) -> void:
		counted[0] += 1
		if node is GeometryInstance3D and (node as GeometryInstance3D).visibility_range_end <= 0.0:
			counted[1] += 1
		for c in node.get_children():
			self_ref.call(c, self_ref)
	var shell := SpawnBuilding.ApartmentCopier.new(bscene.instantiate().get_node("MultiMeshInstance3D/0-0-0"), true)
	walk.call(shell.copy(), walk)
	out.append("one apartment (interior in): %d nodes, %d meshes with no range" % counted)
	t = Time.get_ticks_usec()
	for mi in meshes:
		StructureDrawRange._track(mi)
	out.append("StructureDrawRange._track: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	for mi in meshes:
		mi.child_entered_tree.connect(StructureDrawRange._cover)
	out.append("child_entered_tree.connect: %.2f us" % ((Time.get_ticks_usec() - t) / 1000.0))
	for mi in meshes:
		mi.free()
	for l in out:
		print("[AptAdd] " + l)
	get_tree().quit()


func _fresh(bscene: PackedScene) -> Node:
	var b := bscene.instantiate()
	b.set("rows", _rows)
	b.set("cols", _cols)
	b.set("floors", _floors)
	b.set("stream_interiors", true)
	match _prepare:
		"all":
			ReplicaDress.prepare(b)
		"draw":
			StructureDrawRange.attach_to(b)
		"blend":
			TerrainBlend.attach_to(b)
	add_child(b)
	if _wait:
		for k in 3:
			await get_tree().physics_frame
	return b


func _add_case(bscene: PackedScene, where: String) -> float:
	var b := await _fresh(bscene)
	var mmi: Node = b.get_node("MultiMeshInstance3D")
	var tpl: Node = mmi.get_node("0-0-0")
	var streamer := InteriorStreamer.take_from(tpl, mmi, Vector3.ONE)
	if streamer != null:
		b.add_child(streamer)
	var copier := SpawnBuilding.ApartmentCopier.new(tpl, true)
	var made: Array[Node] = []
	for k in _rows * _cols * _floors - 1:
		var m: Node3D = copier.copy()
		m.name = "x-%d" % k
		m.position = Vector3(0.0 if k % 2 == 0 else 5.0, (k / 12) * 2.6, (k % 12) * 2.6)
		_strip(m, where.get_slice(":", 1))
		made.append(m)
	var parent: Node = mmi
	var holder: Node3D = null
	if where == "root":
		holder = Node3D.new()
		add_child(holder)
		parent = holder
	elif where == "building":
		parent = b
	var t := Time.get_ticks_usec()
	for m in made:
		parent.add_child(m)
	var ms := (Time.get_ticks_usec() - t) / 1000.0
	if holder != null:
		holder.free()
	b.free()
	return ms


func _walkways_case(bscene: PackedScene, where: String) -> float:
	var b := await _fresh(bscene)
	var target: Node3D = b
	var holder: Node3D = null
	if where == "building child":
		holder = Node3D.new()
		b.add_child(holder)
		target = holder
	elif where == "root":
		holder = Node3D.new()
		add_child(holder)
		target = holder
	var t := Time.get_ticks_usec()
	BuildingWalkways.build(target, _rows, _cols, _floors, float(b.get("x_spacing")), float(b.get("z_spacing")),
			float(b.get("y_spacing")))
	var ms := (Time.get_ticks_usec() - t) / 1000.0
	if holder != null and holder.get_parent() == self:
		holder.free()
	b.free()
	return ms


## Leaves out of [param root] what [param what] names: a script file, every script, the shapes, the labels,
## or the bodies (their shapes too).
func _strip(root: Node, what: String) -> void:
	if what == "":
		return
	for node in [root] + root.find_children("*", "", true, false):
		var sc := node.get_script() as Script
		if sc != null and (what == "noscripts" or sc.resource_path.get_file() == what):
			node.set_script(null)
	for node in root.find_children("*", "", true, false):
		if is_instance_valid(node) and node.get_parent() != null and ((what == "noshapes" and node is CollisionShape3D)
				or (what == "nolabels" and node is Label3D) or (what == "nobodies" and node is CollisionObject3D)):
			node.get_parent().remove_child(node)
			node.free()
	if what == "nobodies":
		for node in root.find_children("*", "CollisionShape3D", true, false):
			node.get_parent().remove_child(node)
			node.free()


func _list(times: PackedFloat64Array) -> String:
	var s := PackedStringArray()
	for v in times:
		s.append("%6.1f" % v)
	return " ".join(s)
