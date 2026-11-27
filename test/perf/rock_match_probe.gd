extends Node
## The colliding Nova rocks round one place of tarsis_3, as the server lays them (collision grid, solid only) and
## as the client does (its mesh's grid, full laying): any rock one side has and not the other is a rock seen without
## a collider, or a collider without a rock.
##   <godot> --headless --path . res://test/perf/rock_match_probe.tscn -- at=4450819,2673741,3675817 r=40

const HeadlessPlanet := preload("res://tools/planettech/headless_planet.gd")
const NovaRockCollision := preload("res://scenes/planet/nova/nova_rock_collision.gd")


func _ready() -> void:
	var args := {}
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var xyz: PackedStringArray = str(args.get("at", "4450819,2673741,3675817")).split(",")
	var at := Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
	var within := float(args.get("r", "40"))
	var data := HeadlessPlanet.planet_data("tarsis_3")
	data.apply_chunk_manifest()
	data.remote_source = RemoteTileSource.for_planet("tarsis_3")
	data.attach_remote_modifiers()
	data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions("tarsis_3"))
	data.warm_mountains()
	data.warm_fumaroles()
	var body := NovaBody.open_body("tarsis_3")
	data.nova = body
	data.nova_relief = body
	var nside := 1 << data.max_quadtree_depth
	var ipix := HEALPix.vec2pix_nest(nside, at.normalized())
	var center := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, ipix) * data.radius)
	print("[Match] n%d p%d, place %.0f m from the chunk centre" % [nside, ipix, at.distance_to(center)])
	# Server.
	var t0 := Time.get_ticks_usec()
	var sdescs := NovaRockCollision.layer_descs(body, data.radius, data.default_rock())
	print("[Match] server layers and their models' collision made in %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var shape := PlanetChunk.generate_collision_shape_healpix(data, nside, ipix, data.collision_col_res_for(nside))
	var sgrid: PackedVector3Array = shape.get_meta("nova_grid")
	t0 = Time.get_ticks_usec()
	var server := NovaRockCollision.lay(sdescs, data, body, nside, ipix, sgrid, center)
	var t1 := Time.get_ticks_usec()
	var rocks_body := NovaRockCollision.make_body(server, "probe", center)
	print("[Match] lay %.0f ms, body of %d parts %.1f ms" % [(t1 - t0) / 1000.0, server.size(),
			(Time.get_ticks_usec() - t1) / 1000.0])
	if rocks_body != null:
		rocks_body.free()
	# Client: its finest mesh, unstitched and stitched every way it can be.
	var cdescs := NovaScatter.layer_descs(body, data.radius, data.default_rock(), true)
	for stitch in [0, 15]:
		var mesh := PlanetChunk.generate_mesh_healpix(data, nside, ipix, data.get_resolution_for_lod(0, nside), center, {}, stitch)
		var cgrid: PackedVector3Array = mesh.get_meta("nova_grid")
		var res := int(mesh.get_meta("nova_res"))
		var zones := NovaScatter.zone_context(data, nside, ipix)
		var laid := NovaScatter.lay_chunk(cdescs, nside, ipix, res, cgrid, mesh.get_meta("nova_vid"), center, zones)
		var client := NovaScatter.solid_parts(laid)
		var diff := 0
		for k in mini(sgrid.size(), cgrid.size()):
			diff += int(sgrid[k] != cgrid[k])
		print("[Match] stitch %d: grids res %d/%d, %d of %d points differ; server %d colliders, client %d solid rocks" % [
				stitch, roundi(sqrt(float(sgrid.size()))) - 1, res, diff, sgrid.size(), server.size(), client.size()])
		_compare(server, client, at - center, within)
	if data.remote_source != null:
		data.remote_source.stop()
	get_tree().quit()


func _compare(server: Array, client: Array, local: Vector3, within: float) -> void:
	var lone_s := 0
	var lone_c := 0
	for s: Array in server:
		var p: Vector3 = (s[0] as Transform3D).origin
		var best := INF
		for c: Array in client:
			best = minf(best, p.distance_to((c[0] as Transform3D).origin))
		if best > 0.05:
			lone_s += 1
			if p.distance_to(local) < within:
				print("[Match]   server only, %.1f m from the place: shape %s, nearest client rock %.2f m (%s)" % [
						p.distance_to(local), (s[1] as Shape3D).get_class(), best, (s[3] as Mesh).get_meta("nova_path", "?")])
	for c: Array in client:
		var p: Vector3 = (c[0] as Transform3D).origin
		var best := INF
		for s: Array in server:
			best = minf(best, p.distance_to((s[0] as Transform3D).origin))
		if best > 0.05:
			lone_c += 1
	var near := 0
	for s: Array in server:
		if (s[0] as Transform3D).origin.distance_to(local) < within:
			near += 1
			print("[Match]   collider %.1f m from the place: shape %s" % [(s[0] as Transform3D).origin.distance_to(local),
					(s[1] as Shape3D).get_class()])
	print("[Match]   %d colliders within %.0f m; server-only %d, client-only %d" % [near, within, lone_s, lone_c])
