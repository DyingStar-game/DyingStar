class_name FaceFit
extends RefCounted

## A face's shape from photos, in the game (no Python): MediaPipe's 478 landmarks on one or more photos of the same
## face (FaceDetectNative) -> the weights of FLAME's identity directions and a few creator sliders that make our
## head's landmarks land on them (FaceFitNative.cs solves), over the player's own base head (gender, age, height,
## origins: their face sliders left out). The method of tools/character/face_survey/fit.py.
##
## MediaPipe's landmarks are too loose for that alone to find a face (on our renders of known faces, the fit was
## no nearer the truth than the base head). So the front photo's landmarks first go through a linear map learned on
## those renders (FaceFitData's shape regression, regress.py): it predicts the face's dense shape, the keys are fitted
## to that shape, and the landmark fit then only refines about those weights (and finds the photo's expression and
## pose, the side photos' depth).

const NATIVE_PATH: String = "res://scenes/_universe/characters/human/native/FaceFitNative.cs"
const FLAME_KEYS: int = 50
## Creator sliders fitted beside FLAME's directions: what they miss, the jaw (photo_fit --extra).
const EXTRA_KEYS: Array[String] = ["Jaw_Mandible", "Jaw_Mandible_GonialAngle", "Jaw_Definition", "Chin_Width"]
## The creator's nose sliders, fitted too: FLAME's directions alone left the nose the worst-made part of real faces
## (NoW's scans, the sliders fitted straight to them: the nose 0.89 mm, 0.73 with these, the face 0.80 -> 0.75).
const NOSE_KEYS: Array[String] = ["Nose_NasalBone", "Nose_NasalBone_AnteriorNasalAperature", "Nose_NasalBone_AnteriorNasalSpine",
	"Nose_Potrusion", "Nose_NasalAngle", "Nose_NostrilSize", "Nose_Tip_Potrusion", "Nose_BottomFlatness", "Nose_BridgeProminence"]
## The bridge's two shapes measured on real faces (tools/character/face_survey/ava/ava_dorsum.py): only a profile shows
## them, so neither the front nor the 45-degree sides read them (learnt from those on Ava-256: no better from the front,
## worse with the sides, NoW 1.59 -> 1.64 mm); a true profile does (NoW, fitted to the scan's own outline: the nose
## 1.45 -> 1.30 mm).
const PROFILE_KEYS: Array[String] = ["Nose_Dorsum_Hump", "Nose_Dorsum_Curve"]
## The profile's fit: the share of the face read for its outline (mm either side of its middle; how far behind the
## nose's tip), each of its triangles cut in PROFILE_SUBDIVISIONS a side for points; the keys' ridge per outline
## point (towards where they were: on NoW 0.01 to 1 fitted alike) and the rounds (laying, then the keys).
const PROFILE_HALF_WIDTH: float = 35.0
const PROFILE_DEPTH: float = 80.0
const PROFILE_SUBDIVISIONS: int = 4
const PROFILE_RIDGE: float = 0.1
const PROFILE_ROUNDS: int = 5
## Expressions fitted alongside and left out of the look: a photo's slight smile or raised brows must not be taken
## for the face's shape (tools/character/face_survey/fit.py EXPRESSION_KEYS). Their weights tell how neutral it was.
const EXPRESSION_KEYS: Array[String] = ["FACS_Happy", "FACS_Smile_Lips_Closed", "FACS_Mouth_Large_Opened", "FACS_Jaw_Lower",
	"FACS_aa_02", "FACS_Eyes_Squint", "FACS_Lower_Eyelid_Squint", "FACS_Eyebrows_Raised_Left", "FACS_Eyebrows_Raised_Right",
	"FACS_Eyebrows_Frown_Left", "FACS_Eyebrows_Frown_Right", "FACS_Cheeks_Raised_Left", "FACS_Cheeks_Raised_Right",
	"FACS_Lips_Up_Raised_M", "FACS_Lips_Dn_Lower_M", "FACS_Lips_Up_Corner_Wide_Left", "FACS_Lips_Up_Corner_Wide_Right",
	"FACS_Kiss", "FACS_Eyes_Closed_Left", "FACS_Eyes_Closed_Right", "FACS_Sad", "FACS_Angry"]
