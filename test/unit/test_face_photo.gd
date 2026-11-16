extends GutTest

## A character from photos, in the game: MediaPipe's models run with ONNX Runtime (FaceDetectNative.cs) and the
## face's shape fitted to the landmarks (FaceFit, FaceFitNative.cs).

const FACE := "res://test/data/face/npc_face.png"
const FACE_LANDMARKS := "res://test/data/face/npc_face_landmarks.json"


func test_the_landmark_correspondences_are_packed() -> void:
	var data: FaceFitData = FaceFitData.load_shared()
	assert_not_null(data, "face_fit.res (tools/character/face_survey/pack_face_fit.tscn)")
	assert_eq(data.vertices.size(), FaceFitData.LANDMARKS * 3)
	assert_gt(data.valid.count(1), 470, "nearly every landmark lies on our head")


func test_the_detector_finds_mediapipes_landmarks() -> void:
	var script: Script = NativeScript.load_usable("res://scenes/_universe/characters/human/native/FaceDetectNative.cs", ["Detect"])
	assert_true(script != null, "FaceDetectNative.cs must load, or this tests nothing (rebuild the C#)")
	if script == null:
		return
	var detector: Object = script.new()
	assert_true(detector.call("Load", "res://assets/_universe/characters/human/face_models"), "the ONNX models load")
	var result: Dictionary = detector.call("Detect", load(FACE).get_image(), true)
	assert_true(result["found"], "a face on the render")
	var points: PackedVector3Array = result["points"]
	var want: Array = JSON.parse_string(FileAccess.get_file_as_string(FACE_LANDMARKS))["points"]
	var total := 0.0
	for i in want.size():
		total += Vector2(points[i].x, points[i].y).distance_to(Vector2(want[i][0], want[i][1]))
	var mean: float = total / want.size()
	assert_lt(mean, 1.0, "within a pixel of MediaPipe's own (Python) landmarks on average (%.2f px)" % mean)
	var mask: Image = result["mask"]
	assert_eq(mask.get_size(), Vector2i(384, 384), "a class per pixel of the photo")
	var nose: Vector3 = points[1]
	assert_eq(mask.get_pixel(int(nose.x), int(nose.y)).r8, 3, "the nose's tip is face skin")


func test_a_photo_is_checked_before_it_is_used() -> void:
	var script: Script = NativeScript.load_usable("res://scenes/_universe/characters/human/native/FaceDetectNative.cs", ["Detect"])
	if script == null:
		fail_test("FaceDetectNative.cs must load (rebuild the C#)")
		return
	var detector: Object = script.new()
	detector.call("Load", "res://assets/_universe/characters/human/face_models")
	var image: Image = load(FACE).get_image()
	var measures: Dictionary = FacePhotoCheck.measure(image, detector.call("Detect", image, false))
	gut.p("measures %s" % measures)
	assert_eq(int(measures["faces"]), 1, "one face on the render")
	assert_eq(FacePhotoCheck.problems(measures, FacePhotoCheck.Role.FRONT), [] as Array[FacePhotoCheck.Problem],
			"a good front photo")
	assert_has(FacePhotoCheck.problems(measures, FacePhotoCheck.Role.SIDE), FacePhotoCheck.Problem.NOT_TURNED,
			"a front photo in a side's slot")
	var blurred: Image = image.duplicate()
	blurred.resize(image.get_width() / 6, image.get_height() / 6, Image.INTERPOLATE_BILINEAR)
	blurred.resize(image.get_width(), image.get_height(), Image.INTERPOLATE_BILINEAR)
	var blurred_measures: Dictionary = FacePhotoCheck.measure(blurred, detector.call("Detect", blurred, false))
	assert_has(FacePhotoCheck.problems(blurred_measures, FacePhotoCheck.Role.FRONT), FacePhotoCheck.Problem.BLURRY, "a blurred photo")
	var nothing: Array[FacePhotoCheck.Problem] = FacePhotoCheck.problems({"found": false}, FacePhotoCheck.Role.FRONT)
	assert_eq(nothing, [FacePhotoCheck.Problem.NO_FACE] as Array[FacePhotoCheck.Problem], "no face")
	var smiling: Array[FacePhotoCheck.Problem] = FacePhotoCheck.problems(measures, FacePhotoCheck.Role.FRONT, {"FACS_Happy": 0.6})
	assert_eq(smiling, [FacePhotoCheck.Problem.NOT_NEUTRAL] as Array[FacePhotoCheck.Problem], "a smile on the front photo")
	for problem: int in FacePhotoCheck.Problem.values():
		assert_true(FacePhotoCheck.TEXT.has(problem), "every problem has its text")


