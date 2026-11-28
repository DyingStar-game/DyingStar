extends Node3D
## Where a spawn building's apartments cost the client, headless: the building as a client gets it (interiors
## streamed: shells copied), its apartments made the way _create_apartments makes them, step by step — a copy
## against a fresh instance, the copies entering the tree, and the same with each kind of script left out.
##   <godot> --headless --path . res://test/perf/apartment_probe.tscn [-- rows=2 cols=6 floors=2 full]
## `full`: the interiors copied too (what a headless client, with no camera to stream them, does).

const BUILDING := "res://scenes/_universe/structures/buildings/spawn_building.tscn"
const APARTMENT := "res://scenes/_universe/structures/buildings/container_apartment.tscn"


func _ready() -> void:
	var args := {}
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var rows := int(args.get("rows", "2"))
	var cols := int(args.get("cols", "6"))
	var floors := int(args.get("floors", "2"))
	var stream := not args.has("full")
	var out := PackedStringArray()
	# Warm both scenes, so no stage pays the disk.
	var bscene := load(BUILDING) as PackedScene
	var ascene := load(APARTMENT) as PackedScene
	# 1. The building's own path, timed piece by piece.
	var b := bscene.instantiate()
	b.set("rows", rows)
	b.set("cols", cols)
	b.set("floors", floors)
	b.set("stream_interiors", stream)
	ReplicaDress.prepare(b)
	var t := Time.get_ticks_usec()
	add_child(b)
	out.append("building enters the tree (no apartments yet): %.1f ms" % _ms(t))
	t = Time.get_ticks_usec()
	b.call("_create_apartments")
	out.append("_create_apartments (%d apartments, %s): %.1f ms" % [rows * cols * floors,
			"shells" if stream else "full interiors", _ms(t)])
	t = Time.get_ticks_usec()
	ApartmentPlates.show(b.get_node("MultiMeshInstance3D"), [], "", "")
	out.append("ApartmentPlates.show: %.1f ms" % _ms(t))
	t = Time.get_ticks_usec()
	(b.get("_furniture") as Object).call("show_once", b.call("_rooms"))
	out.append("furniture show_once: %.1f ms" % _ms(t))
	out.append("building now: %d nodes" % b.find_children("*", "", true, false).size())
	for again in 2:
		var b2 := bscene.instantiate()
		b2.set("rows", rows)
		b2.set("cols", cols)
		b2.set("floors", floors)
		b2.set("stream_interiors", stream)
		ReplicaDress.prepare(b2)
		add_child(b2)
		t = Time.get_ticks_usec()
		b2.call("_create_apartments")
		out.append("  another building's _create_apartments: %.1f ms" % _ms(t))
	# 1b. _create_apartments' steps, by hand on a fresh building.
	var b3 := bscene.instantiate()
	b3.set("rows", rows)
	b3.set("cols", cols)
	b3.set("floors", floors)
	b3.set("stream_interiors", stream)
	ReplicaDress.prepare(b3)
	add_child(b3)
	var tpl: Node = b3.get_node("MultiMeshInstance3D/0-0-0")
	var mmi: Node = b3.get_node("MultiMeshInstance3D")
	t = Time.get_ticks_usec()
	var streamer: Node = null
	if stream:
		streamer = InteriorStreamer.take_from(tpl, mmi, Vector3.ONE)
		if streamer != null:
			b3.add_child(streamer)
	out.append("  step: InteriorStreamer.take_from + add: %.1f ms" % _ms(t))
	t = Time.get_ticks_usec()
	var copier := SpawnBuilding.ApartmentCopier.new(tpl, true)
	out.append("  step: pack the template: %.1f ms" % _ms(t))
	var made: Array[Node] = []
	t = Time.get_ticks_usec()
	for k in rows * cols * floors - 1:
		made.append(copier.copy())
	out.append("  step: %d copies: %.1f ms" % [made.size(), _ms(t)])
	t = Time.get_ticks_usec()
	for k in made.size():
		var m: Node3D = made[k]
		m.name = "x-%d" % k
		m.position.z = k * 2.6
		mmi.add_child(m)
	out.append("  step: add them under the building: %.1f ms" % _ms(t))
	t = Time.get_ticks_usec()
	BuildingWalkways.build(b3, rows, cols, floors, float(b3.get("x_spacing")), float(b3.get("z_spacing")),
			float(b3.get("y_spacing")))
	out.append("  step: walkways: %.1f ms" % _ms(t))
	# 2. One apartment, made apart: the template as the building copies it (after the streamer took its
	# interior), a copy against an instance, and entering the tree.
	var template: Node = b.get_node("MultiMeshInstance3D/0-0-0")
	var n := 23
	var copies: Array[Node] = []
	t = Time.get_ticks_usec()
	for k in n:
		copies.append(template.duplicate(Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS))
	out.append("%d copies of the template (out of the tree): %.1f ms, %d nodes each" % [n, _ms(t),
			copies[0].find_children("*", "", true, false).size()])
	var fresh: Array[Node] = []
	t = Time.get_ticks_usec()
	for k in n:
		fresh.append(ascene.instantiate())
	out.append("%d fresh instances of container_apartment (full, out of the tree): %.1f ms, %d nodes each" % [n,
			_ms(t), fresh[0].find_children("*", "", true, false).size()])
	out.append("%d copies enter the tree: %.1f ms" % [n, _enter(copies)])
	out.append("%d fresh instances enter the tree: %.1f ms" % [n, _enter(fresh)])
	# 2b. What a copy costs node by node: each node of the template copied with its subtree, 50 times.
	var per: Array = []
	for node in [template] + template.find_children("*", "", true, false):
		t = Time.get_ticks_usec()
		for k in 50:
			node.duplicate(Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS).free()
		per.append([_ms(t) / 50.0, "%s %s (%s, %d below)" % [node.get_class(), node.name,
				(node.get_script() as Script).resource_path.get_file() if node.get_script() != null else "-",
				node.find_children("*", "", true, false).size()]])
	per.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	for p in per.slice(0, 14):
		out.append("  copy of %s: %.3f ms" % [p[1], p[0]])
	t = Time.get_ticks_usec()
	var bw := Node3D.new()
	add_child(bw)
	BuildingWalkways.build(bw, rows, cols, floors, float(b.get("x_spacing")), float(b.get("z_spacing")),
			float(b.get("y_spacing")))
	out.append("BuildingWalkways.build alone: %.1f ms" % _ms(t))
	bw.free()
	# 2c. The template packed once as a scene (its root no longer an instance: its interior stays out), then
	# instanced: the same nodes as a copy?
	t = Time.get_ticks_usec()
	var one := template.duplicate(Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	for node in [one] + one.find_children("*", "", true, false):
		node.scene_file_path = ""
		if node != one:
			node.owner = one
		for g: StringName in node.get_groups():
			if not str(g).begins_with("_"):
				node.remove_from_group(g)
				node.add_to_group(g, true)
	var packed := PackedScene.new()
	var err := packed.pack(one)
	one.free()
	out.append("pack the template once: %.1f ms (%s)" % [_ms(t), error_string(err)])
	var inst: Array[Node] = []
	t = Time.get_ticks_usec()
	for k in n:
		inst.append(packed.instantiate())
	out.append("%d instances of the packed template: %.1f ms, %d nodes each" % [n, _ms(t),
			inst[0].find_children("*", "", true, false).size()])
	var ref := template.duplicate(Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	out.append("same nodes as a copy: %s" % str(_shape(inst[0]) == _shape(ref)))
	if _shape(inst[0]) != _shape(ref):
		var a := _shape(inst[0])
		var c := _shape(ref)
		for k in maxi(a.size(), c.size()):
			var x: String = a[k] if k < a.size() else "-"
			var y: String = c[k] if k < c.size() else "-"
			if x != y:
				out.append("    packed %s | copy %s" % [x, y])
	ref.free()
	out.append("%d packed instances enter the tree: %.1f ms" % [n, _enter(inst)])
	# 3. The copies entering the tree with each kind of script left out (and with none at all).
	var kinds := {}
	for node in template.find_children("*", "", true, false):
		var sc := node.get_script() as Script
		if sc != null:
			kinds[sc.resource_path] = int(kinds.get(sc.resource_path, 0)) + 1
	var base := _enter(_copies(template, n, ""))
	out.append("baseline again: %.1f ms" % base)
	for path: String in kinds:
		var ms := _enter(_copies(template, n, path))
		out.append("  without %s (%d a apartment): %.1f ms (%+.1f)" % [path.get_file(), kinds[path], ms, ms - base])
	var bare := _enter(_copies(template, n, "*"))
	out.append("  without any script: %.1f ms (%+.1f)" % [bare, bare - base])
	for l in out:
		print("[AptProbe] " + l)
	get_tree().quit()


func _ms(since: int) -> float:
	return (Time.get_ticks_usec() - since) / 1000.0


## [param n] copies of [param template], the nodes of script [param strip] ("*": every script) without it.
func _copies(template: Node, n: int, strip: String) -> Array[Node]:
	var out: Array[Node] = []
	for k in n:
		var c := template.duplicate(Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
		if strip != "":
			for node in c.find_children("*", "", true, false):
				var sc := node.get_script() as Script
				if sc != null and (strip == "*" or sc.resource_path == strip):
					node.set_script(null)
		out.append(c)
	return out


## Adds [param nodes] under a holder in the tree: the time it took (ms); then frees them.
func _enter(nodes: Array[Node]) -> float:
	var holder := Node3D.new()
	add_child(holder)
	var t := Time.get_ticks_usec()
	for node in nodes:
		holder.add_child(node)
	var ms := _ms(t)
	holder.free()
	return ms


## The nodes under [param root] as lines: path, class, script, transform, groups, visibility.
func _shape(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for node in [root] + root.find_children("*", "", true, false):
		var sc := node.get_script() as Script
		var xf := str((node as Node3D).transform) if node is Node3D else ""
		var vis := str((node as Node3D).visible) if node is Node3D else ""
		var groups: Array = node.get_groups().filter(func(g: StringName) -> bool: return not str(g).begins_with("_"))
		var metas := {}
		for m: StringName in node.get_meta_list():
			metas[m] = str(node.get_meta(m))
		var conns := 0
		for sig: Dictionary in node.get_signal_list():
			conns += node.get_signal_connection_list(sig.name).size()
		out.append("%s %s %s %s %s %s metas=%s conns=%d" % [root.get_path_to(node), node.get_class(),
				sc.resource_path if sc != null else "", xf, str(groups), vis, str(metas), conns])
		for prop: Dictionary in node.get_property_list():
			if int(prop.usage) & PROPERTY_USAGE_STORAGE and str(prop.name) not in ["owner", "scene_file_path"]:
				out.append("  %s.%s = %s" % [root.get_path_to(node), prop.name, str(node.get(prop.name))])
	return out
