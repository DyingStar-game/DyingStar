class_name FaceFromPhoto
extends RefCounted

## A character from photos, in the game (the creator's "From photos"): the front photo first, then the side ones.
## Each photo is checked (FacePhotoCheck), its face found (FaceDetectNative: ONNX Runtime), then the face's shape is
## fitted to the front one's landmarks and read from them all by the reader learnt on real faces (FaceFit), its
## colours read from the front one (PhotoAppearance), its beard too (PhotoBeard), and its hair matched to our
## library of cuts (PhotoHair). The photos are only read: nothing of them is kept or sent, only the look made.

const DETECTOR_PATH: String = "res://scenes/_universe/characters/human/native/FaceDetectNative.cs"
const MODELS: String = "res://assets/_universe/characters/human/face_models"
## Whether the face's shape starts from FaceFit's learned shape (false: see make()).
const LEARN_SHAPE: bool = false
## A head with less hair than this (PhotoHair "amount", in half face heights squared) is shaven.
const BALD_AMOUNT: float = 0.3

static var _detector: Object = null


## The face detector (C#, ONNX Runtime), or null when the C# assembly or the native library is missing (the
## feature is then off).
static func detector() -> Object:
	if _detector == null:
		var script: Script = NativeScript.load_usable(DETECTOR_PATH, ["Detect"])
		if script != null:
			var made: Object = script.new()
			if made.call("Load", MODELS):
				_detector = made
	return _detector


static func available() -> bool:
	return detector() != null and FaceFit.native() != null and FaceFitData.load_shared() != null


## One photo, read: { "detection": FaceDetectNative's, "check": FacePhotoCheck.measure's, "problems":
## Array[FacePhotoCheck.Problem] for [param role] }, and for a profile (segmented) "profile": PhotoProfile.measure's
## outline ({} when none could be read: NO_PROFILE). Without [param segment] the detection has no mask (the hair's
## and colours' measures, a profile's outline need it) but costs a fifth: the webcam's live check.
static func read(image: Image, role: FacePhotoCheck.Role, segment: bool = true) -> Dictionary:
	var detection: Dictionary = detector().call("Detect", image, segment) if detector() != null else {"found": false}
	var check: Dictionary = FacePhotoCheck.measure(image, detection)
	var problems: Array[FacePhotoCheck.Problem] = FacePhotoCheck.problems(check, role)
	var out: Dictionary = {"detection": detection, "check": check, "problems": problems}
	if role == FacePhotoCheck.Role.PROFILE and segment and detection.get("found", false):
		out["profile"] = PhotoProfile.measure(image, detection)
		if (out["profile"] as Dictionary).is_empty() and not problems.has(FacePhotoCheck.Problem.NO_PROFILE):
			problems.append(FacePhotoCheck.Problem.NO_PROFILE)
	return out


