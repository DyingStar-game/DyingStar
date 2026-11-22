extends Node

## Many photos' face shapes, as the creator's "From photos" makes them (FaceFromPhoto.make's shape: FaceFit's fit of
## the front photo's landmarks, blended with the reader learnt on real faces), over a base of the photo's sex and age
## and of one origin -- for face_types.py, which learns European faces' types from FFHQ. The colours, beard and hair
## are not read. A dev tool: what it writes stays beside the photos (~/datasets), never in the project.
##
##   godot --headless --path . res://tools/character/face_survey/fit_photos.tscn -- --list=<photos.tsv> --out=<fits.jsonl>
##       [--origin=2]
##
## photos.tsv: per line "<path>\t<female 0|1>\t<years>". fits.jsonl: per photo a JSON line {path, rms, smile,
## weights: {key: stored slider value}, expression: {key: weight}}; a photo with no face, {path, found: false}.
## Resumable: photos already in the output are skipped.

## The base's gender macro for a woman and a man (CharacterAppearance.random draws 0..0.2 and 0.8..1).
const WOMAN: float = 0.1
const MAN: float = 0.9
## The base's main origin weight (random draws 0.8..1).
const ORIGIN_WEIGHT: float = 0.9


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if not args.has("list") or not args.has("out") or not FaceFromPhoto.available():
		push_error("needs --list=<photos.tsv> --out=<fits.jsonl> and the C# detector and solver")
		get_tree().quit(1)
		return
	var origin: int = int(args.get("origin", "2"))
	var done: Dictionary = {}
	if FileAccess.file_exists(args["out"]):
		for line in FileAccess.get_file_as_string(args["out"]).split("\n", false):
			var row: Variant = JSON.parse_string(line)
			if row is Dictionary:
				done[row["path"]] = true
	var out := FileAccess.open(args["out"], FileAccess.READ_WRITE if FileAccess.file_exists(args["out"]) else FileAccess.WRITE)
	out.seek_end()
	var blend: float = FaceFitData.load_shared().reader_blend
	var lines: PackedStringArray = FileAccess.get_file_as_string(args["list"]).split("\n", false)
	var count: int = 0
	var started: int = Time.get_ticks_msec()
	for line in lines:
		var cols: PackedStringArray = line.split("\t")
		if cols.size() < 3 or done.has(cols[0]):
			continue
		var row: Dictionary = {"path": cols[0]}
		var image: Image = Image.load_from_file(cols[0])
		var detection: Dictionary = FaceFromPhoto.detector().call("Detect", image, false) if image != null else {}
		if not detection.get("found", false):
			row["found"] = false
		else:
			var base := CharacterAppearance.new()
			var female: bool = cols[1] == "1"
			base.macros["gender"] = WOMAN if female else MAN
			base.macros["age"] = HumanMacros.age_of(float(cols[2]))
			base.macros["height"] = 0.5
			base.origins[origin] = ORIGIN_WEIGHT
			var front: PackedVector3Array = detection["points"]
			var fit: Dictionary = FaceFit.fit(base, [front] as Array[PackedVector3Array], PackedFloat32Array(), 1.0,
					FaceFromPhoto.LEARN_SHAPE)
			if fit.is_empty():
				row["found"] = false
			else:
				var look: CharacterAppearance = fit["look"]
				var read: Dictionary = FaceFit.read(front, [] as Array[PackedVector3Array], female)
				if not read.is_empty():
					var mixed: Dictionary = {}
					for key: String in read:
						mixed[key] = blend * float(read[key]) + (1.0 - blend) * float(fit["weights"].get(key, 0.0))
					look = FaceFit.with_weights(look, mixed)
				var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
				var weights: Dictionary = {}
				for id: int in look.modifiers:
					weights[String(sliders[id]["key"])] = snappedf(float(look.modifiers[id]), 0.0001)
				var expression: Dictionary = {}
				for key: String in fit["weights"]:
					if FaceFit.is_expression(key) and float(fit["weights"][key]) > 0.01:
						expression[key] = snappedf(float(fit["weights"][key]), 0.001)
				row["rms"] = float(fit["rms"])
				row["smile"] = FacePhotoCheck.smile_chance(front)
				row["weights"] = weights
				row["expression"] = expression
		out.store_line(JSON.stringify(row))
		count += 1
		if count % 200 == 0:
			out.flush()
			print("fit photos: %d (%.0f ms each)" % [count, float(Time.get_ticks_msec() - started) / count])
	out.close()
	print("fit photos: %d done" % count)
	get_tree().quit()
