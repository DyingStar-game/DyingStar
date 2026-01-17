@tool
extends SceneTree

func _init() -> void:
	var dir_path := "user://chunk_cache/tarsis_5_1"
	var d := DirAccess.open(dir_path)
	if d == null:
		print("Cannot open cache dir")
		quit()
		return
	d.list_dir_begin()
	var f := d.get_next()
	var expected_radius := 850667.0
	var max_h := 1100.0
	var off := -150.0
	var min_r := expected_radius + max_h
	var max_r := expected_radius + off
	while f != "":
		if f.ends_with("_mesh.res"):
			var mesh_res := load(dir_path + "/" + f) as ArrayMesh
			if mesh_res:
				for s in range(mesh_res.get_surface_count()):
					var arr := mesh_res.surface_get_arrays(s)
					var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
					if verts.size() == 0:
						continue
					# Vertices are local; mesh is placed at chunk_center in scene.
					# Read center from filename pattern is hard; just print first vertex magnitude.
					var c := Vector3.ZERO
					for v in verts:
						c += v
					c /= float(verts.size())
					var dists: Array = []
					for v in verts:
						# Local vertex relative to chunk center; we want to recover world distance.
						# We don't have chunk_center here, so just print local center magnitude as a hint.
						pass
					print("%s: surf%d verts=%d local_center=%s |c|=%.1f" % [f, s, verts.size(), c, c.length()])
		f = d.get_next()
	quit()
