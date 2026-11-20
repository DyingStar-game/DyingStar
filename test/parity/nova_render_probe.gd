extends Node3D
## Nova render probe: compiles the Nova ground shader and photographs a Tarsis 3 chunk that
## straddles two corundum variants, with its scatter, from above. Opens a window (needs a GPU).
## Run: godot --path . res://test/parity/nova_render_probe.tscn -- --out=<png>

const SCENE := "res://scenes/systems/tarsis/tarsis_3.tscn"
const NSIDE := 8192
const IPIX := 203988693  # crosses corundum variants 1 and 4 (nova_probe.gd)

var _frames := 0
var _out := "user://nova_render_probe.png"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	var root := (load(SCENE) as PackedScene).instantiate()
	var data: PlanetData = root.get("planet_data")
	data.apply_chunk_manifest()
	data.nova = NovaBody.open_body(data.planet_name)
	var mat := data.nova.build_material(data.terrain_material)
	var center := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(NSIDE, IPIX) * data.radius)
	var mesh := PlanetChunk.generate_mesh_healpix(data, NSIDE, IPIX, data.chunk_resolution, center)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.set_surface_override_material(0, mat)
	mi.set_instance_shader_parameter("chunk_origin_mod", Vector3(fposmod(center.x, 8192.0),
			fposmod(center.y, 8192.0), fposmod(center.z, 8192.0)))
	mi.set_instance_shader_parameter("chunk_center_local", center)
	add_child(mi)
	var descs := NovaScatter.layer_descs(data.nova, data.radius)
	var laid := NovaScatter.lay_chunk(descs, NSIDE, IPIX, int(mesh.get_meta("nova_res")),
			mesh.get_meta("nova_grid"), mesh.get_meta("nova_vid"), center,
			NovaScatter.zone_context(data, NSIDE, IPIX))
	for key: Array in laid:
		mi.add_child(NovaScatter.build_node(key, laid[key], 1, center))
	var up := center.normalized()
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.look_at_from_position(up * 10.0, -up + up.cross(Vector3.UP).normalized() * 0.8, Vector3.UP)
	var cam := Camera3D.new()
	add_child(cam)
	var side := up.cross(Vector3.UP).normalized()
	cam.far = 20000.0
	cam.look_at_from_position(up * 420.0 + side * 260.0, Vector3.ZERO, up)
	cam.current = true
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.45, 0.55, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.5, 0.55)
	add_child(env)
	print("PROBE render: %d scatter meshes, palette %s" % [laid.size(),
			mesh.get_meta("nova_palette", "none")])
	root.free()


func _process(_dt: float) -> void:
	_frames += 1
	if _frames == 30:
		var img := get_viewport().get_texture().get_image()
		img.save_png(_out)
		print("PROBE render saved %s" % ProjectSettings.globalize_path(_out))
		get_tree().quit()
