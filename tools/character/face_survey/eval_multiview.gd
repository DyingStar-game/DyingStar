extends Node

## Whether side photos help the photo-to-character's face shape on real people, without their 3D: each person is
## fitted twice from separate photos (two fronts, two pairs of sides), with and without the sides, and the two
## dense shapes FaceFit makes are written out; eval_multiview.py then asks how close one person's two shapes are,
## against how far apart different people's are (a better shape is the same person's twice, and someone else's
## less). For a set like the FEI face database (200 people, 14 photos each from profile to profile: 11 the front, 13
## the front in a dimmer light, 02/03 and 08/09 the head turned 40-50 degrees each way). Run headless:
##   godot --headless --path . res://tools/character/face_survey/eval_multiview.tscn -- --dir=<images>
##       --people=1-200 --out=<prefix> [--pattern=%d-%02d.jpg] [--sets=11|13|11,02,09|13,03,08|11,09|13,08]
## Writes <prefix>.json (per person and set: the photos used, their turns) and <prefix>_<set>.f32 (per person, the
## shape at our head's 478 landmarks, x y z float32; zeros when the front has no face).
##
## With --heldout="11>02|11>09|11,09>02|11,02>09|0>02|0>09" it asks instead how well a shape fitted to some photos
## (before ">"; 0: the base face, nothing fitted) explains a photo it did not see (after it): the shape held, only
## the pose and the expression fitted to that photo, the landmarks' residual (mm, on the head). A side photo carries
## 3D the front does not when, with it, the other side is better explained. Writes <prefix>_heldout.json.

const DETECTOR: String = "res://scenes/_universe/characters/human/native/FaceDetectNative.cs"


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if not args.has("dir") or not args.has("out") or not FaceFromPhoto.available():
		push_error("needs --dir=<images> --out=<prefix> and the C# detector and solver")
		get_tree().quit(1)
		return
	if args.has("heldout"):
		_heldout(args)
		get_tree().quit()
		return
	var pattern: String = args.get("pattern", "%d-%02d.jpg")
	var range_text: PackedStringArray = String(args.get("people", "1-200")).split("-")
	var sets: PackedStringArray = String(args.get("sets", "11|13|11,02,09|13,03,08|11,09|13,08")).split("|")
	var base: CharacterAppearance = CharacterAppearance.preset("default_male")
	var m: Dictionary = FaceFit.model(base)
	var shape_base: PackedVector3Array = m["base"]
	var shape_deltas: PackedFloat32Array = m["deltas"]
	var shape_keys: Array = m["keys"]  # the expressions' weights are left at 0 below
	var files: Dictionary = {}
	for s in sets:
		files[s] = FileAccess.open("%s_%s.f32" % [args["out"], s.replace(",", "-")], FileAccess.WRITE)
	var report: Array = []
	for person in range(int(range_text[0]), int(range_text[1]) + 1):
		var points: Dictionary = {}  # photo number -> landmarks, or null
		var turns: Dictionary = {}
		var entry: Dictionary = {"person": person}
		for s in sets:
			var views: Array[PackedVector3Array] = []
			var used: Array = []
			for n_text in s.split(","):
				var n: int = int(n_text)
				if not points.has(n):
					points[n] = null
					var image: Image = Image.load_from_file(String(args["dir"]).path_join(pattern % [person, n]))
					if image != null:
						var detection: Dictionary = FaceFromPhoto.detector().call("Detect", image, false)
						if detection.get("found", false):
							points[n] = detection["points"]
							turns[n] = FaceFit.turn(detection["points"])
				if points[n] == null:
					continue
				# As the game does: a side photo less turned than a side's is left out.
				if not views.is_empty() and absf(float(turns[n])) < FacePhotoCheck.MIN_SIDE_TURN:
					continue
				if views.is_empty() and n_text != s.split(",")[0]:
					continue  # no front: nothing
				views.append(points[n])
				used.append(n)
			var shape := PackedFloat32Array()
			shape.resize(shape_base.size() * 3)
			if not views.is_empty():
				var fit: Dictionary = FaceFit.fit(base, views)
				var weights: Dictionary = fit.get("weights", {})
				for i in shape_base.size():
					var v: Vector3 = shape_base[i]
					for k in shape_keys.size():
						var w: float = 0.0 if FaceFit.is_expression(shape_keys[k]) else float(weights.get(shape_keys[k], 0.0))
						if w != 0.0:
							var at: int = (k * shape_base.size() + i) * 3
							v += w * Vector3(shape_deltas[at], shape_deltas[at + 1], shape_deltas[at + 2])
					shape[i * 3] = v.x
					shape[i * 3 + 1] = v.y
					shape[i * 3 + 2] = v.z
			(files[s] as FileAccess).store_buffer(shape.to_byte_array())
			entry[s] = used
		entry["turns"] = turns
		report.append(entry)
		print("PERSON %d %s" % [person, turns])
	for s in sets:
		(files[s] as FileAccess).close()
	var f := FileAccess.open("%s.json" % args["out"], FileAccess.WRITE)
	f.store_string(JSON.stringify({"sets": sets, "vertices": shape_base.size(), "people": report}))
	f.close()
	get_tree().quit()


