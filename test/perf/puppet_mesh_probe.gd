extends Node
## Counts the geometry a single human puppet carries (surfaces, vertices, triangles, LODs, skeleton
## bones), to size what 30 remote avatars cost the renderer. Output: user://puppet_mesh_probe.txt

func _ready() -> void:
	var out := FileAccess.open("user://puppet_mesh_probe.txt", FileAccess.WRITE)
	for path in ["res://scenes/_universe/characters/humanoids/human_puppet.tscn",
			"res://assets/_universe/characters/humanoids/astronaut/astronaut.res",
			"res://scenes/player/player.tscn"]:
		var ps: PackedScene = load(path)
		if ps == null:
			out.store_line("PROBE %s: load failed" % path)
			continue
		var inst := ps.instantiate()
		var total_tris := 0
		var total_verts := 0
		var surfaces := 0
		var meshes := 0
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var m: Mesh = (mi as MeshInstance3D).mesh
			if m == null: continue
			meshes += 1
			for s in range(m.get_surface_count()):
				surfaces += 1
				var arrays := m.surface_get_arrays(s)
				var v: int = arrays[Mesh.ARRAY_VERTEX].size() if arrays[Mesh.ARRAY_VERTEX] != null else 0
				var idx = arrays[Mesh.ARRAY_INDEX]
				var t: int = (idx.size() / 3) if idx != null else v / 3
				total_verts += v
				total_tris += t
				var lods := ""
				if m is ArrayMesh:
					lods = " lods=%d" % (m as ArrayMesh).surface_get_blend_shape_arrays(s).size()
				out.store_line("PROBE %s mesh=%s surf=%d verts=%d tris=%d mat=%s skin=%s" % [
					path.get_file(), mi.name, s, v, t,
					m.surface_get_material(s).resource_path.get_file() if m.surface_get_material(s) else "-",
					(mi as MeshInstance3D).skin != null])
		var skels := inst.find_children("*", "Skeleton3D", true, false)
		for sk in skels:
			out.store_line("PROBE %s skeleton=%s bones=%d" % [path.get_file(), sk.name, (sk as Skeleton3D).get_bone_count()])
		var lights := inst.find_children("*", "Light3D", true, false)
		for l in lights:
			out.store_line("PROBE %s light=%s shadow=%s visible=%s" % [path.get_file(), l.name, (l as Light3D).shadow_enabled, l.visible])
		out.store_line("PROBE %s TOTAL meshes=%d surfaces=%d verts=%d tris=%d nodes=%d" % [
			path.get_file(), meshes, surfaces, total_verts, total_tris, inst.find_children("*", "", true, false).size() + 1])
		inst.free()
	out.close()
	get_tree().quit()
