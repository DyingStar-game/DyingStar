extends Control

## What a PLAYER can make in the character creator, to judge: each sample starts from a realistic look
## (CharacterAppearance.random) and then does what a player does -- grabs a few of the creator's controls and drags
## them, anywhere along their whole travel. Rendered through the creator's own preview, so what is judged is what
## the player sees. The verdicts tell where the creator's sliders must stop (CreatorLimits).
##
## Subjects:
## - face: the face tabs' sliders (head, eyes, nose, mouth, jaw, ears), the "overall" axes (FaceAxes, moved as the
##   creator moves them) and the origins; front and three-quarter portraits.
## - body: gender, age, height, the body tabs' sliders (shape, torso, hips, arms, legs) and the origins; the whole
##   figure from the front and the side, without garments, in the skeleton's rest pose.
##
## Samples by id (the category follows from the id, so every batch of the rating page mixes them):
## - control: random(seed) as it is (the baseline rejection rate, and what calibrates CLIP);
## - retouch: 1 to 4 gestures;
## - tinkerer: 8 to 15 gestures (combinations).
## A gesture draws its value over the control's whole travel, half the time near an end (|v| 0.7..1).
## --origin=N (catalogue "origins" index, 2 = European) keeps to one origin: each base look is the first random()
## look of that origin alone (seeds offset + id, then + ORIGIN_SEED_STRIDE...), and no gesture moves an origin.
## --sweep=0.4,0.7,1 replaces the categories: each sample moves ONE control, one way (a 0..1 control: up), to one of
## these levels -- every control, both ways, at every level, in a shuffled order (sweep_plan): where each control alone
## stops looking human, one control at a time. Ids past the plan are controls.
##
## Writes <out>/<id>_<view>.png and <out>/samples.json: per id its seed, category, sex, age (years), the gestures
## ([control, value] each, in order) and the final macros, origins, sliders (by key) and axis positions.
##
## Needs a GPU (not --headless):
##   godot --path . res://tools/character/face_survey/creator_survey.tscn -- --subject=face --out=/tmp/s --from=1
##   --count=800 [--ids=3,17] [--origin=2] [--sweep=0.4,0.7,1]
## random_faces_sheets.py --views packs the images into contact sheets; clip_judge.py pre-sorts them.

## Per subject: views (name -> yaw, rad), image size (px), framing, camera zoom, seed offset of the base look.
const SUBJECTS: Dictionary = {
	"face": {"views": {"front": 0.0, "three_quarter": 0.6}, "size": Vector2i(480, 600), "framing": &"face",
			"zoom": 1.0, "seed": 100000},
	"body": {"views": {"front": 0.0, "side": PI / 2.0}, "size": Vector2i(400, 800), "framing": &"body",
			"zoom": 1.4, "seed": 200000},
}
## The face tabs' and the body tabs' sliders (catalogue "tab").
const FACE_TABS: Array = ["head", "eyes", "nose", "mouth", "jaw", "ears"]
const BODY_TABS: Array = ["shape", "torso", "hips", "arms", "legs"]
## The body's macros a player sets (all 0..1 in the creator; the age as years, 18..90).
const BODY_MACROS: Array = ["gender", "age", "height"]
## Step between the seeds tried for a sample's base look when it must be of one origin (beyond any id).
const ORIGIN_SEED_STRIDE: int = 1000003
## Frames drawn before a capture, once the look and the camera are set.
const SETTLE_FRAMES: int = 4
## The outfit faces are seen in (an outfit of the first catalogue: the garments it became).
const FACE_OUTFIT: int = 1

var _out: String = ""
var _subject: String = "face"
var _origin: int = -1
var _plan: Array = []
var _preview: CreatorPreview


## Category of a sample from its id: one in ten a control; of the rest, faces 6 in 9 retouched (bodies 13 in 18).
static func category(subject: String, id: int) -> String:
	if subject == "body":
		var r: int = id % 20
		return "control" if r == 0 or r == 10 else ("tinkerer" if r >= 15 else "retouch")
	var k: int = id % 10
	return "control" if k == 0 else ("tinkerer" if k >= 7 else "retouch")


