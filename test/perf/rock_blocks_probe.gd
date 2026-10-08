extends Node3D
## Offline look at the rock blocks of a rocky_terrain field (rock_blocks.gdshaderinc):
## a floor and a wall carrying CUSTOM1 = (intensity, small-block size,
## level + 8 × type, altitude),
## under the two terrain shaders side by side (terrain_biome left, the corundum
## planet_surface material right). Renders a few frames, saves a PNG, quits.
##
## Needs a display (the dummy headless renderer compiles no shader):
##     DISPLAY=:0 godot --path . res://test/perf/rock_blocks_probe.tscn
## ROCK_PROBE_OUT = output PNG (default user://rock_blocks_probe.png),
## ROCK_PROBE_SIZE = small-block size in metres (default 4), ROCK_PROBE_INTENSITY =
## the field's intensity (default 1; 0 = the shaders without rock, for comparison),
## ROCK_PROBE_TYPE = the rock type (RockFieldRelief.STYLES name, default chalk).

const BIOME_MAT := "res://assets/_universe/environment/terrain/terrain_biome.tres"
const SURFACE_MAT := "res://assets/_universe/_shared/materials/mat_mineral_corundum_pure/corundum_outcrop_surface.tres"
const SIDE := 40.0
const RES := 32


func _ready() -> void:
	RenderingServer.global_shader_parameter_set("planet_hex_quality", 2)
	var size := float(OS.get_environment("ROCK_PROBE_SIZE")) if OS.has_environment("ROCK_PROBE_SIZE") else 4.0
	var mats: Array[String] = [BIOME_MAT, SURFACE_MAT]
	for k in mats.size():
		var mi := MeshInstance3D.new()
		var amount := float(OS.get_environment("ROCK_PROBE_INTENSITY")) \
				if OS.has_environment("ROCK_PROBE_INTENSITY") else 1.0
		mi.mesh = _floor_and_wall(size, amount)
		mi.material_override = load(mats[k])
		mi.position = Vector3((k - 0.5) * (SIDE + 6.0), 0.0, 0.0)
		add_child(mi)
		mi.set_instance_shader_parameter("chunk_origin_mod", Vector3(1000.0 + k * 50.0, 0.0, 1000.0))
		mi.set_instance_shader_parameter("chunk_center_local", Vector3(0.0, 6356000.0, 0.0))
		# The field's scree (RockFieldScree), from the floor's grid.
		var arr := mi.mesh.surface_get_arrays(0)
		var grid_n := (RES + 1) * (RES + 1)
		var mesh := ArrayMesh.new()
		mesh.set_meta("rock_scree", RockFieldScree.pack(RockFieldScree.place(
				(arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).slice(0, grid_n),
				(arr[Mesh.ARRAY_NORMAL] as PackedVector3Array).slice(0, grid_n),
				_floor_colors(grid_n),
				(arr[Mesh.ARRAY_CUSTOM1] as PackedFloat32Array).slice(0, grid_n * 4), RES, k,
				Vector3.UP)))
		var scree := RockFieldScree.build(mesh, mi.position)
		if scree:
			add_child(scree)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 40.0, 0.0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.35, 0.35, 0.4)
	add_child(env)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 28.0, 46.0)
	add_child(cam)
	cam.look_at(Vector3(0.0, 4.0, -6.0))
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var out := OS.get_environment("ROCK_PROBE_OUT") if OS.has_environment("ROCK_PROBE_OUT") \
			else "user://rock_blocks_probe.png"
	img.save_png(out)
	print("[RockProbe] saved %s" % out)
	get_tree().quit()


func _type() -> int:
	var name := OS.get_environment("ROCK_PROBE_TYPE") if OS.has_environment("ROCK_PROBE_TYPE") \
			else "chalk"
	return maxi(RockFieldRelief.STYLES.find(name), 0)


## A beige ground colour for every floor vertex (what a chunk bakes in COLOR).
func _floor_colors(n: int) -> PackedColorArray:
	var c := PackedColorArray()
	c.resize(n)
	c.fill(Color(0.85, 0.75, 0.6))
	return c


## A SIDE × SIDE floor, and a wall of the same width standing on its far edge,
## every vertex with CUSTOM1 = (amount, size, level 3 + 8 × type, altitude = y).
func _floor_and_wall(size: float, amount: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var custom := PackedFloat32Array()
	var c0 := PackedFloat32Array()
	var idx := PackedInt32Array()
	for part in 2:
		var base := verts.size()
		for y in RES + 1:
			for x in RES + 1:
				var u := (float(x) / RES - 0.5) * SIDE
				var v := float(y) / RES * SIDE
				if part == 0:
					verts.append(Vector3(u, 0.0, SIDE * 0.5 - v))
					normals.append(Vector3.UP)
				else:
					verts.append(Vector3(u, v * 0.9, -SIDE * 0.5))
					normals.append(Vector3.BACK)
				var p: Vector3 = verts[verts.size() - 1]
				custom.append_array([amount, size, float(3 + 8 * _type()), p.y])
				c0.append_array([0.0, 0.0, 0.0])
		for y in RES:
			for x in RES:
				var i := base + y * (RES + 1) + x
				idx.append_array([i, i + 1, i + RES + 1, i + 1, i + RES + 2, i + RES + 1])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = custom
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			(Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT))
	return mesh
