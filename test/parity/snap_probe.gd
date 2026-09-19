extends Node
## Snap probe: PlanetTerrain.compute_surface_transform on a ROTATED planet
## (editor flight / tilt) must land on the same altitude as the sampler read
## in the body frame. Run: godot --headless --path . res://test/parity/snap_probe.tscn
func _ready() -> void:
	var data := PlanetData.new()
	data.planet_name = "tarsis_3"
	data.chunk_export_depth = 10
	data.chunk_resolution = 32
	data.max_quadtree_depth = 13
	data.chunk_heightmaps_dir = "assets/qgis/export/tarsis_3_chunks"
	data.chunk_heightmap_res = 32
	data.apply_chunk_manifest()
	data.ensure_queries_loaded()
	data.warm_mountains()

	var body := Node3D.new()
	body.transform = Transform3D(Basis(Vector3(0.3, 0.8, -0.5).normalized(), 1.1), Vector3(4464613.9, 2667284.1, -3668506.2))
	add_child(body)
	var terrain := PlanetTerrain.new()
	terrain.planet_data = data
	body.add_child(terrain)
	var obj := Node3D.new()
	add_child(obj)

	var worst := 0.0
	for ll in [Vector2(-39.5881896, 24.76178135), Vector2(-39.68055545, 24.86168335), Vector2(-37.00874755, 26.31991855), Vector2(10.0, -40.0)]:
		var local_dir: Vector3 = HEALPix.lonlat2vec(ll.x, ll.y)
		var expected := data.sample_height_for_direction(local_dir)
		# Object hovering 500 m above sea level along that body direction.
		obj.global_position = terrain.global_transform * (local_dir * (data.radius + 500.0))
		obj.global_transform.basis = Basis(Vector3.UP, 0.7)
		var t := terrain.compute_surface_transform(obj)
		var got_local: Vector3 = terrain.global_transform.affine_inverse() * t.origin
		var got_h := got_local.length() - data.radius
		var dir_err := got_local.normalized().angle_to(local_dir)
		var up_err := t.basis.y.normalized().angle_to((terrain.global_transform.basis * local_dir).normalized())
		worst = maxf(worst, absf(got_h - expected))
		print("PROBE ll=%s expected=%.2f snapped=%.2f dir_err=%.7f up_err=%.7f" % [ll, expected, got_h, dir_err, up_err])
	print("PROBE worst=%.3f m %s" % [worst, "OK" if worst < 0.05 else "FAIL"])
	get_tree().quit()