func test_a_photos_colours_are_read_back_on_the_creators_scales() -> void:
	for tone in [0.0, 0.2, 0.5, 0.9]:
		var back: float = PhotoAppearance.tone_for_ita(PhotoAppearance.ita(PhotoAppearance.lab_of(PhotoAppearance.skin_albedo(tone))))
		assert_almost_eq(back, tone, 0.011, "the skin tone back from its albedo's ITA")
	for k in CharacterAppearance.EYE_TINTS.size():
		var tint: Color = CharacterAppearance.EYE_TINTS[k].srgb_to_linear()
		var ratio := Vector3(tint.r, tint.g, tint.b) / PhotoAppearance.EYE_WHITE
		var mean: float = (log(ratio.x) + log(ratio.y) + log(ratio.z)) / 3.0
		# A photo dulls an iris' hue: take its log colour's spread down as estimate() takes it up.
		var dulled := Vector3(exp(mean + (log(ratio.x) - mean) / PhotoAppearance.EYE_CHROMA),
				exp(mean + (log(ratio.y) - mean) / PhotoAppearance.EYE_CHROMA), exp(mean + (log(ratio.z) - mean) / PhotoAppearance.EYE_CHROMA))
		assert_eq(PhotoAppearance.eye_colour_for(dulled), k, "eye colour %d found again" % k)
	var look := CharacterAppearance.new()
	for pigments in [Vector2(0.1, 0.0), Vector2(0.5, 1.0), Vector2(0.9, 0.1)]:
		look.hair_eumelanin = pigments.x
		look.hair_pheomelanin = pigments.y
		var c: Color = look.hair_colour().srgb_to_linear()
		var lab: Vector3 = PhotoAppearance.lab_of(Vector3(c.r, c.g, c.b))
		# As a photo shows it: saturated like a render.
		var seen: Vector3 = _linear_of_lab(Vector3(lab.x, lab.y * PhotoAppearance.HAIR_SATURATION, lab.z * PhotoAppearance.HAIR_SATURATION))
		var found: Dictionary = PhotoAppearance.hair_pigments(seen)
		assert_almost_eq(float(found["hair_eumelanin"]), pigments.x, 0.06, "eumelanin %.1f found again" % pigments.x)
		assert_almost_eq(float(found["hair_pheomelanin"]), pigments.y, 0.12, "pheomelanin %.1f found again" % pigments.y)
	var script: Script = NativeScript.load_usable("res://scenes/_universe/characters/human/native/FaceDetectNative.cs", ["Detect"])
	if script == null:
		fail_test("FaceDetectNative.cs must load (rebuild the C#)")
		return
	var detector: Object = script.new()
	detector.call("Load", "res://assets/_universe/characters/human/face_models")
	var image: Image = load(FACE).get_image()
	var estimate: Dictionary = PhotoAppearance.estimate(PhotoAppearance.measure(image, detector.call("Detect", image, true)))
	gut.p("estimate on our render: %s" % estimate)
	for key in ["skin_tone", "skin_warmth", "redness", "eye_colour", "hair_eumelanin", "hair_pheomelanin"]:
		assert_true(estimate.has(key), "the render tells " + key)


