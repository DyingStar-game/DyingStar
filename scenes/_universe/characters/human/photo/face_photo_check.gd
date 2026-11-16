class_name FacePhotoCheck
extends RefCounted

## Whether a photo will make a good character (the photo-to-character's quality gates): one face, large and sharp
## enough, well lit, turned as its slot asks (the front, or a side), with no expression. measure() reads the
## photo and FaceDetectNative's result; problems() turns that, and the fit's expression weights, into what to
## tell the player (Problem, each with a localisation key).

enum Role { FRONT, SIDE, PROFILE }
enum Problem { NO_FACE, SEVERAL_FACES, TOO_SMALL, NOT_FRONT, NOT_TURNED, TOO_DARK, TOO_BRIGHT, BLURRY, NOT_NEUTRAL, TOO_TURNED,
	NO_PROFILE }

## Each problem's text (tools/localization/localisation.csv).
const TEXT: Dictionary = {
	Problem.NO_FACE: "%%PHOTO_CHECK_NO_FACE",
	Problem.SEVERAL_FACES: "%%PHOTO_CHECK_SEVERAL_FACES",
	Problem.TOO_SMALL: "%%PHOTO_CHECK_TOO_SMALL",
	Problem.NOT_FRONT: "%%PHOTO_CHECK_NOT_FRONT",
	Problem.NOT_TURNED: "%%PHOTO_CHECK_NOT_TURNED",
	Problem.TOO_DARK: "%%PHOTO_CHECK_TOO_DARK",
	Problem.TOO_BRIGHT: "%%PHOTO_CHECK_TOO_BRIGHT",
	Problem.BLURRY: "%%PHOTO_CHECK_BLURRY",
	Problem.NOT_NEUTRAL: "%%PHOTO_CHECK_NOT_NEUTRAL",
	Problem.TOO_TURNED: "%%PHOTO_CHECK_TOO_TURNED",
	Problem.NO_PROFILE: "%%PHOTO_CHECK_NO_PROFILE",
}
## The face's height (forehead's top to chin, pixels) under which MediaPipe's landmarks get loose (a 100 px face
## gave a poor fit, 200 px good ones).
const MIN_FACE_HEIGHT: float = 150.0
## A front photo's largest FaceFit.turn() (about 13 degrees of yaw; the regression learnt fronts up to 18).
const MAX_FRONT_TURN: float = 0.2
## The face skin's mean luminance (0..1, sRGB) bounds, and the share of clipped pixels allowed.
const MIN_BRIGHTNESS: float = 0.18
const MAX_BRIGHTNESS: float = 0.85
const MAX_CLIPPED: float = 0.08
## The face's sharpness (the Laplacian's deviation on the face scaled to SHARP_SIZE px, over its contrast) under
## which the photo is too blurred for its landmarks: sharp photos 0.13-0.52, blurred ones 0.05-0.15, so only the
## clearly blurred are refused.
const MIN_SHARPNESS: float = 0.1
const SHARP_SIZE: int = 160
## A side photo's smallest FaceFit.turn() (about 25 degrees of yaw): less turned, it tells little the front does not,
## and the learnt shape takes it for a 40-degree view.
const MIN_SIDE_TURN: float = 0.35
## A side photo's largest FaceFit.turn() (about 65 degrees): the reader learnt sides of 0.55 to 1.1 (Ava-256's 45
## degree cameras) and the hair library's are 45 degrees, so a true profile (1.5 and more) is read by nothing.
const MAX_SIDE_TURN: float = 1.1
## A profile photo's smallest FaceFit.turn(): MediaPipe's landmarks are loose on a true profile, their turn too
## (Ava-256's cameras: 98 % of the 75-degree views reach it, 71-88 % of the 90-degree ones, 8-22 % of the 45-degree).
const MIN_PROFILE_TURN: float = 0.9
## The smile's chance (smile_chance(), from the landmarks) from which a front photo is not neutral, and the lips'
## gap (inner lips, in half face heights) from which the mouth is open. Learnt on 33 000 FFHQ photos against their
## smile labels: held out, AUC 0.956; at 0.7, 86 % of the smiles caught and 5 % of the neutral faces taken for
## smiles. The open mouth: neutral faces' 95th percentile is 0.15.
const MAX_SMILE: float = 0.7
const MAX_LIPS_GAP: float = 0.2
## smile_chance()'s logistic regression: its measures' mean and spread on FFHQ, its weights and its bias (lips' gap,
## mouth's width over the face's, the corners' lift, the eyes' opening, the nose to the lip).
const SMILE_MEAN: Array[float] = [0.087, 0.4231, 0.0817, 0.0986, 0.164]
const SMILE_STD: Array[float] = [0.0756, 0.0607, 0.0547, 0.025, 0.0347]
const SMILE_WEIGHTS: Array[float] = [0.083, 2.5929, 0.8901, -0.3807, -0.5598]
const SMILE_BIAS: float = 2.3851
## Expression weights (FaceFit's FACS keys) past which the photo is not neutral: the fit takes an expression for
## the face's shape only so far.
const MAX_EXPRESSION: Dictionary = {
	"FACS_Happy": 0.35, "FACS_Smile_Lips_Closed": 0.4, "FACS_Mouth_Large_Opened": 0.3, "FACS_Jaw_Lower": 0.35,
	"FACS_aa_02": 0.35, "FACS_Eyes_Closed_Left": 0.5, "FACS_Eyes_Closed_Right": 0.5, "FACS_Kiss": 0.4,
}