## Ridge of a key, per unit of landmark weight (m^2 a unit of weight squared): how far a key moves for the
## landmarks' sake. FLAME's directions are each one deviation of real faces; the sliders' units are larger.
const FLAME_PRIOR: float = 2e-7
const EXTRA_PRIOR: float = 1e-7
const EXPRESSION_PRIOR: float = 1e-7
## The face's outline slides along the cheek in MediaPipe's mesh: its landmarks count for less.
const OVAL_WEIGHT: float = 0.3
const FACE_OVAL: Array[int] = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148,
	176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
const ROUNDS: int = 8
## The dense shape fit's ridge, per unit of a key's landmark prior (_prior): 2.4e-5 for FLAME's (6 x regress.py's).
## On our renders, from three views: 1.24 mm (x1: 1.25 mm, x30: 1.31 mm); it keeps the weights nearer real faces'.
const SHAPE_RIDGE: float = 120.0
## Rounds of the dense shape fit (align the predicted shape on our head, then solve).
const SHAPE_ROUNDS: int = 3
## How much firmer the landmark fit holds the shape keys about the learned shape than about the base head: on our
## renders of known faces, any freer and the loose landmarks pull it away (x1: 2.36 mm off, x100: 1.81 mm, as the
## learned shape alone); the landmark fit then finds the photo's expression and pose.
const LEARNED_HOLD: float = 100.0
## The learned shape's furthest spread, in deviations of the training faces' (rms over its components): beyond, a
## photo unlike our renders makes the map extrapolate (a real face gave 1.3, our renders 0.6 median) and its fitted
## FLAME directions went to 2.6 deviations, a face of dents across the cheeks.
const MAX_SHAPE_SPREAD: float = 1.0
## A photo counts as turned to a side past this turn() (the nose's offset over the cheeks' span).
const TURNED: float = 0.2
## The turn() of the reader's side photos (Ava-256's cameras about 45 degrees off the face): the side photo nearest
## it is the one read.
const SIDE_TURN: float = 0.75

static var _native: Object = null


## The solver (C#), or null when the C# assembly is not there (the feature is then off).
static func native() -> Object:
	if _native == null:
		var script: Script = NativeScript.load_usable(NATIVE_PATH, ["Fit"])
		if script != null:
			_native = script.new()
	return _native


static func keys() -> Array[String]:
	var out: Array[String] = []
	for i in FLAME_KEYS:
		out.append("%s%02d" % [CharacterAppearance.FLAME_PREFIX, i])
	out.append_array(EXTRA_KEYS)
	out.append_array(NOSE_KEYS)
	for key: String in _survey_sliders():
		if not out.has(key):
			out.append(key)
	out.append_array(EXPRESSION_KEYS)
	return out


## The creator's sliders that landmarks tell on photos (the face survey's, face_stats.json: eyes, nose's height,
## lips, mouth's width, brows, chin...), with their spread over real faces: FLAME's few directions, held by
## their prior, made the lips too thin, the mouth too narrow.
static func _survey_sliders() -> Dictionary:
	var out: Dictionary = {}
	var stats: Dictionary = CharacterAppearance.face_stats()  # already its "sliders": { key: {range, sd, ...} }
	for key: String in stats:
		if not key.is_empty() and (stats[key] as Dictionary).has("sd"):
			out[key] = stats[key]
	return out


## A key's ridge: FLAME's directions each one deviation of real faces; a surveyed slider by its own spread.
static func _prior(key: String) -> float:
	if is_expression(key):
		return EXPRESSION_PRIOR
	if key.begins_with(CharacterAppearance.FLAME_PREFIX):
		return FLAME_PRIOR
	var survey: Dictionary = _survey_sliders()
	if survey.has(key):
		var spread: float = float(survey[key]["sd"]) * CharacterAppearance.slider_range(key)
		return FLAME_PRIOR / maxf(spread * spread, 1e-4)
	return EXTRA_PRIOR


static func is_expression(key: String) -> bool:
	return key.begins_with("FACS_")