## A linear RGB colour of a Lab one (D65): lab_of's inverse.
func _linear_of_lab(lab: Vector3) -> Vector3:
	var fy: float = (lab.x + 16.0) / 116.0
	var fx: float = fy + lab.y / 500.0
	var fz: float = fy - lab.z / 200.0
	var inv := func(f: float) -> float: return f * f * f if f > 0.2069 else (f - 16.0 / 116.0) / 7.787
	var x: float = inv.call(fx) * 0.9505
	var y: float = inv.call(fy)
	var z: float = inv.call(fz) * 1.089
	return Vector3(3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z, 0.0557 * x - 0.2040 * y + 1.0570 * z)


func test_a_look_is_made_from_a_photo() -> void:
	if not FaceFromPhoto.available():
		fail_test("FaceFromPhoto needs the C# detector and solver (rebuild the C#)")
		return
	var base: CharacterAppearance = CharacterAppearance.preset("default_female")
	var photos: Array[Image] = [load(FACE).get_image()]
	var t0: int = Time.get_ticks_msec()
	var result: Dictionary = FaceFromPhoto.make(base, photos)
	gut.p("made in %d ms, problems %s" % [Time.get_ticks_msec() - t0, result["problems"]])
	var made: CharacterAppearance = result["look"]
	assert_true(made != null, "a look from a front photo")
	if made == null:
		return
	assert_false(made.modifiers.is_empty(), "the face's sliders fitted")
	assert_eq(made.macros["gender"], base.macros["gender"], "the body chosen is kept")
	assert_eq(CharacterAppearance.decode(made.encode()).encode(), made.encode(), "a canonical look")
	var nothing: Dictionary = FaceFromPhoto.make(base, [Image.create(64, 64, false, Image.FORMAT_RGB8)] as Array[Image])
	assert_true(nothing["look"] == null, "no look without a face")


func test_a_beard_is_read_from_a_photo() -> void:
	if not FaceFromPhoto.available():
		fail_test("PhotoBeard needs the C# detector (rebuild the C#)")
		return
	assert_false(PhotoBeard.model().is_empty(), "the beard's model is shipped")
	assert_eq(PhotoBeard.feature_names().size() + 1, (PhotoBeard.model()["names"] as Array).size(),
			"the model reads measure()'s numbers and the sex")
	# Our renders of one man shaven, with a full beard, with a moustache alone (test/data/face/beard_*.jpg).
	var styles: Array = CharacterAppearance.catalogue()["assets"]["beard"]
	for id: String in ["none", "full", "moustache"]:
		var image: Image = (load("res://test/data/face/beard_%s.jpg" % id) as Texture2D).get_image()
		var detection: Dictionary = FaceFromPhoto.detector().call("Detect", image, true)
		var beard: Dictionary = PhotoBeard.read(image, detection, true)
		gut.p("%s: %s" % [id, beard["scores"]])
		assert_eq(String(styles[beard["slot"]]["id"]), id, "the beard read from the photo of a %s beard" % id)
		if id == "full":
			var cut: BeardCut = beard["cut"]
			assert_gt(cut.chin, 0.5, "a full beard covers the chin")
			assert_gt(cut.cheeks, 0.5, "and the cheeks")
		if id == "moustache":
			assert_lt(float(beard["scores"]["chin"]), PhotoBeard.ZONE_BARE + 0.02, "a moustache alone leaves the chin bare")


