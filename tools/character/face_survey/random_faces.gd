extends Control

## Random faces to judge: CharacterAppearance.random() for a range of seeds, each rendered through the character
## creator's own preview (its lights, its portrait lens, the head and hair framing), front and three-quarter, all in
## the same outfit -- the face is what is judged. Writes <out>/<seed>_front.png, <out>/<seed>_three_quarter.png and
## <out>/faces.json: per seed its sex, age, origins and every slider it moved (by key), to learn from the verdicts.
##
## Needs a GPU (not --headless):
##   godot --path . res://tools/character/face_survey/random_faces.tscn -- --out=/tmp/faces --from=1 --count=200
##   [--seeds=1,7,11] those seeds instead; [--zero=Nose_Dorsum_Hump,Nose_Dorsum_Curve] those sliders left at rest
##   (does a face come right without them?)
## random_faces_sheets.py packs the images into contact sheets for the rating page.

## Name -> yaw (rad).
const VIEWS: Dictionary = {"front": 0.0, "three_quarter": 0.6}
## The captured image (px).
const IMAGE_SIZE := Vector2i(480, 600)
## Frames drawn before a capture, once the look and the camera are set.
const SETTLE_FRAMES: int = 4
## The outfit everyone wears (its slot in the catalogue).
const OUTFIT: int = 1

var _out: String = ""
var _preview: CreatorPreview


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_out = String(args.get("out", "user://random_faces"))
	var first: int = int(args.get("from", "1"))
	var count: int = int(args.get("count", "200"))
	var seeds: Array[int] = []
	for v in String(args.get("seeds", "")).split(",", false):
		seeds.append(int(v))
	if seeds.is_empty():
		for v in range(first, first + count):
			seeds.append(v)
	var zero: PackedStringArray = String(args.get("zero", "")).split(",", false)
	DirAccess.make_dir_recursive_absolute(_out)
	_preview = (load("res://ui/character_creator/creator_preview.gd") as GDScript).new()
	_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_preview)
	_preview.set_process(false)
	_preview.stretch = false
	_preview._viewport.size = IMAGE_SIZE
	_preview._viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await get_tree().process_frame
	var faces: Array = []
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for seed_value in seeds:
		var look: CharacterAppearance = CharacterAppearance.random(seed_value)
		look.outfit = OUTFIT
		for key: String in zero:
			look.modifiers.erase(CharacterAppearance.modifier_id(key))
		_preview._looks.set_appearance_now(look)
		for player: Node in _preview.find_children("*", "AnimationPlayer", true, false):
			(player as AnimationPlayer).stop()
		for face: Node in _preview.find_children("*", "FaceLife", true, false):
			face.set_process(false)
		var motion: HairMotion = HairMotion.of(_preview)
		if motion != null:
			motion.set_process(false)  # the hair at rest: the face is judged, not a breeze
		_preview.focus(&"face")
		for view: String in VIEWS:
			_preview._yaw = VIEWS[view]
			_preview._zoom = 1.0
			for i in SETTLE_FRAMES:
				_preview._place_camera(1.0)
				await get_tree().process_frame
			RenderingServer.force_draw(false)
			_preview._viewport.get_texture().get_image().save_png(_out.path_join("%d_%s.png" % [seed_value, view]))
		var moved: Dictionary = {}
		for id: int in look.modifiers:
			moved[String(sliders[id]["key"])] = float(look.modifiers[id])
		faces.append({"seed": seed_value, "female": float(look.macros["gender"]) < 0.5, "years": look.years(),
				"macros": look.macros, "origins": Array(look.origins), "sliders": moved})
		if faces.size() % 20 == 0:
			print("random faces: %d / %d" % [faces.size(), seeds.size()])
	var f := FileAccess.open(_out.path_join("faces.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(faces, "\t"))
	f.close()
	print("random faces: %d in %s" % [faces.size(), _out])
	get_tree().quit()
