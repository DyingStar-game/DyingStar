extends Node

## The beard's measures (PhotoBeard.measure) of a list of photos, for tools/character/face_survey/beard_model.py
## to learn the beard's model from (FFHQ's photos and their facial hair labels). One JSON line per photo, written as
## it goes. Run headless:
##   godot --headless --path . res://tools/character/face_survey/measure_beards.tscn -- --list=<paths.txt> --out=<lines.jsonl>

const DETECTOR: String = "res://scenes/_universe/characters/human/native/FaceDetectNative.cs"


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var script: Script = NativeScript.load_usable(DETECTOR, ["Detect"])
	if script == null or not args.has("list") or not args.has("out"):
		push_error("needs the C# detector, --list=<paths.txt> and --out=<lines.jsonl>")
		get_tree().quit(1)
		return
	var detector: Object = script.new()
	detector.call("Load", "res://assets/_universe/characters/human/face_models")
	var f := FileAccess.open(args["out"], FileAccess.WRITE)
	f.store_line(JSON.stringify({"names": PhotoBeard.feature_names()}))
	var count := 0
	for path in FileAccess.get_file_as_string(args["list"]).split("\n", false):
		var image: Image = Image.load_from_file(path.strip_edges())
		if image == null:
			continue
		var detection: Dictionary = detector.call("Detect", image, true)
		var features: PackedFloat32Array = PhotoBeard.measure(image, detection)
		var turn: float = FaceFit.turn(detection["points"]) if detection.get("found", false) else 0.0
		f.store_line(JSON.stringify({"path": path.strip_edges(), "f": Array(features), "turn": turn}))
		f.flush()
		count += 1
	f.close()
	print("MEASURED %d photos -> %s" % [count, args["out"]])
	get_tree().quit()
