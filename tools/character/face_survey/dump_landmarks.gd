extends Node

## MediaPipe's 478 landmarks of a list of photos as the game reads them (FaceDetectNative, the photo shrunk to
## 1280 px as the creator's dialog does), for learning or checking the photo-to-character outside the game
## (Ava-256, NoW). One JSON line per photo, written as it goes: { "path", "found", "turn", "points": [x, y, z, ...]
## (pixels, MediaPipe's depth), "size": [w, h] }; with --profile also, on a true profile, "profile": PhotoProfile's
## outline ({ "facing", "points": [x, y, ...], "height", "nose_tip": [x, y] }). Run headless:
##   godot --headless --path . res://tools/character/face_survey/dump_landmarks.tscn -- --list=<paths.txt> --out=<lines.jsonl>

const MAX_SIDE: int = 1280


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if not args.has("list") or not args.has("out") or FaceFromPhoto.detector() == null:
		push_error("needs --list=<paths.txt> --out=<lines.jsonl> and the C# detector")
		get_tree().quit(1)
		return
	var f := FileAccess.open(args["out"], FileAccess.WRITE)
	var count := 0
	for line in FileAccess.get_file_as_string(args["list"]).split("\n", false):
		var path: String = line.strip_edges()
		var image: Image = Image.load_from_file(path)
		var entry: Dictionary = {"path": path, "found": false}
		if image != null:
			var longest: int = maxi(image.get_width(), image.get_height())
			if longest > MAX_SIDE:
				var scale: float = float(MAX_SIDE) / longest
				image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
			entry["size"] = [image.get_width(), image.get_height()]
			var detection: Dictionary = FaceFromPhoto.detector().call("Detect", image, args.has("profile"))
			if detection.get("found", false):
				var points: PackedVector3Array = detection["points"]
				var flat := PackedFloat32Array()
				for p in points:
					flat.append_array([p.x, p.y, p.z])
				entry["found"] = true
				entry["turn"] = FaceFit.turn(points)
				entry["points"] = Array(flat)
				var profile: Dictionary = PhotoProfile.measure(image, detection) if args.has("profile") else {}
				if not profile.is_empty():
					var outline := PackedFloat32Array()
					for p: Vector2 in profile["points"]:
						outline.append_array([p.x, p.y])
					var tip: Vector2 = profile["nose_tip"]
					entry["profile"] = {"facing": profile["facing"], "points": Array(outline), "height": profile["height"],
							"nose_tip": [tip.x, tip.y]}
		f.store_line(JSON.stringify(entry))
		count += 1
	f.close()
	print("DUMPED %d photos -> %s" % [count, args["out"]])
	get_tree().quit()