## The look made from [param photos] (the front first, then any side ones) over [param base] (the body the player
## chose: gender, age, height, origins), and a true [param profile] photo if any (the nose's bridge: FaceFit.
## fit_profile). Returns { "look": CharacterAppearance (null when the front photo shows no face), "problems": per
## photo its Array[FacePhotoCheck.Problem] (the front's with its expression once fitted), "profile_problems": the
## profile's, "weights": FaceFit's, "beard": PhotoBeard.scores', "profile": FaceFit.fit_profile's }.
static func make(base: CharacterAppearance, photos: Array[Image], profile: Image = null) -> Dictionary:
	var problems: Array = []
	var reads: Array[Dictionary] = []
	for i in photos.size():
		var role: FacePhotoCheck.Role = FacePhotoCheck.Role.FRONT if i == 0 else FacePhotoCheck.Role.SIDE
		var r: Dictionary = read(photos[i], role)
		reads.append(r)
		problems.append(r["problems"])
	var profile_read: Dictionary = read(profile, FacePhotoCheck.Role.PROFILE) if profile != null else {}
	var out: Dictionary = {"look": null, "problems": problems, "weights": {}, "profile_problems": profile_read.get("problems", [])}
	if photos.is_empty() or not reads[0]["detection"].get("found", false) or not available():
		return out
	var views: Array[PackedVector3Array] = []
	var used: Array[int] = []
	for i in reads.size():
		var detection: Dictionary = reads[i]["detection"]
		var side_problems: Array = reads[i]["problems"]
		var usable: bool = i == 0 or not (side_problems.has(FacePhotoCheck.Problem.NOT_TURNED) or side_problems.has(
				FacePhotoCheck.Problem.TOO_TURNED))
		if detection.get("found", false) and usable:
			views.append(detection["points"])
			used.append(i)
	# The face's shape first from the front photo's landmarks, fitted directly (FaceFit's learned shape and the side
	# photos left out): measured on the NoW benchmark's real scans (tools/character/face_survey/eval_now.py, 20
	# people, metrical), the shape learned on our renders made real faces worse than the base face (2.13 mm against
	# 1.96), the direct fit better (1.78), and the sides, even down-weighted, did not help it (1.82).
	var fit: Dictionary = FaceFit.fit(base, [views[0]] as Array[PackedVector3Array], PackedFloat32Array(), 1.0, LEARN_SHAPE)
	if fit.is_empty():
		return out
	out["weights"] = fit["weights"]
	# Then half of it the sliders the reader learnt on real faces gives (Ava-256): on NoW, 1.61 mm from the front,
	# 1.59 with the sides (eval: tools/character/face_survey/ava/ava_learn.py).
	var sides: Array[PackedVector3Array] = []
	for i in used:
		if i != 0:
			sides.append(reads[i]["detection"]["points"])
	var read: Dictionary = FaceFit.read(views[0], sides, base.is_female())
	out["read"] = read
	var front_problems: Array[FacePhotoCheck.Problem] = FacePhotoCheck.problems(reads[0]["check"], FacePhotoCheck.Role.FRONT,
			fit["weights"])
	problems[0] = front_problems
	var look: CharacterAppearance = fit["look"]
	if not read.is_empty():
		var blend: float = FaceFitData.load_shared().reader_blend
		var mixed: Dictionary = {}
		for key: String in read:
			mixed[key] = blend * float(read[key]) + (1.0 - blend) * float(fit["weights"].get(key, 0.0))
		look = FaceFit.with_weights(look, mixed)
	# The bridge, which only a profile shows (on NoW's real profiles the nose 1.45 -> 1.37 mm).
	if not profile_read.is_empty() and (profile_read["problems"] as Array).is_empty():
		var bridge: Dictionary = FaceFit.fit_profile(look, profile_read["profile"])
		if not bridge.is_empty():
			look = FaceFit.with_weights(look, bridge["weights"])
			out["profile"] = bridge
	var colours: Dictionary = PhotoAppearance.estimate(PhotoAppearance.measure(photos[0], reads[0]["detection"]), base.years())
	for key: String in colours:
		look.set(key, colours[key])
	var smiling: bool = float(reads[0]["check"].get("smile", 0.0)) >= FacePhotoCheck.MAX_SMILE
	var beard: Dictionary = PhotoBeard.read(photos[0], reads[0]["detection"], not base.is_female(), smiling)
	if not (beard["scores"] as Dictionary).is_empty():
		look.beard = beard["slot"]
		look.beard_length = 1.0
		if beard["cut"] != null:
			look.beard_cut = beard["cut"]
	out["beard"] = beard["scores"]
	var shapes: Array[Dictionary] = []
	for i in used:
		var shape: Dictionary = PhotoHair.measure(photos[i], reads[i]["detection"], detector())
		if not shape.is_empty() and float(reads[i]["check"].get("sharpness", 1.0)) < PhotoHair.TEXTURE_MIN_SHARPNESS:
			shape["coherence"] = -1.0  # too soft to read the hair's texture
		if not shape.is_empty():
			shapes.append(shape)
	if not shapes.is_empty() and float(shapes[0].get("amount", 1.0)) < BALD_AMOUNT:
		look.hair = 0
	else:
		var cut: HairCut = PhotoHair.match_cut(shapes)
		if cut != null:
			look.hair = maxi(look.hair, 1)
			look.cut = cut
	look.canonicalise()
	out["look"] = look
	return out
