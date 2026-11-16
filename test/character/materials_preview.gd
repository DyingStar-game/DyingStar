extends Node3D

## Before / after of the character's materials: `-- --legacy` shows the glTF's own (alpha blend), the
## default shows CharacterMaterials. `--face` frames the face, `--back` adds a strong back light.

const PUPPET := preload("res://scenes/_universe/characters/humanoids/human_puppet.tscn")


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var puppet: Node3D = PUPPET.instantiate()
	add_child(puppet)
	var body: Node = puppet.get_node("Body")
	if args.has("--legacy"):
		for node in body.find_children("*", "MeshInstance3D", true, false):
			for i in (node as MeshInstance3D).mesh.get_surface_count():
				(node as MeshInstance3D).set_surface_override_material(i, null)
	var player: AnimationPlayer = puppet.get_node("AnimationPlayer")
	for clip in player.get_animation_list():
		if String(clip) == "Idle":
			player.play(clip)
			break
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment.ssao_enabled = true
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 40.0, 0.0)
	sun.shadow_enabled = true
	sun.light_energy = 1.4
	add_child(sun)
	if args.has("--back"):
		var back := DirectionalLight3D.new()
		back.rotation_degrees = Vector3(-10.0, 200.0, 0.0)
		back.light_energy = 3.0
		add_child(back)
	var cam := Camera3D.new()
	add_child(cam)
	if args.has("--face"):
		cam.fov = 22.0
		cam.look_at_from_position(Vector3(0.35, 1.68, 1.15), Vector3(0.0, 1.62, 0.0))
	else:
		cam.fov = 35.0
		cam.look_at_from_position(Vector3(1.3, 1.25, 3.2), Vector3(0.0, 0.95, 0.0))
	cam.make_current()
