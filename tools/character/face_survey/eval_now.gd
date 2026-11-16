extends Node

## The photo-to-character's face shape against the NoW benchmark's 3D scans (now.is.tue.mpg.de: real people,
## photographed with a phone from several sides, each with a neutral scan). Two modes, run headless:
##
##   godot --headless --path . res://tools/character/face_survey/eval_now.tscn -- --model --out=<dir>
## writes, per base body (a man's and a woman's, the default ones), our head's face as eval_now.py needs it to make
## any face from its sliders: model_<base>.json (the face's vertices and triangles, the shape keys, the 7 NoW
## landmarks as MediaPipe's on our head, "mediapipe": all 478 of them) and model_<base>.f32 (the vertices' rest
## positions, then per key their moves at weight 1; m, x y z float32).
##
##   godot ... -- --fit --root=<iphone_pictures> --list=<imagepathsvalidation.txt> --out=<dir>
## fits FaceFit to each photo of the list for each base (the benchmark's own protocol: one photo, one face), and
## for each person to their neutral photos together (the front: the least turned; then the most turned each way,
## as the creator's side slots): fits.json, per photo or set its shape keys' weights. With --variants, the sets only,
## each also fitted other ways (VARIANTS: the learned shape alone, the landmark fit alone at several priors):
## variants.json, to tune FaceFit on.

const DETECTOR: String = "res://scenes/_universe/characters/human/native/FaceDetectNative.cs"
const BASES: Array[String] = ["default_male", "default_female"]
## NoW's 7 landmarks (its annotations.png: an eye's outer and inner corners, the other's inner and outer, the
## nose's bottom, the mouth's corners) as MediaPipe's; which side comes first eval_now.py tells by the fit.
const NOW_LANDMARKS: Array[int] = [33, 133, 362, 263, 2, 61, 291]
## --variants: name -> FaceFit.fit's [prior_scale, learn, refine, the side photos' weight].
const VARIANTS: Dictionary = {
	"game": [1.0, true, true, 1.0], "learned": [1.0, true, false, 1.0], "landmarks_p1": [1.0, false, true, 1.0],
	"landmarks_p4": [4.0, false, true, 1.0], "landmarks_p16": [16.0, false, true, 1.0], "landmarks_p64": [64.0, false, true, 1.0],
	"landmarks_p0.25": [0.25, false, true, 1.0], "landmarks_p0.5": [0.5, false, true, 1.0],
	"landmarks_p1_side0.3": [1.0, false, true, 0.3], "landmarks_p0.5_side0.3": [0.5, false, true, 0.3],
}


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if not args.has("out"):
		push_error("needs --out=<dir> and --model or --fit")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(args["out"])
	if args.has("model"):
		var extra: PackedStringArray = String(args.get("extra-keys", "")).split(",", false)  # sliders to try beyond FaceFit's
		for base in BASES:
			_export_model(CharacterAppearance.preset(base), String(args["out"]).path_join("model_" + base), extra)
	if args.has("fit"):
		_fit(args)
	get_tree().quit()


func _export_model(look: CharacterAppearance, stem: String, extra: PackedStringArray = PackedStringArray()) -> void:
	var morph: HumanMorph = HumanBuilder.prepare()
	var bank: HumanBank = morph.bank
	var data: FaceFitData = FaceFitData.load_shared()
	var plain: CharacterAppearance = look.duplicate_appearance()
	plain.modifiers = {}
	var order: HumanBuilder.Order = HumanBuilder.order_for(plain, false)
	var points: PackedVector3Array = morph.morph(order.targets, order.weights)
	var stature: float = order.stature
	# The face zone's triangles, over compact vertices numbered locally.
	var local: Dictionary = {}
	var vertices: Array[int] = []
	var triangles: Array[int] = []
	var z: int = bank.zone_names.find("Face")
	for t in range(bank.zone_index_ptr[z], bank.zone_index_ptr[z + 1]):
		var compact: int = bank.body_vertex[bank.zone_vertex_ptr[z] + bank.body_index[t]]
		if not local.has(compact):
			local[compact] = vertices.size()
			vertices.append(compact)
		triangles.append(local[compact])
	var landmarks: Array = []
	for i: int in NOW_LANDMARKS:
		var corner: Array = []
		for j in 3:
			var compact: int = data.vertices[i * 3 + j]
			if not local.has(compact):
				local[compact] = vertices.size()
				vertices.append(compact)
			corner.append([local[compact], data.bary[i * 3 + j]])
		landmarks.append(corner)
	var mediapipe: Array = []  # all 478 landmarks, as the 7 above
	for i in FaceFitData.LANDMARKS:
		var corner: Array = []
		for j in 3:
			var compact: int = data.vertices[i * 3 + j]
			if not local.has(compact):
				local[compact] = vertices.size()
				vertices.append(compact)
			corner.append([local[compact], data.bary[i * 3 + j]])
		mediapipe.append(corner)
	var keys: Array[String] = []
	var blob := PackedFloat32Array()
	for v in vertices:
		var p: Vector3 = points[v] * stature
		blob.append_array([p.x, p.y, p.z])
	var all_keys: Array[String] = FaceFit.keys()
	for key in extra:
		if not all_keys.has(key):
			all_keys.append(key)
	for key in all_keys:
		var slot: int = bank.target_index(key)
		if slot == -1 or FaceFit.is_expression(key):
			continue
		var moved: PackedVector3Array = morph.with_target(points, slot, 1.0)
		for v in vertices:
			var d: Vector3 = (moved[v] - points[v]) * stature
			blob.append_array([d.x, d.y, d.z])
		keys.append(key)
	var f := FileAccess.open(stem + ".f32", FileAccess.WRITE)
	f.store_buffer(blob.to_byte_array())
	f.close()
	var info := {"vertices": vertices.size(), "triangles": triangles, "keys": keys, "landmarks": landmarks, "mediapipe": mediapipe,
			"stature": stature,
			"ranges": keys.map(func(k: String) -> float: return CharacterAppearance.slider_range(k))}
	f = FileAccess.open(stem + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(info))
	f.close()
	print("MODEL %s: %d vertices, %d triangles, %d keys" % [stem, vertices.size(), triangles.size() / 3, keys.size()])