## The controls a gesture can grab, for [param subject]: [kind, key] with kind slider / axis / origin / macro.
## With [param origin] >= 0 the origins stay as the base look has them.
static func controls(subject: String, origin: int = -1) -> Array:
	var out: Array = []
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	var tabs: Array = FACE_TABS if subject == "face" else BODY_TABS
	for entry: Dictionary in sliders:
		if tabs.has(String(entry["tab"])):
			out.append(["slider", String(entry["key"])])
	if subject == "face":
		for axis: Array in FaceAxes.axes():
			out.append(["axis", String(axis[0])])
	else:
		for macro: String in BODY_MACROS:
			out.append(["macro", macro])
	if origin < 0:
		for i in CharacterAppearance.ORIGINS:
			out.append(["origin", str(i)])
	return out


## Seed of sample [param id]'s base look: offset + id, or with [param origin] >= 0 the first seed along
## offset + id + k * ORIGIN_SEED_STRIDE whose random() look is of that origin alone.
static func base_seed(subject: String, id: int, origin: int = -1) -> int:
	var s: int = int(SUBJECTS[subject]["seed"]) + id
	while origin >= 0:
		var look: CharacterAppearance = CharacterAppearance.random(s)
		var alone: bool = look.origins[origin] > 0.0
		for i in CharacterAppearance.ORIGINS:
			alone = alone and (i == origin or look.origins[i] == 0.0)
		if alone:
			break
		s += ORIGIN_SEED_STRIDE
	return s


