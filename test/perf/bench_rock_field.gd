## Banc de mesure du terrain rocheux (RockFieldRelief) par échantillon de hauteur.
##
## Pourquoi : un champ rocheux s'ajoute dans sample_height_for_direction, soit
## ~5 appels par sommet de chaque chunk fin qu'il couvre. Ce banc mesure un
## appel MountainSetNative.Rock (C#) et la référence GDScript, à côté d'une zone
## de montagne (Offset) pour l'ordre de grandeur. Cible du plan : ≤ +10 µs par
## échantillon en C#, comme un volcan.
##
## Un test GUT et non un `--script`, pour la même raison que bench_rock_impurity.gd.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/perf/bench_rock_field.gd -gexit
extends GutTest

const RADIUS := 3467000.0
const N := 20000
const PITCH := 25.0


func _field(style: String, over: Dictionary = {}) -> RockFieldRelief.Field:
	var props := RockFieldRelief.resolve_debug("very_rugged", style, over)
	var rec := RockFieldRelief.debug_record(Vector2(10.0, 20.0), 5.0, RADIUS, props)
	rec["coverage"] = "full"
	return RockFieldRelief.prepare(rec)


func test_bench() -> void:
	var dirs := PackedVector3Array()
	var c := HEALPix.lonlat2vec(10.0, 20.0)
	var u := c.cross(Vector3.UP).normalized()
	var v := c.cross(u)
	for i in N:
		dirs.append((c * RADIUS + u * fmod(i * 37.0, 4000.0) + v * fmod(i * 53.0, 4000.0)).normalized())
	var mtn := MountainRelief.prepare_zone({"coverage": "full", "amplitude_m": 1200.0,
			"wavelength_m": 8000.0, "octaves": 7, "ridge": 0.8, "exponent": 1.5, "seed": 3})
	var mset_m: RefCounted = MountainRelief.build_set([mtn], [])
	var sink := 0.0
	var t0 := Time.get_ticks_usec()
	for i in N:
		sink += mset_m.Offset(dirs[i], RADIUS, PITCH)
	var t_mtn := float(Time.get_ticks_usec() - t0) / N
	for style in ["slabs", "yardang", "strata"]:
		var f := _field(style)
		var mset: RefCounted = MountainRelief.build_set([], [], [], [f])
		t0 = Time.get_ticks_usec()
		for i in N:
			sink += mset.Rock(dirs[i], RADIUS, PITCH, 1000.0 + i * 0.01)
		var t_cs := float(Time.get_ticks_usec() - t0) / N
		t0 = Time.get_ticks_usec()
		for i in 2000:
			sink += RockFieldRelief.offset(dirs[i], RADIUS, [f], PITCH, 1000.0 + i * 0.01)
		var t_gd := float(Time.get_ticks_usec() - t0) / 2000
		gut.p("[RockBench] %-8s C# %.2f µs/sample, GDScript %.1f µs/sample (mountain zone C# %.2f µs)"
				% [style, t_cs, t_gd, t_mtn])
	# Where the time goes: blocks only, buttes only, nothing (call overhead).
	var parts := {"blocks only": {"butte_rate": 0.0}, "buttes only": {"step_m": 0.0,
			"joint_depth_m": 0.0}, "empty": {"butte_rate": 0.0, "step_m": 0.0, "joint_depth_m": 0.0}}
	for name: String in parts:
		var mset: RefCounted = MountainRelief.build_set([], [], [], [_field("slabs", parts[name])])
		t0 = Time.get_ticks_usec()
		for i in N:
			sink += mset.Rock(dirs[i], RADIUS, PITCH, 1000.0 + i * 0.01)
		gut.p("[RockBench] %-12s C# %.2f µs/sample" % [name, float(Time.get_ticks_usec() - t0) / N])
	# Scree of a fine chunk (res 32, 25 m pitch), fully inside a very rugged field.
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var rock := PackedFloat32Array()
	for yi in 33:
		for xi in 33:
			verts.append(Vector3(xi * 25.0, sin(xi * 0.4) * 20.0, yi * 25.0))
			normals.append(Vector3(-cos(xi * 0.4) * 0.8, 1.0, 0.0).normalized())
			rock.append_array([1.0, 10.0, 4.0, 0.0])
	t0 = Time.get_ticks_usec()
	var scree := RockFieldScree.place(verts, normals, PackedColorArray(), rock, 32, 12345, Vector3.UP)
	gut.p("[RockBench] scree place: %d rocks in %.1f ms" % [scree.size() / RockFieldScree.STRIDE,
			float(Time.get_ticks_usec() - t0) / 1000.0])
	t0 = Time.get_ticks_usec()
	var packed := RockFieldScree.pack(scree)
	gut.p("[RockBench] scree pack (worker): %.1f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	var mesh := ArrayMesh.new()
	mesh.set_meta("rock_scree", packed)
	t0 = Time.get_ticks_usec()
	var node := RockFieldScree.build(mesh, Vector3.ZERO)
	gut.p("[RockBench] scree build (main thread): %.1f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	node.free()
	assert_true(is_finite(sink))
