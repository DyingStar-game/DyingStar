extends Node3D
## What a prop scene costs the client when it arrives, headless: reading it, instancing it, entering the tree
## (its _ready) dressed as a replica (ReplicaDress), and the first physics step after (Jolt builds the shapes
## of the bodies added since the last step there), with what its collision is made of.
##   <godot> --headless --path . res://test/perf/prop_spawn_probe.tscn -- scenes=a.tscn,b.tscn [count=3]
##   [set=rows:2,cols:6,floors:2] (properties set on each instance before it enters the tree)

func _ready() -> void:
	var args := {}
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var paths: PackedStringArray = str(args.get("scenes", "")).split(",", false)
	var count := int(args.get("count", "3"))
	var props := {}
	for kv: String in str(args.get("set", "")).split(",", false):
		props[kv.get_slice(":", 0)] = str_to_var(kv.get_slice(":", 1))
	await _settle()
	var out := PackedStringArray()
	for p: String in paths:
		var path := p if p.begins_with("res://") else "res://" + p
		var t0 := Time.get_ticks_usec()
		var scene := load(path) as PackedScene
		var load_ms := (Time.get_ticks_usec() - t0) / 1000.0
		if scene == null:
			out.append("%s: not found" % path)
			continue
		for k in count:
			t0 = Time.get_ticks_usec()
			var node := scene.instantiate()
			var t1 := Time.get_ticks_usec()
			for key: String in props:
				node.set(key, props[key])
			ReplicaDress.prepare(node)
			if node is Node3D:
				(node as Node3D).position = Vector3(300.0 * (k + 1), 0.0, 0.0)
			add_child(node)
			var t2 := Time.get_ticks_usec()
			var step_ms := await _physics_step_ms()
			var shapes := _collision(node)
			out.append("%s #%d: load %.1f, instantiate %.1f, enter tree %.1f, next physics step %.1f ms | %s" % [
					path.get_file(), k, load_ms if k == 0 else 0.0, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, step_ms,
					shapes])
	var base := await _physics_step_ms()
	out.append("an empty physics step: %.1f ms" % base)
	for l in out:
		print("[PropProbe] " + l)
	get_tree().quit()


func _settle() -> void:
	for k in 10:
		await get_tree().physics_frame


## Wall time from the next physics frame's start to the frame after: its scripts and its step.
func _physics_step_ms() -> float:
	await get_tree().physics_frame
	var t := Time.get_ticks_usec()
	await get_tree().process_frame
	return (Time.get_ticks_usec() - t) / 1000.0


func _collision(node: Node) -> String:
	var bodies := 0
	var shapes := {}
	var faces := 0
	var csg := 0
	for n in node.find_children("*", "", true, false) + [node]:
		if n is CollisionObject3D:
			bodies += 1
		if n is CollisionShape3D and (n as CollisionShape3D).shape != null:
			var s := (n as CollisionShape3D).shape
			shapes[s.get_class()] = int(shapes.get(s.get_class(), 0)) + 1
			if s is ConcavePolygonShape3D:
				faces += (s as ConcavePolygonShape3D).get_faces().size() / 3
		if n is CSGShape3D and (n as CSGShape3D).use_collision and (n as CSGShape3D).is_root_shape():
			csg += 1
	var kinds := {}
	for n in node.find_children("*", "CollisionObject3D", true, false) + [node]:
		if not (n is CollisionObject3D):
			continue
		var kind: String = n.get_class()
		if n is Area3D:
			kind += "(monitoring)" if (n as Area3D).monitoring else "(passive)"
		elif n is RigidBody3D:
			kind += "(frozen)" if (n as RigidBody3D).freeze else "(live)"
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	var scripted := {}
	for n in node.find_children("*", "", true, false):
		var sc := n.get_script() as Script
		if sc != null:
			var f := sc.resource_path.get_file()
			scripted[f] = int(scripted.get(f, 0)) + 1
	var top := scripted.keys()
	top.sort_custom(func(a: String, b: String) -> bool: return scripted[a] > scripted[b])
	var top_s := PackedStringArray()
	for f: String in top.slice(0, 6):
		top_s.append("%s=%d" % [f, scripted[f]])
	return "%d bodies %s, shapes %s, %d concave faces, %d CSG roots with collision, %d nodes, scripts %s" % [bodies,
			str(kinds), str(shapes), faces, csg, node.find_children("*", "", true, false).size(), ", ".join(top_s)]
