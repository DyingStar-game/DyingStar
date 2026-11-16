extends Node

## Measures photos as the game's photo-to-character does (FaceDetectNative, PhotoAppearance.measure,
## FacePhotoCheck.measure) and writes the numbers and the settings they give (PhotoAppearance.estimate), to check
## it on real photos. Run headless:
##   godot --headless --path . res://tools/character/face_survey/measure_photos.tscn -- --list=<paths.txt> --out=<measures.json>
##       [--years=30]

const DETECTOR: String = "res://scenes/_universe/characters/human/native/FaceDetectNative.cs"


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var script: Script = NativeScript.load_usable(DETECTOR, ["Detect"])
	if script == null or not args.has("list") or not args.has("out"):
		push_error("needs the C# detector, --list=<paths.txt> and --out=<measures.json>")
		get_tree().quit(1)
		return
	var detector: Object = script.new()
	detector.call("Load", "res://assets/_universe/characters/human/face_models")
	var out: Array = []
	var paths: PackedStringArray = FileAccess.get_file_as_string(args["list"]).split("\n", false)
	for path in paths:
		var image: Image = Image.load_from_file(path.strip_edges())
		if image == null:
			continue
		var detection: Dictionary = detector.call("Detect", image, true)
		var colours: Dictionary = PhotoAppearance.measure(image, detection)
		var entry: Dictionary = {"path": path.strip_edges(), "check": FacePhotoCheck.measure(image, detection),
				"estimate": PhotoAppearance.estimate(colours, float(args.get("years", "30")))}
		for key: String in colours:
			var v: Variant = colours[key]
			entry[key] = [v.x, v.y, v.z] if v is Vector3 else v
		entry["hair_shape"] = PhotoHair.measure(image, detection, detector)
		out.append(entry)
	var f := FileAccess.open(args["out"], FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("MEASURED %d photos -> %s" % [out.size(), args["out"]])
	get_tree().quit()
