@tool
extends SceneTree
## One-shot: report vertex / triangle counts for the mining-rock mesh, so the "is it the
## triangles?" half of the rock-spawn FPS question can be answered with a number.
## Run: godot --headless --script res://tools/perf/mesh_stats.gd
func _init() -> void:
	for path in [
		"res://assets/_universe/environment/terrain/rocks/rock_mining_001.mesh",
	]:
		var m: Mesh = load(path)
		if m == null:
			print("MISS ", path)
			continue
		var verts := 0
		var tris := 0
		for i in m.get_surface_count():
			var a: Array = m.surface_get_arrays(i)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			verts += v.size()
			tris += (idx.size() / 3) if idx.size() > 0 else (v.size() / 3)
		print("%s  surfaces=%d verts=%d tris=%d aabb=%s" % [path.get_file(), m.get_surface_count(), verts, tris, m.get_aabb().size])
	quit()