## The landmarks of photo [param n] of [param person] (null without a face), cached in [param cache].
func _points(args: Dictionary, person: int, n: int, cache: Dictionary) -> Variant:
	if not cache.has(n):
		cache[n] = null
		var image: Image = Image.load_from_file(String(args["dir"]).path_join(String(args.get("pattern", "%d-%02d.jpg")) % [person, n]))
		if image != null:
			var detection: Dictionary = FaceFromPhoto.detector().call("Detect", image, false)
			if detection.get("found", false):
				cache[n] = detection["points"]
	return cache[n]


func _heldout(args: Dictionary) -> void:
	var range_text: PackedStringArray = String(args.get("people", "1-200")).split("-")
	var tests: PackedStringArray = String(args["heldout"]).split("|")
	var base: CharacterAppearance = CharacterAppearance.preset("default_male")
	var m: Dictionary = FaceFit.model(base)
	var used: Array[String] = m["keys"]
	var report: Array = []
	for person in range(int(range_text[0]), int(range_text[1]) + 1):
		var cache: Dictionary = {}
		var entry: Dictionary = {"person": person}
		for test in tests:
			var sides: PackedStringArray = test.split(">")
			var target: Variant = _points(args, person, int(sides[1]), cache)
			if target == null:
				continue
			var weights: Dictionary = {}
			if sides[0] != "0":
				var views: Array[PackedVector3Array] = []
				for n_text in sides[0].split(","):
					var pts: Variant = _points(args, person, int(n_text), cache)
					if pts != null:
						views.append(pts)
				if views.size() != sides[0].split(",").size():
					continue
				weights = FaceFit.fit(base, views).get("weights", {})
			var lower := PackedFloat32Array()
			var upper := PackedFloat32Array()
			var prior := PackedFloat32Array()
			var start := PackedFloat32Array()
			for key in used:
				var w: float = float(weights.get(key, 0.0))
				if FaceFit.is_expression(key):
					lower.append(0.0)
					upper.append(1.0)
					prior.append(FaceFit.EXPRESSION_PRIOR)
					start.append(0.0)
				else:
					lower.append(w)
					upper.append(w)
					prior.append(1.0)
					start.append(w)
			var result: Dictionary = FaceFit.native().call("Fit", m["base"], m["normals"], m["deltas"], lower, upper, prior,
					FaceFit.landmark_weights(), [{"points": target, "weight": 1.0}], FaceFit.ROUNDS, start)
			entry[test] = float(result["rms"]) * 1000.0
		report.append(entry)
		print("PERSON %d %s" % [person, entry])
	var f := FileAccess.open("%s_heldout.json" % args["out"], FileAccess.WRITE)
	f.store_string(JSON.stringify({"tests": tests, "people": report}))
	f.close()