func test_the_slider_reader_learnt_on_real_faces_is_used() -> void:
	if not FaceFromPhoto.available():
		fail_test("FaceFromPhoto needs the C# detector and solver (rebuild the C#)")
		return
	var data: FaceFitData = FaceFitData.load_shared()
	assert_true(data.has_reader(), "face_fit.res carries the slider reader (pack_face_fit.tscn --reader=)")
	if not data.has_reader():
		return
	for female in [false, true]:
		for mask in [1, 3, 5, 7]:
			assert_eq(int(data.reader(mask, female).get("mask", 0)), mask, "a reader for views %d (female %s)" % [mask, female])
	assert_eq(int(data.reader(3 | 8, false)["mask"]), 3, "an unknown view is left out")
	var result: Dictionary = FaceFromPhoto.make(CharacterAppearance.preset("default_male"), [load(FACE).get_image()] as Array[Image])
	var read: Dictionary = result.get("read", {})
	assert_eq(read.size(), data.reader_keys.size(), "the front photo read")
	for key: String in read:
		var w: float = read[key]
		assert_true(is_finite(w) and absf(w) <= 3.0 * CharacterAppearance.slider_range(key), "%s read %.2f" % [key, w])


func test_a_cut_is_matched_from_its_measures() -> void:
	var library: Dictionary = PhotoHair.library()
	assert_false(library.is_empty(), "hair_library.json (tools/character/face_survey/pack_hair_library.py)")
	if library.is_empty():
		return
	var cuts: Array = library["cuts"]
	assert_gt(cuts.size(), 50, "a library of renders")
	var close := 0
	for k in 10:
		var entry: Dictionary = cuts[k * 7 % cuts.size()]
		var views: Array[Dictionary] = []
		for yaw: String in entry["views"]:
			views.append(entry["views"][yaw])
		var found: HairCut = PhotoHair.match_cut(views)
		var truth: HairCut = HairCut.from_bytes(String(entry["cut"]).hex_decode())
		if absf(found.length - truth.length) < 0.15:
			close += 1
	assert_gt(close, 7, "a render's own measures give back about its length")
	var profile: Array[Dictionary] = [{"turn": 1.8, "amount": 30.0}]
	assert_true(PhotoHair.match_cut(profile) == null, "a true profile alone tells the library nothing")


func test_the_landmark_fit_alone_finds_a_known_face_again_from_three_views() -> void:
	if FaceFit.native() == null:
		fail_test("FaceFitNative.cs must load (rebuild the C#)")
		return
	var look: CharacterAppearance = CharacterAppearance.preset("default_female")
	var m: Dictionary = FaceFit.model(look)
	var base: PackedVector3Array = m["base"]
	var deltas: PackedFloat32Array = m["deltas"]
	var keys: Array = m["keys"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var truth := PackedFloat32Array()
	for key: String in keys:
		truth.append(0.0 if FaceFit.is_expression(key) else (rng.randfn(0.0, 0.6) if key.begins_with("FLAME") else rng.randf_range(-0.3, 0.3)))
	var head: PackedVector3Array = _head(base, deltas, truth)
	var views: Array[PackedVector3Array] = []
	for yaw in [0.0, 0.7, -0.7]:
		var turn := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, 0.08)
		var pts := PackedVector3Array()
		for p in head:  # a photo: pixels, y down, MediaPipe's depth (towards the camera negative), half a pixel of noise
			var q: Vector3 = turn * p * 3000.0 + Vector3(500.0, 400.0, 0.0)
			pts.append(Vector3(q.x + rng.randfn(0.0, 0.5), -q.y + rng.randfn(0.0, 0.5), -q.z))
		views.append(pts)
	var result: Dictionary = FaceFit.fit(look, views, PackedFloat32Array(), 1.0, false)  # exact landmarks: no learned map
	var found := PackedFloat32Array()
	for key: String in keys:
		found.append(0.0 if FaceFit.is_expression(key) else float(result["weights"][key]))
	var error: float = _aligned_error(_head(base, deltas, found), head)
	var neutral: float = _aligned_error(base, head)
	gut.p("shape error %.2f mm (the neutral head's %.2f mm)" % [error * 1000.0, neutral * 1000.0])
	# Landmarks alone, under the ridge real photos need (MediaPipe's landmarks are loose): a third of the way, at least.
	assert_lt(error, 0.75 * neutral, "the fitted face is nearer the truth than the neutral head")
	var expression := 0.0
	for key: String in keys:
		if FaceFit.is_expression(key):
			expression = maxf(expression, float(result["weights"][key]))
	assert_lt(expression, 0.25, "little expression found on a neutral face")
	var fitted: CharacterAppearance = result["look"]
	assert_false(fitted.modifiers.is_empty(), "the look carries the fitted sliders")