## Every control of [param subject] one way at each of [param levels] (0..1): [[control, value]...], shuffled the
## same way every run. A -1..1 control both ways; a 0..1 one up only.
static func sweep_plan(subject: String, origin: int, levels: Array) -> Array:
	var plan: Array = []
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for control: Array in controls(subject, origin):
		var both: bool = control[0] == "axis" \
				or (control[0] == "slider" and not sliders[CharacterAppearance.modifier_id(control[1])]["unipolar"])
		for level: float in levels:
			plan.append([control, level])
			if both:
				plan.append([control, -level])
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([subject, "creator_survey_sweep"])
	for i in range(plan.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var t: Variant = plan[i]
		plan[i] = plan[j]
		plan[j] = t
	return plan


## Category of sample [param id], with [param plan] the sweep's (empty: the categories by id).
static func category_in(subject: String, id: int, plan: Array) -> String:
	if plan.is_empty():
		return category(subject, id)
	return "sweep" if id >= 1 and id <= plan.size() else "control"


## The look of sample [param id]: its base random() look, then its gestures (recorded in [param gestures]); with
## [param plan] (sweep_plan) the one gesture the plan gives it.
static func sample(subject: String, id: int, gestures: Array, origin: int = -1, plan: Array = []) -> CharacterAppearance:
	var look: CharacterAppearance = CharacterAppearance.random(base_seed(subject, id, origin))
	var cat: String = category_in(subject, id, plan)
	if cat == "control":
		return look
	if cat == "sweep":
		var step: Array = plan[id - 1]
		apply(look, step[0], step[1])
		gestures.append([step[0][0] + ":" + step[0][1], snappedf(step[1], 0.001)])
		look.canonicalise()
		return look
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([subject, id, "creator_survey"])
	var count: int = rng.randi_range(1, 4) if cat == "retouch" else rng.randi_range(8, 15)
	var all: Array = controls(subject, origin)
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for _g in count:
		var control: Array = all[rng.randi() % all.size()]
		var lowest: float = -1.0
		if control[0] == "slider":
			lowest = 0.0 if sliders[CharacterAppearance.modifier_id(control[1])]["unipolar"] else -1.0
		elif control[0] != "axis":
			lowest = 0.0
		# Half the gestures anywhere along the travel, half near an end: the ends are where faces break.
		var v: float = rng.randf_range(lowest, 1.0)
		if rng.randf() < 0.5:
			var far: float = rng.randf_range(0.7, 1.0)
			if lowest < 0.0:
				v = far if rng.randf() < 0.5 else -far
			else:
				v = far if rng.randf() < 0.6 else 1.0 - far  # a 0..1 control: mostly its high end
		apply(look, control, v)
		gestures.append([control[0] + ":" + control[1], snappedf(v, 0.001)])
	look.canonicalise()
	return look


## Set [param control] of [param look] to [param v] as the creator's row does.
static func apply(look: CharacterAppearance, control: Array, v: float) -> void:
	match String(control[0]):
		"slider":
			var id: int = CharacterAppearance.modifier_id(control[1])
			if absf(v) < 0.5 / 127.0:
				look.modifiers.erase(id)
			else:
				look.modifiers[id] = v
		"axis":
			for axis: Array in FaceAxes.axes():
				if String(axis[0]) == control[1]:
					FaceAxes.move(look, axis[2], v - FaceAxes.value_of(look, axis[2]))
		"origin":
			look.origins[int(control[1])] = v
		"macro":
			look.macros[control[1]] = v


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_subject = String(args.get("subject", "face"))
	var setup: Dictionary = SUBJECTS[_subject]
	_out = String(args.get("out", "user://creator_survey_" + _subject))
	_origin = int(args.get("origin", "-1"))
	var first: int = int(args.get("from", "1"))
	var count: int = int(args.get("count", "800"))
	if args.has("sweep"):
		var levels: Array = Array(String(args["sweep"]).split(",", false)).map(func(v: String) -> float: return float(v))
		_plan = sweep_plan(_subject, _origin, levels)
		print("creator survey: sweep of %d samples" % _plan.size())
	var ids: Array[int] = []
	for v in String(args.get("ids", "")).split(",", false):
		ids.append(int(v))
	if ids.is_empty():
		for v in range(first, first + count):
			ids.append(v)
	DirAccess.make_dir_recursive_absolute(_out)
	_preview = (load("res://ui/character_creator/creator_preview.gd") as GDScript).new()
	_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_preview)
	_preview.set_process(false)
	_preview.stretch = false
	_preview._viewport.size = setup["size"]
	_preview._viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await get_tree().process_frame
	var samples: Array = []
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for id in ids:
		var gestures: Array = []
		var look: CharacterAppearance = sample(_subject, id, gestures, _origin, _plan)
		if _subject == "face":
			look.garments = CharacterAppearance.outfit_garments(FACE_OUTFIT).map(func(i: int) -> Array: return [i, 0])
		_preview._looks.set_appearance_now(look)
		if _subject == "body":
			# Without garments: the game always dresses a look (shape_hash canonicalises it: dressed), so the bare
			# body is baked here, past the cache, its order stripped of them (they come last: hair_at and beard_at
			# stay right).
			var order: HumanBuilder.Order = HumanBuilder.order_for(_preview._looks.appearance, false)
			var bare: Array[HumanAssetData] = []
			for asset: HumanAssetData in order.assets:
				if asset.kind != &"garment":
					bare.append(asset)
			order.assets = bare
			_preview._looks._apply(HumanBuilder.build(order, HumanMeshCache._bases()))
		for player: Node in _preview.find_children("*", "AnimationPlayer", true, false):
			var anim := player as AnimationPlayer
			anim.stop()
		if _subject == "body":
			_preview._skeleton.reset_bone_poses()  # the rest pose: arms away from the body, legs straight
		for face: Node in _preview.find_children("*", "FaceLife", true, false):
			face.set_process(false)
		var motion: HairMotion = HairMotion.of(_preview)
		if motion != null:
			motion.set_process(false)  # the hair at rest: the figure is judged, not a breeze
		_preview.focus(setup["framing"])
		for view: String in setup["views"]:
			_preview._yaw = setup["views"][view]
			_preview._zoom = setup["zoom"]
			for i in SETTLE_FRAMES:
				_preview._place_camera(1.0)
				await get_tree().process_frame
			RenderingServer.force_draw(false)
			_preview._viewport.get_texture().get_image().save_png(_out.path_join("%d_%s.png" % [id, view]))
		var moved: Dictionary = {}
		for slider_id: int in look.modifiers:
			moved[String(sliders[slider_id]["key"])] = float(look.modifiers[slider_id])
		var axes: Dictionary = {}
		for axis: Array in FaceAxes.axes():
			axes[String(axis[0])] = snappedf(FaceAxes.value_of(look, axis[2]), 0.001)
		samples.append({"id": id, "seed": base_seed(_subject, id, _origin), "category": category_in(_subject, id, _plan),
				"female": look.is_female(), "years": look.years(), "gestures": gestures, "macros": look.macros,
				"origins": Array(look.origins), "sliders": moved, "axes": axes, "look": look.encode()})
		if samples.size() % 20 == 0:
			print("creator survey: %d / %d" % [samples.size(), ids.size()])
	var f := FileAccess.open(_out.path_join("samples.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(samples, "\t"))
	f.close()
	print("creator survey: %d %s samples in %s" % [samples.size(), _subject, _out])
	get_tree().quit()
