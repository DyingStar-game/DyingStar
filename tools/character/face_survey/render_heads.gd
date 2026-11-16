extends Node

## Renders baked heads for the face survey (tools/character/face_survey): each look's head mesh as baked
## (HumanBuilder), unskinned -- so in the bank's own space, at rest -- seen front-on through an orthographic
## camera, with the game's skin, eyes and brows. Beside each PNG a JSON gives the camera, so that a pixel
## maps back to bank coordinates: x = centre.x + (u - 0.5) * extent, y = centre.y + (0.5 - v) * extent.
##
##   godot --path . res://tools/character/face_survey/render_heads.tscn -- --looks=<file> --out=<dir>
##       [--size=1024] [--yaw=0]
##   ... -- --random=3000 --seed=1 --out=<dir> [--start=0] [--yaw=40]
## <file>: one look per line, "neutral" (every slider at rest) or an encoded CharacterAppearance.
## --flame: random faces drawn from FLAME's law instead (flame_look).
## --random: that many training faces (training_look): every face slider moved, any origin, gender and age,
## a random skin, brows and eye colour, the head turned a little and the light moved -- what a regression
## from MediaPipe's landmarks to our face shapes learns from (fit.py, regress.py). With --yaw, turned about that
## much instead (side photos' regression): the same seed gives the same faces at any --yaw.

const SIZE: int = 1024
## Height and width of what the camera sees (m): a head and a little of the neck.
const EXTENT: float = 0.3

var _viewport: SubViewport
var _holder: Node3D
var _camera: Camera3D
var _key: DirectionalLight3D


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var size: int = int(args.get("size", str(SIZE)))
	var yaw: float = float(args.get("yaw", "0"))
	var out: String = args.get("out", "user://face_survey")
	DirAccess.make_dir_recursive_absolute(out)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(size, size)
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	_viewport.add_child(_environment())
	_holder = Node3D.new()
	_viewport.add_child(_holder)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = EXTENT
	_viewport.add_child(_camera)
	_camera.make_current()
	HumanBuilder.generate_lods = false
	HumanBuilder.prepare()
	if args.has("random"):
		var rng := RandomNumberGenerator.new()
		var first: int = int(args.get("start", "0"))
		for k in range(first, first + int(args["random"])):
			rng.seed = hash([int(args.get("seed", "1")), k])
			var pose := Vector2(yaw + rng.randf_range(-18.0, 18.0), rng.randf_range(-10.0, 10.0))
			_key.rotation_degrees = Vector3(rng.randf_range(-45.0, -10.0), rng.randf_range(-50.0, 50.0), 0.0)
			var look: CharacterAppearance = flame_look(rng) if args.has("flame") else training_look(rng)
			await _render(look, pose.x, "%s/head_%05d" % [out, k], size, pose.y)
		get_tree().quit()
		return
	var lines: PackedStringArray = FileAccess.get_file_as_string(args.get("looks", "")).split("\n", false)
	for k in lines.size():
		var line: String = lines[k].strip_edges()
		var look: CharacterAppearance = CharacterAppearance.new() if line == "neutral" else CharacterAppearance.decode(line)
		if look == null:
			push_warning("not a look: %s" % line)
			continue
		if line == "neutral":
			look.skin_tone = 0.2
			look.eyebrows = 0
			look.canonicalise()
		await _render(look, yaw, "%s/head_%05d" % [out, k], size)
	get_tree().quit()


## A face for the regression to learn from: wider than CharacterAppearance.random -- every face slider
## moved (most a little, some far), any mix of origins, the whole range of gender and age.
static func training_look(rng: RandomNumberGenerator) -> CharacterAppearance:
	var a := CharacterAppearance.new()
	a.macros["gender"] = rng.randf()
	a.macros["age"] = rng.randf()
	a.macros["height"] = rng.randf()
	a.origins[rng.randi() % CharacterAppearance.ORIGINS] = rng.randf_range(0.3, 1.0)
	if rng.randf() < 0.4:
		a.origins[rng.randi() % CharacterAppearance.ORIGINS] += rng.randf_range(0.1, 0.5)
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for id in sliders.size():
		if not ["head", "eyes", "nose", "mouth", "jaw", "ears"].has(sliders[id]["tab"]):
			continue
		var v: float = rng.randfn(0.0, 0.45) if rng.randf() < 0.85 else rng.randf_range(-1.0, 1.0)
		a.modifiers[id] = absf(v) if sliders[id]["unipolar"] else v
	a.skin_tone = rng.randf()
	a.skin_warmth = rng.randf_range(0.3, 0.7)
	a.eye_colour = rng.randi() % 9
	a.eyebrows = rng.randi() % maxi(CharacterAppearance.choice_count("eyebrows"), 1)
	a.hair_eumelanin = rng.randf()
	a.canonicalise()
	return a