func _head(base: PackedVector3Array, deltas: PackedFloat32Array, weights: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n: int = base.size()
	for i in n:
		var p: Vector3 = base[i]
		for j in weights.size():
			if weights[j] != 0.0:
				var at: int = (j * n + i) * 3
				p += Vector3(deltas[at], deltas[at + 1], deltas[at + 2]) * weights[j]
		out.append(p)
	return out


## Mean distance (m) between two sets of landmarks once [param a] is scaled and shifted onto [param b] (a photo
## does not tell a head's size).
func _aligned_error(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var weights: PackedFloat32Array = FaceFit.landmark_weights()
	var ma := Vector3.ZERO
	var mb := Vector3.ZERO
	var n := 0.0
	for i in a.size():
		if weights[i] > 0.0:
			ma += a[i]
			mb += b[i]
			n += 1.0
	ma /= n
	mb /= n
	var num := 0.0
	var den := 0.0
	for i in a.size():
		if weights[i] > 0.0:
			num += (a[i] - ma).dot(b[i] - mb)
			den += (a[i] - ma).length_squared()
	var s: float = num / den
	var total := 0.0
	for i in a.size():
		if weights[i] > 0.0:
			total += ((a[i] - ma) * s - (b[i] - mb)).length()
	return total / n


func test_a_profile_photo_reads_the_bridge() -> void:
	if not FaceFromPhoto.available():
		fail_test("the profile's fit needs the C# detector and solver (rebuild the C#)")
		return
	# Our renders of the default man side-on, his bridge's hump at +0.8 and -0.8 (test/data/face/profile_hump_*.jpg):
	# read from the photo, over the same man with a straight bridge, each hump comes back on its side and most of
	# the two's difference with it (the bridge's two keys share some of a profile: the curve takes the rest).
	var base: CharacterAppearance = CharacterAppearance.preset("default_male")
	var humps: Dictionary = {}
	for case: Array in [["up", 1.0], ["down", -1.0]]:
		var image: Image = (load("res://test/data/face/profile_hump_%s.jpg" % case[0]) as Texture2D).get_image()
		var read: Dictionary = FaceFromPhoto.read(image, FacePhotoCheck.Role.PROFILE)
		assert_eq(read["problems"], [], "the %s photo passes as a profile" % case[0])
		var fit: Dictionary = FaceFit.fit_profile(base, read.get("profile", {}))
		assert_false(fit.is_empty(), "the profile is fitted")
		if fit.is_empty():
			return
		var hump: float = float(fit["weights"]["Nose_Dorsum_Hump"])
		humps[case[0]] = hump
		gut.p("%s: %s, laid to %.2f mm, %.0f degrees off" % [case[0], fit["weights"], fit["score"], fit["view"]])
		assert_gt(hump * float(case[1]), 0.1, "the hump read back on its side (%s: %.2f, rendered at %.1f)" % [case[0], hump, 0.8 * case[1]])
		assert_lt(float(fit["score"]), 3.0, "the photo's outline laid on ours (mm)")
	assert_gt(float(humps["up"]) - float(humps["down"]), 0.8, "most of the humps' difference (1.6) read back")
	# A front photo is no profile.
	var front: Image = (load("res://test/data/face/beard_none.jpg") as Texture2D).get_image()
	var problems: Array = FaceFromPhoto.read(front, FacePhotoCheck.Role.PROFILE)["problems"]
	assert_has(problems, FacePhotoCheck.Problem.NO_PROFILE, "a front photo is refused as a profile")