## What the checks look at, from [param image] and FaceDetectNative.Detect's [param detection]: { "found",
## "faces", "height" (px), "box_height" (the face detector's, px: a profile's landmarks are loose), "turn", "smile"
## (smile_chance()), "lips_gap", "brightness", "clipped", "sharpness" }.
static func measure(image: Image, detection: Dictionary) -> Dictionary:
	var out: Dictionary = {"found": bool(detection.get("found", false)), "faces": int(detection.get("faces", 0))}
	if not out["found"]:
		return out
	var points: PackedVector3Array = detection["points"]
	out["height"] = Vector2(points[10].x, points[10].y).distance_to(Vector2(points[152].x, points[152].y))
	out["box_height"] = (detection["box"] as Rect2).size.y if detection.has("box") else out["height"]
	out["turn"] = FaceFit.turn(points)
	out["smile"] = smile_chance(points)
	out["lips_gap"] = _mouth(points)[0]
	var bounds := Rect2(points[0].x, points[0].y, 0.0, 0.0)
	for p in points:
		bounds = bounds.expand(Vector2(p.x, p.y))
	var crop: Rect2i = Rect2i(bounds).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if crop.size.x < 8 or crop.size.y < 8:
		return out
	var face: Image = image.get_region(crop)
	face.convert(Image.FORMAT_RGB8)
	face.resize(SHARP_SIZE, int(SHARP_SIZE * float(crop.size.y) / crop.size.x), Image.INTERPOLATE_BILINEAR)
	var w: int = face.get_width()
	var h: int = face.get_height()
	var luma := PackedFloat32Array()
	luma.resize(w * h)
	var data: PackedByteArray = face.get_data()
	for i in w * h:
		luma[i] = (0.2126 * data[i * 3] + 0.7152 * data[i * 3 + 1] + 0.0722 * data[i * 3 + 2]) / 255.0
	# Brightness and clipping over the face's middle (the landmarks' box holds some background on a side photo).
	var total := 0.0
	var clipped := 0
	var count := 0
	for y in range(h / 4, h * 3 / 4):
		for x in range(w / 4, w * 3 / 4):
			var v: float = luma[y * w + x]
			total += v
			count += 1
			if v > 0.98 or v < 0.02:
				clipped += 1
	out["brightness"] = total / maxi(count, 1)
	out["clipped"] = float(clipped) / maxi(count, 1)
	# Sharpness: the Laplacian's deviation over the luminance's (blur lowers the first, not the second).
	var lap_sum := 0.0
	var lap_sq := 0.0
	var mean: float = 0.0
	for v in luma:
		mean += v
	mean /= luma.size()
	var spread := 0.0
	for v in luma:
		spread += (v - mean) * (v - mean)
	spread = sqrt(spread / luma.size())
	var n := 0
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var i: int = y * w + x
			var l: float = luma[i - 1] + luma[i + 1] + luma[i - w] + luma[i + w] - 4.0 * luma[i]
			lap_sum += l
			lap_sq += l * l
			n += 1
	var lap_mean: float = lap_sum / maxi(n, 1)
	out["sharpness"] = sqrt(maxf(lap_sq / maxi(n, 1) - lap_mean * lap_mean, 0.0)) / maxf(spread, 1e-3)
	return out


