extends Control

## Face types of one origin (FaceTypes, <origin>_face_types.json) rendered one by one, to judge by eye: per sex, the mean
## face, then each trait's types alone on it (the same base: age, hair, light), front and three-quarter, framed as the
## creator frames a face. --boost=2 tells every type twice as strongly (FaceTypes.STRENGTH), to see what tells them
## apart; --scale=2 renders twice as many pixels each way (same framing). Needs a GPU (not --headless):
##   godot --path . res://tools/character/face_survey/render_types.tscn -- --out=<dir> [--origin=2] [--years=30]
##       [--boost=1] [--scale=1]
## (--origin: a catalogue origin index, CharacterAppearance.ORIGIN_*; only the sexes its file has)
## Writes <sex>_mean_<view>.png and <sex>_<trait>_<type>_<view>.png, and types.json (per image its sex, trait, type).

const VIEWS: Dictionary = {"front": 0.0, "three_quarter": 0.6}
const SIZE := Vector2i(480, 600)
const SETTLE_FRAMES: int = 4
## The outfit faces are seen in (creator_survey.gd's).
const FACE_OUTFIT: int = 1

var _preview: CreatorPreview


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var out: String = String(args.get("out", "user://face_types"))
	var years: float = float(args.get("years", "30"))
	var boost: float = float(args.get("boost", "1"))
	var scale: int = int(args.get("scale", "1"))
	var origin: int = int(args.get("origin", str(CharacterAppearance.ORIGIN_WHITE)))
	if FaceTypes.data(origin).is_empty():
		push_error("no face types for origin %d" % origin)
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out)
	CreatorLimits.strength = 0.0  # the types as they are
	_preview = (load("res://ui/character_creator/creator_preview.gd") as GDScript).new()
	_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_preview)
	_preview.set_process(false)
	_preview.stretch = false
	_preview._viewport.size = SIZE * scale
	_preview._viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await get_tree().process_frame
	var index: Array = []
	for female: bool in [true, false]:
		if not FaceTypes.available(origin, female):
			continue
		var sex_name: String = "female" if female else "male"
		var sex: Dictionary = FaceTypes.data(origin)[sex_name]
		var gain: float = float(sex.get("gain", 1.0)) * FaceTypes.STRENGTH * boost
		var jobs: Array = [["mean", "", {}]]
		for feature: String in FaceTypes.data(origin)["traits"]:
			var types: Array = sex["traits"][feature]["types"]
			for t in types.size():
				jobs.append([feature, String(types[t]["id"]), types[t]["delta"]])
		for job: Array in jobs:
			var look: CharacterAppearance = CharacterAppearance.preset("default_female" if female else "default_male")
			for i in CharacterAppearance.ORIGINS:
				look.origins[i] = 0.9 if i == origin else 0.0
			look.skin_tone = CharacterAppearance.ORIGIN_TONES[origin]  # the origin's typical skin, as random() starts it
			look.macros["age"] = HumanMacros.age_of(years)
			look.garments = CharacterAppearance.outfit_garments(FACE_OUTFIT).map(func(i: int) -> Array: return [i, 0])
			var values: Dictionary = {}
			for key: String in sex["mean"]:
				values[key] = float(sex["mean"][key])
			for key: String in job[2]:
				values[key] = float(values.get(key, 0.0)) + gain * float(job[2][key])
			for key: String in values:
				var id: int = CharacterAppearance.modifier_id(key)
				if id != -1:
					look.modifiers[id] = clampf(values[key], -1.0, 1.0)
			look.canonicalise()
			var stem: String = "%s_mean" % sex_name if job[0] == "mean" else "%s_%s_%s" % [sex_name, job[0], job[1]]
			await _render(look, out, stem)
			index.append({"stem": stem, "sex": sex_name, "trait": job[0], "type": job[1]})
	var f := FileAccess.open(out.path_join("types.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(index, "\t"))
	f.close()
	print("render types: %d faces in %s" % [index.size(), out])
	get_tree().quit()


func _render(look: CharacterAppearance, out: String, stem: String) -> void:
	_preview._looks.set_appearance_now(look)
	for player: Node in _preview.find_children("*", "AnimationPlayer", true, false):
		(player as AnimationPlayer).stop()
	for face: Node in _preview.find_children("*", "FaceLife", true, false):
		face.set_process(false)
	var motion: HairMotion = HairMotion.of(_preview)
	if motion != null:
		motion.set_process(false)
	_preview.focus(&"face")
	for view: String in VIEWS:
		_preview._yaw = VIEWS[view]
		_preview._zoom = 1.0
		for i in SETTLE_FRAMES:
			_preview._place_camera(1.0)
			await get_tree().process_frame
		RenderingServer.force_draw(false)
		_preview._viewport.get_texture().get_image().save_png(out.path_join("%s_%s.png" % [stem, view]))