func _fit(args: Dictionary) -> void:
	var script: Script = NativeScript.load_usable(DETECTOR, ["Detect"])
	if script == null or not FaceFromPhoto.available():
		push_error("needs the C# detector and solver")
		return
	var root: String = args["root"]
	var photos: Dictionary = {}  # path -> landmarks
	var turns: Dictionary = {}
	for line in FileAccess.get_file_as_string(args["list"]).split("\n", false):
		var path: String = line.strip_edges()
		var image: Image = Image.load_from_file(root.path_join(path))
		if image == null:
			continue
		var longest: int = maxi(image.get_width(), image.get_height())
		if longest > 1280:  # as the creator's dialog shrinks them
			var scale: float = 1280.0 / longest
			image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
		var detection: Dictionary = FaceFromPhoto.detector().call("Detect", image, false)
		if detection.get("found", false):
			photos[path] = detection["points"]
			turns[path] = FaceFit.turn(detection["points"])
	var out: Dictionary = {"turns": turns, "single": {}, "sets": {}}
	var variants: bool = args.has("variants")
	for base_name in BASES:
		var base: CharacterAppearance = CharacterAppearance.preset(base_name)
		var single: Dictionary = {}
		for path: String in ([] if variants else photos.keys()):
			single[path] = _shape_weights(FaceFit.fit(base, [photos[path]] as Array[PackedVector3Array]))
		out["single"][base_name] = single
		# Per person, their neutral photos: the front and the most turned each way.
		var people: Dictionary = {}
		for path: String in photos:
			if path.contains("multiview_neutral"):
				var person: String = path.split("/")[0]
				if not people.has(person):
					people[person] = []
				people[person].append(path)
		var sets: Dictionary = {}
		for person: String in people:
			var paths: Array = people[person]
			paths.sort_custom(func(a: String, b: String) -> bool: return absf(turns[a]) < absf(turns[b]))
			var front: String = paths[0]
			var left: String = ""
			var right: String = ""
			for p: String in paths:
				var t: float = turns[p]
				if absf(t) < FacePhotoCheck.MIN_SIDE_TURN or absf(t) > PhotoHair.MAX_TURN * 1.6:
					continue
				if t < 0.0 and (left == "" or absf(t - (-0.57)) < absf(float(turns[left]) - (-0.57))):
					left = p
				if t > 0.0 and (right == "" or absf(t - 0.57) < absf(float(turns[right]) - 0.57)):
					right = p
			var entry: Dictionary = {"front": front, "left": left, "right": right}
			if variants:
				for name: String in VARIANTS:
					var c: Array = VARIANTS[name]
					entry["front_only|" + name] = _shape_weights(FaceFit.fit(base, [photos[front]] as Array[PackedVector3Array],
							PackedFloat32Array(), c[0], c[1], c[2]))
					if left != "" and right != "":
						entry["front_both|" + name] = _shape_weights(FaceFit.fit(base,
								[photos[front], photos[left], photos[right]] as Array[PackedVector3Array],
								PackedFloat32Array([1.0, c[3], c[3]]), c[0], c[1], c[2]))
				sets[person] = entry
				continue
			entry["front_only"] = _shape_weights(FaceFit.fit(base, [photos[front]] as Array[PackedVector3Array]))
			for side: String in [left, right]:
				if side != "":
					entry["front_" + ("left" if side == left else "right")] = _shape_weights(FaceFit.fit(base,
							[photos[front], photos[side]] as Array[PackedVector3Array]))
			if left != "" and right != "":
				entry["front_both"] = _shape_weights(FaceFit.fit(base,
						[photos[front], photos[left], photos[right]] as Array[PackedVector3Array]))
			sets[person] = entry
		out["sets"][base_name] = sets
		print("FIT %s: %d photos, %d people" % [base_name, single.size(), sets.size()])
	var f := FileAccess.open(String(args["out"]).path_join("variants.json" if variants else "fits.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()


static func _shape_weights(fit: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var weights: Dictionary = fit.get("weights", {})
	for key: String in weights:
		if not FaceFit.is_expression(key):
			out[key] = weights[key]
	return out