## The landmarks' model over [param look]'s body, its face sliders left out: { "base": PackedVector3Array (478, m),
## "normals": their skin's normals,
## "deltas": PackedFloat32Array (K x 478 x 3, each key at weight 1), "keys": Array[String] (the bank's ones),
## "shape_base" / "shape_deltas": the same at the shape regression's vertices, for the shape keys (no expression;
## empty without the regression) }.
static func model(look: CharacterAppearance) -> Dictionary:
	var data: FaceFitData = FaceFitData.load_shared()
	var morph: HumanMorph = HumanBuilder.prepare()
	var bank: HumanBank = morph.bank
	var plain: CharacterAppearance = look.duplicate_appearance()
	plain.modifiers = {}
	var order: HumanBuilder.Order = HumanBuilder.order_for(plain, false)
	var points: PackedVector3Array = morph.morph(order.targets, order.weights)
	var stature: float = order.stature
	var base: PackedVector3Array = data.landmarks(points)
	for i in base.size():
		base[i] *= stature
	var normals: PackedVector3Array = data.normals(points)
	var deltas := PackedFloat32Array()
	var used: Array[String] = []
	var dense: bool = data.has_shape_model()
	var shape_base: PackedVector3Array = data.shape_points(points) if dense else PackedVector3Array()
	var shape_deltas := PackedFloat32Array()
	for key in keys():
		var slot: int = bank.target_index(key)
		if slot == -1:
			continue
		var body: PackedVector3Array = morph.with_target(points, slot, 1.0)
		var moved: PackedVector3Array = data.landmarks(body)
		for i in moved.size():
			var d: Vector3 = (moved[i] * stature) - base[i]
			deltas.append_array([d.x, d.y, d.z])
		used.append(key)
		if dense and not is_expression(key):  # the shape's keys come first in keys(), the expressions last
			var shape: PackedVector3Array = data.shape_points(body)
			for i in shape.size():
				var d: Vector3 = (shape[i] - shape_base[i]) * stature
				shape_deltas.append_array([d.x, d.y, d.z])
	for i in shape_base.size():
		shape_base[i] *= stature
	return {"base": base, "normals": normals, "deltas": deltas, "keys": used, "shape_base": shape_base, "shape_deltas": shape_deltas}


## Per landmark, how much it counts: 0 where our head has no match, OVAL_WEIGHT on the outline.
static func landmark_weights() -> PackedFloat32Array:
	var data: FaceFitData = FaceFitData.load_shared()
	var out := PackedFloat32Array()
	out.resize(FaceFitData.LANDMARKS)
	for i in FaceFitData.LANDMARKS:
		out[i] = 1.0 if data.valid[i] else 0.0
	for i in FACE_OVAL:
		out[i] *= OVAL_WEIGHT
	return out


