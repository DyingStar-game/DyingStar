extends Control

## The hair bench: a fixed set of cuts, beards, colours, views and lights, rendered through the character
## creator's own preview (its lights, its portrait lens), one PNG each, to compare the hair's rendering
## before and after a change. Each figure is also rendered bald, and the stage empty, so that
## hair_bench_report.py can tell the hair's footprint, the skin seen through it and its silhouette.
##
## Needs a GPU (not --headless):
##   godot --path . res://tools/character/hair_groom/hair_bench.tscn -- --out=/tmp/bench_a
## `--quick` one colour and the front view only; `--only=swept_back,bob` the cuts whose name holds one of those;
## `--colours=black,blond` and `--views=front,profile` those only;
## `--param=strands.spec_strength:0,shell.wrap:0.5` hair shader parameters set for the run (strands, shell, scalp).
## `--motion=0.05,0,0` every moving hair displaced that much (m, in its mesh's frame) past its fixed length, through
## the hair_motion_rows texture as HairMotion fills it: only what lies past the fixed length moves.
## Writes <out>/manifest.json: one entry per image with its cut, beard, colour, view, light and references.

const CUTS: Array[String] = ["buzz", "swept_back", "side_part", "bob", "medium_wavy", "long_straight", "curly",
		"afro", "bun"]
const BEARDS: Array[String] = ["stubble", "goatee", "full"]
## Name -> [eumelanin, pheomelanin].
const COLOURS: Dictionary = {"black": [0.95, 0.05], "brown": [0.6, 0.15], "blond": [0.1, 0.3]}
## Name -> [yaw (rad), lens: "hair" the creator's portrait framing, else the distance (m) through the game's
## 75 degree lens].
const VIEWS: Dictionary = {"front": [0.0, "hair"], "three_quarter": [0.8, "hair"], "profile": [1.5708, "hair"],
		"back": [3.1416, "hair"], "game": [0.5, 2.0], "far": [0.5, 6.0]}
## Frames rendered before a capture, once the look and the camera are set.
const SETTLE_FRAMES: int = 6
## The captured image (px): the creator's portrait lens frames the head some 450 px tall in it.
const IMAGE_SIZE := Vector2i(900, 1200)

var _out: String = ""
var _preview: CreatorPreview
var _manifest: Array = []
var _key_rotation: Vector3
var _params: Array = []  # [shader name part, parameter, value]
var _motion := Vector3.ZERO


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_out = String(args.get("out", "user://hair_bench"))
	for item: String in String(args.get("param", "")).split(",", false):
		var kv: PackedStringArray = item.split(":")
		var which: PackedStringArray = kv[0].split(".")
		_params.append(["hair_" + which[0], StringName(which[1]), float(kv[1])])
	if args.has("motion"):
		var m: PackedStringArray = String(args["motion"]).split(",")
		_motion = Vector3(float(m[0]), float(m[1]), float(m[2]))
		var row := Image.create(HairMotionBinding.SIM_GUIDES * HairMotionBinding.SAMPLES, 1, false, Image.FORMAT_RGBAF)
		row.fill(Color(_motion.x, _motion.y, _motion.z, 0.0))
		RenderingServer.global_shader_parameter_set(&"hair_motion_rows", ImageTexture.create_from_image(row))
	DirAccess.make_dir_recursive_absolute(_out)
	_preview = (load("res://ui/character_creator/creator_preview.gd") as GDScript).new()
	_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_preview)
	_preview.set_process(false)  # the camera is placed here, at once
	_preview.focus(&"hair")
	# The same image whatever the window: the viewport is captured, not the screen.
	_preview.stretch = false
	_preview._viewport.size = IMAGE_SIZE
	_preview._viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await get_tree().process_frame
	var key: DirectionalLight3D = _lights()[0]
	_key_rotation = key.rotation_degrees
	await _run(args)
	var f := FileAccess.open(_out.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(_manifest, "\t"))
	f.close()
	print("hair bench: %d images in %s" % [_manifest.size(), _out])
	get_tree().quit()


