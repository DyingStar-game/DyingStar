extends Node
## How much of each Nova rock model's collision box (its AABB, NovaScatter.solid_box) the rock fills.

func _ready() -> void:
	var out := PackedStringArray()
	var dumps: Array = []
	var f := FileAccess.open("res://nova/bodies/tarsis_3/_default.tres", FileAccess.READ)
	var text := f.get_as_text()
	var re := RegEx.new()
	re.compile("\"scatter/s(\\d)/meshes\": \\[([^\\]]*)\\]")
	var pr := RegEx.new()
	pr.compile("res://[^\"]+")
	for m in re.search_all(text):
		for p in pr.search_all(m.get_string(2)):
			var path := p.get_string()
			var mesh := NovaScatter.load_mesh(path)
			if mesh == null:
				out.append("%s null" % path); continue
			var aabb := mesh.get_aabb()
			var authored := NovaScatter.scene_shapes(path)
			var kinds := {}
			var points := 0
			for part: Array in authored:
				kinds[(part[0] as Shape3D).get_class()] = int(kinds.get((part[0] as Shape3D).get_class(), 0)) + 1
				if part[0] is ConvexPolygonShape3D:
					points += (part[0] as ConvexPolygonShape3D).points.size()
			out.append("s%s %s: model %s surfaces %d | scene shapes %d %s, %d hull points" % [m.get_string(1),
					path.get_file(), str(aabb.size.snappedf(0.01)), mesh.get_surface_count(), authored.size(), str(kinds),
					points])
			var vol := 0.0
			var tris := 0
			for s in mesh.get_surface_count():
				var arr := mesh.surface_get_arrays(s)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				for i in range(0, idx.size(), 3):
					vol += v[idx[i]].dot(v[idx[i + 1]].cross(v[idx[i + 2]])) / 6.0
					tris += 1
			var t0 := Time.get_ticks_usec()
			var hull := mesh.create_convex_shape(true, true) as ConvexPolygonShape3D
			var t_hull := (Time.get_ticks_usec() - t0) / 1000.0
			var hv := _vol(hull.get_debug_mesh())
			var shifted := _vol(mesh, Vector3(10, 20, 30))
			var box := aabb.size.x * aabb.size.y * aabb.size.z
			var hull_pts: Array = Array(hull.points).map(func(q: Vector3) -> Array: return [q.x, q.y, q.z])
			var dump := {"path": path, "slot": int(m.get_string(1)), "hull": hull_pts, "v": [], "i": []}
			for s2 in mesh.get_surface_count():
				var arr2 := mesh.surface_get_arrays(s2)
				var base: int = dump.v.size()
				for q: Vector3 in arr2[Mesh.ARRAY_VERTEX]:
					dump.v.append([q.x, q.y, q.z])
				for k: int in arr2[Mesh.ARRAY_INDEX]:
					dump.i.append(base + k)
			dumps.append(dump)
			out.append("    hull fill of box=%.0f%% mesh/hull=%.0f%% closed=%s hull_ms=%.1f" % [100.0 * hv / box,
					100.0 * absf(vol) / hv, str(absf(shifted - vol) < 0.01 * absf(vol)), t_hull])
			out.append("s%s %-34s size=%s fill=%.0f%% tris=%d hull_pts=%d ground_y=%.2f" % [m.get_string(1),
					path.get_file(), str(aabb.size.snappedf(0.01)), 100.0 * absf(vol) / box, tris,
					hull.points.size() if hull else -1, aabb.position.y])
	var w := FileAccess.open("user://rock_fill.txt", FileAccess.WRITE)
	w.store_string("\n".join(out) + "\n")
	w.close()
	var j := FileAccess.open("user://rock_fill.json", FileAccess.WRITE)
	j.store_string(JSON.stringify(dumps))
	j.close()
	get_tree().quit()


func _vol(mesh: Mesh, shift := Vector3.ZERO) -> float:
	var vol := 0.0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			idx.resize(v.size())
			for i in v.size():
				idx[i] = i
		for i in range(0, idx.size() - 2, 3):
			var a := v[idx[i]] + shift
			vol += a.dot((v[idx[i + 1]] + shift).cross(v[idx[i + 2]] + shift)) / 6.0
	return absf(vol)