## Fits the face of [param look] (its body as the player chose it) to [param views]: per photo, its 478 landmarks
## (FaceDetectNative "points": pixels, MediaPipe's depth), the front photo first. Returns { "look": the fitted
## CharacterAppearance, "weights": { key: weight }, "rms": the landmarks' residual (m), "poses": per photo }; {}
## without the solver. [param learn]: start from the learned shape (when packed); [param refine]: then fit the
## landmarks about it (also what finds the expression and the poses).
static func fit(look: CharacterAppearance, views: Array[PackedVector3Array],
		view_weights: PackedFloat32Array = PackedFloat32Array(), prior_scale: float = 1.0, learn: bool = true,
		refine: bool = true) -> Dictionary:
	var solver: Object = native()
	if solver == null or FaceFitData.load_shared() == null or views.is_empty():
		return {}
	var m: Dictionary = model(look)
	var used: Array[String] = m["keys"]
	learn = learn and not (m["shape_base"] as PackedVector3Array).is_empty()
	var hold: float = LEARNED_HOLD if learn else 1.0
	var lower := PackedFloat32Array()
	var upper := PackedFloat32Array()
	var prior := PackedFloat32Array()
	for key in used:
		if is_expression(key):
			lower.append(0.0)
			upper.append(1.0)
			prior.append(EXPRESSION_PRIOR)
			continue
		var reach: float = CharacterAppearance.slider_range(key)
		lower.append(-reach)
		upper.append(reach)
		prior.append(_prior(key) * prior_scale * hold)
	var learned: PackedFloat32Array = _learned_weights(solver, m, views, lower, upper) if learn else PackedFloat32Array()
	var view_list: Array = []
	for v in views.size():
		view_list.append({"points": views[v], "weight": view_weights[v] if v < view_weights.size() else 1.0})
	var result: Dictionary = {"weights": learned, "rms": 0.0, "poses": []}
	if refine or learned.is_empty():
		result = solver.call("Fit", m["base"], m["normals"], m["deltas"], lower, upper, prior, landmark_weights(), view_list, ROUNDS,
				learned)
	var weights: PackedFloat32Array = result["weights"]
	weights.resize(used.size())  # the learned weights alone stop before the expressions: 0
	var fitted: CharacterAppearance = look.duplicate_appearance()
	fitted.modifiers = {}  # the model was the body without its face sliders: the fitted face replaces them
	var by_key: Dictionary = {}
	for j in used.size():
		by_key[used[j]] = weights[j]
		if is_expression(used[j]):
			continue  # the photo's expression, not the face's shape
		var id: int = CharacterAppearance.modifier_id(used[j])
		if id != -1:
			fitted.modifiers[id] = clampf(weights[j] / CharacterAppearance.slider_range(used[j]), -1.0, 1.0)
	fitted.canonicalise()
	return {"look": fitted, "weights": by_key, "rms": result["rms"], "poses": result["poses"]}


## The shape keys' weights (the expressions' 0, after them) whose head is nearest the shape the learned map predicts
## from the photos' landmarks [param views] (the front first): the starting point, and the ridge's centre, of the
## landmark fit.
static func _learned_weights(solver: Object, m: Dictionary, views: Array[PackedVector3Array], lower: PackedFloat32Array,
		upper: PackedFloat32Array) -> PackedFloat32Array:
	var data: FaceFitData = FaceFitData.load_shared()
	var slots: Dictionary = view_slots(views)
	var mask: int = 0
	for view: int in slots:
		mask |= 1 << view
	var regression: Dictionary = data.regression(mask)
	var picked: Array = []
	var means := PackedFloat32Array()
	for view in data.shape_view_turn.size():
		if int(regression["mask"]) & (1 << view):
			picked.append(views[slots[view]])
			means.append_array(data.view_landmarks(view))
	var target: PackedVector3Array = solver.call("Predict", picked, means, regression["feature_mean"], regression["feature_std"],
			regression["beta"], data.shape_mean, data.shape_components, data.shape_component_std, MAX_SHAPE_SPREAD)
	var shape_base: PackedVector3Array = m["shape_base"]
	var k: int = (m["shape_deltas"] as PackedFloat32Array).size() / (shape_base.size() * 3)
	var ridge := PackedFloat32Array()
	for j in k:
		ridge.append(_prior(m["keys"][j]) * SHAPE_RIDGE)
	var result: Dictionary = solver.call("FitShape", shape_base, m["shape_deltas"], lower.slice(0, k), upper.slice(0, k), ridge, target,
			SHAPE_ROUNDS)
	var weights: PackedFloat32Array = result["weights"]
	weights.resize(lower.size())
	return weights


## Which photo of [param views] stands for each view the regressions know: { view: index into views }. The first
## photo is the front (view 0); a turned one (past TURNED) goes to the view of its side nearest its turn(), one
## photo a side (the one nearest its view when two are).
static func view_slots(views: Array[PackedVector3Array]) -> Dictionary:
	var data: FaceFitData = FaceFitData.load_shared()
	var slots: Dictionary = {0: 0}
	var by_side: Dictionary = {}  # side (+1 / -1) -> [view, photo, distance]
	for i in range(1, views.size()):
		var t: float = turn(views[i])
		if absf(t) < TURNED:
			continue
		for view in range(1, data.shape_view_turn.size()):
			var typical: float = data.shape_view_turn[view]
			if signf(typical) != signf(t):
				continue
			var off: float = absf(t - typical)
			var side: int = int(signf(t))
			if not by_side.has(side) or off < float(by_side[side][2]):
				by_side[side] = [view, i, off]
	for side: int in by_side:
		slots[by_side[side][0]] = by_side[side][1]
	return slots