func _run(args: Dictionary) -> void:
	var quick: bool = args.has("quick")
	var only: PackedStringArray = String(args.get("only", "")).split(",", false)
	var colours: Array = ["brown"] if quick else COLOURS.keys()
	var views: Array = ["front"] if quick else VIEWS.keys()
	if args.has("colours"):
		colours = Array(String(args["colours"]).split(","))
	if args.has("views"):
		views = Array(String(args["views"]).split(","))
	var jobs: Array = []  # [name, base preset, HairCut or null, BeardCut or null]
	for cut: String in CUTS:
		jobs.append([cut, "default_female", HairCut.preset(cut), null])
	for beard: String in BEARDS:
		jobs.append(["beard_" + beard, "default_male", HairCut.preset("short_crop"), BeardCut.preset(beard)])
	var refs: Dictionary = {}  # base preset + view -> [empty image, bald image]
	for job: Array in jobs:
		if not only.is_empty() and not Array(only).any(func(o: String) -> bool: return String(job[0]).contains(o)):
			continue
		for colour: String in colours:
			var look: CharacterAppearance = _look(job, colour)
			_preview._looks.set_appearance_now(look)
			for view: String in views:
				for light: String in (["key", "backlit"] if view in ["front", "three_quarter"] else ["key"]):
					var ref_key: String = "%s_%s_%s" % [job[1], view, light]
					if not refs.has(ref_key):
						refs[ref_key] = await _references(job[1], view, light)
						_preview._looks.set_appearance_now(look)
					var file: String = "%s_%s_%s_%s.png" % [job[0], colour, view, light]
					await _shoot(view, light, file)
					_manifest.append({"file": file, "job": job[0], "colour": colour, "view": view, "light": light,
							"empty": refs[ref_key][0], "bald": refs[ref_key][1]})


## The same figure bald, and the stage without it: what the hair's footprint is measured against.
func _references(preset: String, view: String, light: String) -> Array:
	var bald: CharacterAppearance = CharacterAppearance.preset(preset)
	bald.hair = 0
	bald.beard = 0
	_preview._looks.set_appearance_now(bald)
	var bald_file: String = "ref_%s_%s_%s_bald.png" % [preset, view, light]
	await _shoot(view, light, bald_file)
	_preview._puppet.visible = false
	var empty_file: String = "ref_%s_%s_%s_empty.png" % [preset, view, light]
	await _shoot(view, light, empty_file)
	_preview._puppet.visible = true
	return [empty_file, bald_file]


func _look(job: Array, colour: String) -> CharacterAppearance:
	var look: CharacterAppearance = CharacterAppearance.preset(job[1])
	look.hair = maxi(look.hair, 1)
	look.cut = job[2]
	look.beard = 0
	if job[3] != null:
		look.beard = maxi(look.beard, 1)
		look.beard_cut = job[3]
	look.hair_eumelanin = COLOURS[colour][0]
	look.hair_pheomelanin = COLOURS[colour][1]
	look.hair_grey = 0.0
	return look


func _shoot(view: String, light: String, file: String) -> void:
	var yaw: float = VIEWS[view][0]
	_preview._yaw = yaw
	_preview._zoom = 1.0
	var key: DirectionalLight3D = _lights()[0]
	key.rotation_degrees = _key_rotation
	if light == "backlit":  # from behind the head, a little to the side and above: towards the camera
		key.rotation_degrees = Vector3(-25.0, rad_to_deg(yaw) + 180.0 + 25.0, 0.0)
	for player: Node in _preview.find_children("*", "AnimationPlayer", true, false):
		(player as AnimationPlayer).stop()
	for face: Node in _preview.find_children("*", "FaceLife", true, false):
		face.set_process(false)
	_apply_params()
	if _motion != Vector3.ZERO:
		for hair: Node in _preview.find_children("Hair", "MeshInstance3D", true, false):
			(hair as MeshInstance3D).set_instance_shader_parameter(&"hair_motion", Vector4(1.0, 0.0, 0.0, 0.0))
	for i in SETTLE_FRAMES:
		_place(view)
		await RenderingServer.frame_post_draw
	var image: Image = _preview._viewport.get_texture().get_image()
	image.save_png(_out.path_join(file))


func _place(view: String) -> void:
	_preview._place_camera(1.0)
	if VIEWS[view][1] is float:  # a player that far away, through the game's lens
		var camera: Camera3D = _preview._camera
		camera.fov = 75.0
		var offset := Vector3(sin(_preview._yaw), 0.0, cos(_preview._yaw)) * float(VIEWS[view][1])
		camera.look_at_from_position(_preview._aim + offset, _preview._aim)


## The run's shader parameters on every hair material the figure wears.
func _apply_params() -> void:
	if _params.is_empty():
		return
	for node: Node in _preview._puppet.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for k in mesh.get_surface_count():
			var mat := mesh.surface_get_material(k) as ShaderMaterial
			var over := (node as MeshInstance3D).get_surface_override_material(k) as ShaderMaterial
			for m: ShaderMaterial in [mat, over]:
				if m == null or m.shader == null:
					continue
				for p: Array in _params:
					if m.shader.resource_path.contains(p[0]):
						m.set_shader_parameter(p[1], p[2])


func _lights() -> Array:
	return _preview._viewport.find_children("*", "DirectionalLight3D", true, false)