## The chance (0..1) the face on [param points] (MediaPipe's 478, pixels) smiles: from the lips' gap, the mouth's
## width, its corners' lift, the eyes' opening and the nose-to-lip distance, a logistic regression learnt on FFHQ.
static func smile_chance(points: PackedVector3Array) -> float:
	var measures: PackedFloat32Array = _mouth(points)
	var v: float = SMILE_BIAS
	for k in measures.size():
		v += SMILE_WEIGHTS[k] * (measures[k] - SMILE_MEAN[k]) / SMILE_STD[k]
	return 1.0 / (1.0 + exp(-v))


## The mouth's measures, in the face's frame (forehead's top to chin down) and half face heights: the inner lips'
## gap, the mouth's width over the face's, its corners' lift over the lips' middle, the eyes' opening, the nose to
## the upper lip.
static func _mouth(points: PackedVector3Array) -> PackedFloat32Array:
	var p := func(i: int) -> Vector2: return Vector2(points[i].x, points[i].y)
	var axis: Vector2 = (p.call(152) as Vector2) - (p.call(10) as Vector2)
	var unit: float = maxf(0.5 * axis.length(), 1e-3)
	var down: Vector2 = axis.normalized()
	var dist := func(a: int, b: int) -> float: return (p.call(a) as Vector2).distance_to(p.call(b)) / unit
	var lips: Vector2 = 0.5 * ((p.call(0) as Vector2) + (p.call(17) as Vector2))
	var corners: Vector2 = 0.5 * ((p.call(61) as Vector2) + (p.call(291) as Vector2))
	return PackedFloat32Array([
		dist.call(13, 14),
		(p.call(61) as Vector2).distance_to(p.call(291)) / maxf((p.call(234) as Vector2).distance_to(p.call(454)), 1e-3),
		(lips - corners).dot(down) / unit,
		0.5 * (float(dist.call(159, 145)) + float(dist.call(386, 374))),
		dist.call(2, 0),
	])


## The problems of a photo for [param role] from its [param measures] (measure()) and, once fitted, the photo's
## [param expressions] (FaceFit.fit "weights": the FACS keys').
static func problems(measures: Dictionary, role: Role, expressions: Dictionary = {}) -> Array[Problem]:
	var out: Array[Problem] = []
	if not measures.get("found", false):
		out.append(Problem.NO_FACE)
		return out
	if int(measures.get("faces", 1)) > 1:
		out.append(Problem.SEVERAL_FACES)
	var height: float = float(measures.get("box_height" if role == Role.PROFILE else "height", 0.0))
	if height < MIN_FACE_HEIGHT:
		out.append(Problem.TOO_SMALL)
	var turn: float = absf(float(measures.get("turn", 0.0)))
	if role == Role.PROFILE and turn < MIN_PROFILE_TURN:
		out.append(Problem.NO_PROFILE)
	if role == Role.FRONT and turn > MAX_FRONT_TURN:
		out.append(Problem.NOT_FRONT)
	if role == Role.SIDE and turn < MIN_SIDE_TURN:
		out.append(Problem.NOT_TURNED)
	if role == Role.SIDE and turn > MAX_SIDE_TURN:
		out.append(Problem.TOO_TURNED)
	if measures.has("brightness"):
		var b: float = measures["brightness"]
		if b < MIN_BRIGHTNESS:
			out.append(Problem.TOO_DARK)
		elif b > MAX_BRIGHTNESS or float(measures["clipped"]) > MAX_CLIPPED:
			out.append(Problem.TOO_BRIGHT)
		if float(measures["sharpness"]) < MIN_SHARPNESS:
			out.append(Problem.BLURRY)
	if role == Role.FRONT and (float(measures.get("smile", 0.0)) >= MAX_SMILE or float(measures.get("lips_gap", 0.0)) >= MAX_LIPS_GAP):
		out.append(Problem.NOT_NEUTRAL)
		return out
	if role == Role.FRONT:
		for key: String in MAX_EXPRESSION:
			if float(expressions.get(key, 0.0)) > float(MAX_EXPRESSION[key]):
				out.append(Problem.NOT_NEUTRAL)
				break
	return out