## The creator's shape sliders read from photos by the reader learnt on real faces (FaceFitData's reader_*, from
## Ava-256's people): [param front] the front photo's landmarks, [param sides] the side ones' (any order: each goes
## to its side by turn(), the one nearest SIDE_TURN kept per side, those outside FacePhotoCheck's MIN_SIDE_TURN ..
## MAX_SIDE_TURN left out), for a [param female] or male base. { key: weight }, {} without a reader.
static func read(front: PackedVector3Array, sides: Array[PackedVector3Array], female: bool) -> Dictionary:
	var data: FaceFitData = FaceFitData.load_shared()
	var solver: Object = native()
	if data == null or solver == null or not data.has_reader():
		return {}
	var by_bit: Dictionary = {}  # 2: turned > 0, 4: turned < 0 (the reader's view bits)
	var off: Dictionary = {}
	for points in sides:
		var t: float = turn(points)
		if absf(t) < FacePhotoCheck.MIN_SIDE_TURN or absf(t) > FacePhotoCheck.MAX_SIDE_TURN:
			continue  # too little turned to tell more than the front, or more than the reader learnt
		var bit: int = 2 if t > 0.0 else 4
		var d: float = absf(absf(t) - SIDE_TURN)
		if not off.has(bit) or d < float(off[bit]):
			off[bit] = d
			by_bit[bit] = points
	var mask := 1
	for bit: int in by_bit:
		mask |= bit
	var r: Dictionary = data.reader(mask, female)
	if r.is_empty():
		return {}
	var views: Array = [front]
	for bit in [2, 4]:
		if int(r["mask"]) & bit:
			views.append(by_bit[bit])
	var weights: PackedFloat32Array = solver.call("Read", views, r["mean_landmarks"], r["feature_mean"], r["feature_std"], r["beta"],
			r["weight_mean"])
	var out: Dictionary = {}
	for k in data.reader_keys.size():
		out[data.reader_keys[k]] = weights[k]
	return out


## [param look] with its face's shape sliders set from [param weights] ({ key: weight }, at fit()'s scale).
static func with_weights(look: CharacterAppearance, weights: Dictionary) -> CharacterAppearance:
	var out: CharacterAppearance = look.duplicate_appearance()
	for key: String in weights:
		if is_expression(key):
			continue
		var id: int = CharacterAppearance.modifier_id(key)
		if id != -1:
			out.modifiers[id] = clampf(float(weights[key]) / CharacterAppearance.slider_range(key), -1.0, 1.0)
	out.canonicalise()
	return out