## A face as real faces vary (--flame): FLAME's identity directions drawn from their law N(0, 1), any gender and age,
## nothing else moved -- what a regression or a fit in FLAME's space is checked against.
static func flame_look(rng: RandomNumberGenerator) -> CharacterAppearance:
	var a := CharacterAppearance.new()
	a.macros["gender"] = rng.randf()
	a.macros["age"] = rng.randf() * 0.7
	a.macros["height"] = rng.randf()
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for id in sliders.size():
		if String(sliders[id]["key"]).begins_with(CharacterAppearance.FLAME_PREFIX):
			a.modifiers[id] = clampf(rng.randfn(0.0, 1.0) / CharacterAppearance.FLAME_RANGE, -1.0, 1.0)
	a.skin_tone = rng.randf()
	a.skin_warmth = rng.randf_range(0.3, 0.7)
	a.eye_colour = rng.randi() % 9
	a.eyebrows = rng.randi() % maxi(CharacterAppearance.choice_count("eyebrows"), 1)
	a.hair_eumelanin = rng.randf()
	a.canonicalise()
	return a


func _render(look: CharacterAppearance, yaw: float, stem: String, size: int, pitch: float = 0.0) -> void:
	for child in _holder.get_children():
		child.queue_free()
	var order: HumanBuilder.Order = HumanBuilder.order_for(look, false)
	var baked: HumanBuilder.Baked = HumanBuilder.build(order, HumanMeshCache._bases())
	var weights: Dictionary = {}  # bank target -> its weight in this body: what a fit should find
	var bank: HumanBank = HumanMorph.shared().bank
	for k in order.targets.size():
		var key: String = bank.target_names[order.targets[k]]
		weights[key] = float(weights.get(key, 0.0)) + order.weights[k]
	var head := MeshInstance3D.new()
	head.mesh = baked.head_mesh
	for s in baked.head_mesh.get_surface_count():
		head.set_surface_override_material(s, CharacterMaterials.human_material(baked.head_surface_assets[s], look, true))
	head.set_instance_shader_parameter(&"skin_look", Vector3(look.skin_tone, look.skin_warmth, 0.0))
	var hair: Color = look.hair_colour().srgb_to_linear()
	head.set_instance_shader_parameter(&"hair_colour", Vector4(hair.r, hair.g, hair.b, 1.0))
	var eye: Color = look.eye_tint().srgb_to_linear()
	head.set_instance_shader_parameter(&"eye_colour", Vector3(eye.r, eye.g, eye.b))
	_holder.add_child(head)
	# The face: what lies in front of the ears, above the chin.
	var aabb: AABB = baked.head_mesh.get_aabb()
	var centre := Vector3(0.0, aabb.position.y + aabb.size.y * 0.62, 0.0)
	# Turned about the face's centre, so that it stays in frame.
	var turn := Basis(Vector3.UP, deg_to_rad(yaw)) * Basis(Vector3.RIGHT, deg_to_rad(pitch))
	_holder.transform = Transform3D(turn, centre - turn * centre)
	_camera.position = Vector3(centre.x, centre.y, aabb.end.z + 1.0)
	_camera.near = 0.05
	_camera.far = 3.0
	for _frame in 4:
		await RenderingServer.frame_post_draw
	var image: Image = _viewport.get_texture().get_image()
	image.save_png(stem + ".png")
	var info := {"look": look.encode(), "centre": [centre.x, centre.y], "extent": EXTENT, "size": size, "yaw": yaw, "pitch": pitch,
			"stature": HumanMacros.stature(look.macros["height"]), "targets": weights}
	var f := FileAccess.open(stem + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(info))
	f.close()


func _environment() -> WorldEnvironment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.45, 0.47, 0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.62)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var world := WorldEnvironment.new()
	world.environment = env
	_key = DirectionalLight3D.new()
	_key.rotation_degrees = Vector3(-25.0, 20.0, 0.0)
	_key.light_energy = 1.3
	world.add_child(_key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10.0, -40.0, 0.0)
	fill.light_energy = 0.5
	world.add_child(fill)
	return world
