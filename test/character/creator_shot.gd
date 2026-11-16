extends Node

## The character creator over the menu's still image, for screenshots: `-- --tab=face --sub=nose`, and
## `--look=<encoded CharacterAppearance>` to show that look instead of the saved one, `--unit=smile:0.4,happy:0.2`
## to hold the face in those life shapes (HumanBuilder.LIFE_SHAPES; FaceLife stands still), `--still` the figure
## at rest (no idle clip), `--zoom=0.5` the camera at that share of its distance (closer), `--yaw=0.6` the figure
## turned (radians, positive shows its left cheek), `--rise=-0.16` the camera's rise towards
## the face (the creator's FACE_RISE -0.06; MediaPipe's pitch of the render tells which matches a photo's).

var _units: Dictionary = {}  # life shape -> weight, held
var _still: bool = false
var _rise: float = NAN
var _creator: CharacterCreator

func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var back := CanvasLayer.new()
	var image := TextureRect.new()
	image.texture = load("res://ui/SplashScreen.png")
	image.set_anchors_preset(Control.PRESET_FULL_RECT)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	back.add_child(image)
	add_child(back)
	var creator: CharacterCreator = (load("res://ui/character_creator/character_creator.tscn") as PackedScene).instantiate()
	add_child(creator)
	if args.has("look"):
		var look: CharacterAppearance = CharacterAppearance.decode(args["look"])
		if look != null:
			creator._show(look, false)
	if args.has("tab"):
		creator._open_tab(StringName(args["tab"]))
	if args.has("sub"):
		creator._open_subtab(StringName(args["sub"]))
	if args.has("unit"):
		for unit in String(args["unit"]).split(","):
			var kv: PackedStringArray = unit.split(":")
			_units[StringName(kv[0])] = float(kv[1]) if kv.size() > 1 else 1.0
	_still = args.has("still")
	if args.has("zoom"):
		creator._preview._zoom = float(args["zoom"])
	if args.has("yaw"):
		creator._preview._yaw = float(args["yaw"])
	if args.has("rise"):
		_rise = float(args["rise"])
		process_priority = 100  # after the preview has placed its camera
	_creator = creator
	set_process(not _units.is_empty() or _still or not is_nan(_rise))


func _process(_delta: float) -> void:
	if not is_nan(_rise):
		var preview: CreatorPreview = _creator._preview
		var offset := Vector3(sin(preview._yaw), _rise, cos(preview._yaw)).normalized() * preview._distance
		preview._camera.look_at_from_position(preview._aim + offset, preview._aim)
	if _still:
		for player: Node in find_children("*", "AnimationPlayer", true, false):
			(player as AnimationPlayer).stop()
	for face: Node in find_children("*", "FaceLife", true, false):
		face.set_process(false)
	for looks: Node in find_children("*", "HumanAppearance", true, false):
		var appearance := looks as HumanAppearance
		if appearance != null and appearance.is_live():
			for shape: StringName in _units:
				appearance.set_face_shape(shape, _units[shape])