## The bridge's sliders (PROFILE_KEYS) read on a profile photo: our head as [param look] has it (the other photos'
## fit), its outline seen from the side laid on the photo's ([param profile]: PhotoProfile.measure's) by its
## forehead, lips and chin, then the keys moved so that its nose's outline follows the photo's (FaceFitNative.
## FitProfile; on NoW's real profiles the nose 1.45 -> 1.38 mm, tools/character/face_survey/profile_fit.py).
## Returns { "weights": { key: weight }, "score": the laying's residual (mm), "view": degrees off a pure profile },
## {} without the solver or the profile.
static func fit_profile(look: CharacterAppearance, profile: Dictionary) -> Dictionary:
	var solver: Object = native()
	var data: FaceFitData = FaceFitData.load_shared()
	if solver == null or not solver.has_method("FitProfile") or data == null or profile.is_empty():
		return {}
	var morph: HumanMorph = HumanBuilder.prepare()
	var bank: HumanBank = morph.bank
	var order: HumanBuilder.Order = HumanBuilder.order_for(look, false)
	var points: PackedVector3Array = morph.morph(order.targets, order.weights)
	var mm: float = order.stature * 1000.0
	var marks: PackedVector3Array = data.landmarks(points)
	for i in marks.size():
		marks[i] *= mm
	var height: float = marks[10].distance_to(marks[152])
	# The front of the face (its middle, a hand either side): points over its triangles.
	var tris := PackedInt32Array()
	var z: int = bank.zone_names.find("Face")
	for t in range(bank.zone_index_ptr[z], bank.zone_index_ptr[z + 1], 3):
		var corners: Array[int] = []
		var centre := Vector3.ZERO
		for c in 3:
			var v: int = bank.body_vertex[bank.zone_vertex_ptr[z] + bank.body_index[t + c]]
			corners.append(v)
			centre += points[v] * (mm / 3.0)
		if absf(centre.x) < PROFILE_HALF_WIDTH and centre.z > marks[1].z - PROFILE_DEPTH:
			tris.append_array(corners)
	var samples := PackedVector3Array()
	for t in range(0, tris.size(), 3):
		for bary: Vector3 in _profile_bary():
			samples.append((points[tris[t]] * bary.x + points[tris[t + 1]] * bary.y + points[tris[t + 2]] * bary.z) * mm)
	var deltas := PackedFloat32Array()
	var start := PackedFloat32Array()
	var lower := PackedFloat32Array()
	var upper := PackedFloat32Array()
	var used: Array[String] = []
	for key in PROFILE_KEYS:
		var slot: int = bank.target_index(key)
		if slot == -1:
			continue
		var moved: PackedVector3Array = morph.with_target(points, slot, 1.0)
		for t in range(0, tris.size(), 3):
			for bary: Vector3 in _profile_bary():
				var d: Vector3 = (moved[tris[t]] - points[tris[t]]) * bary.x + (moved[tris[t + 1]] - points[tris[t + 1]]) * bary.y \
						+ (moved[tris[t + 2]] - points[tris[t + 2]]) * bary.z
				deltas.append_array([d.x * mm, d.y * mm, d.z * mm])
		var reach: float = CharacterAppearance.slider_range(key)
		var id: int = CharacterAppearance.modifier_id(key)
		start.append(float(look.modifiers.get(id, 0.0)) * reach)
		lower.append(-reach)
		upper.append(reach)
		used.append(key)
	if used.is_empty() or samples.is_empty():
		return {}
	# The photo's outline in its face detector box's heights from the nose's tip: forward, up.
	var outline := PackedVector2Array()
	var tip: Vector2 = profile["nose_tip"]
	var box_height: float = float(profile["height"])
	var facing: float = float(profile["facing"])
	for p: Vector2 in profile["points"]:
		outline.append(Vector2((p.x - tip.x) * facing / box_height, -(p.y - tip.y) / box_height))
	var r: Dictionary = solver.call("FitProfile", samples, deltas, start, lower, upper, PROFILE_RIDGE, outline,
			marks[2].y + 2.0, marks[168].y - 3.0, marks[152].y - 0.15 * height, marks[10].y + 0.02 * height, height,
			PROFILE_ROUNDS)
	var weights: Dictionary = {}
	var solved: PackedFloat32Array = r["weights"]
	for j in used.size():
		weights[used[j]] = solved[j]
	return {"weights": weights, "score": float(r["score"]), "view": float(r["view"]), "laid": r.get("laid", PackedVector2Array()),
			"ours": r.get("ours", PackedVector2Array())}


static func _profile_bary() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for a in PROFILE_SUBDIVISIONS + 1:
		for b in PROFILE_SUBDIVISIONS + 1 - a:
			var u: float = float(a) / PROFILE_SUBDIVISIONS
			var v: float = float(b) / PROFILE_SUBDIVISIONS
			out.append(Vector3(u, v, 1.0 - u - v))
	return out


## How a photo's face is turned: its nose's tip (landmark 1) off the middle of its cheeks' edges (234, 454), over
## their span; > 0 towards the image's right. Within 0.3 of 0 on a front photo, about 0.55 at 40 degrees.
static func turn(points: PackedVector3Array) -> float:
	var span: float = absf(points[454].x - points[234].x)
	return (points[1].x - 0.5 * (points[234].x + points[454].x)) / maxf(span, 1e-6)
